import Foundation
import PodsCore

/// Turns pod frameworks into xcframeworks that SwiftPM consumers can link as binary targets.
struct XCFrameworkAssembler {
    let shell: Shell
    /// Scratch space; each assembly stages its files in a subdirectory it removes when done.
    let workDirectory: URL

    private enum SDK: CaseIterable {
        case device, simulator

        var directory: String {
            switch self {
            case .device: "iphoneos"
            case .simulator: "iphonesimulator"
            }
        }

        var platformName: String {
            switch self {
            case .device: "iPhoneOS"
            case .simulator: "iPhoneSimulator"
            }
        }

        /// The LC_BUILD_VERSION platform number.
        var platform: UInt32 {
            switch self {
            case .device: 2
            case .simulator: 7
            }
        }

        /// The platform name `ld -platform_version` takes.
        var linkerPlatform: String {
            switch self {
            case .device: "ios"
            case .simulator: "ios-simulator"
            }
        }
    }

    /// Intel slices only ever run in the simulator, whatever their load commands say.
    private static let intelArchs: Set<String> = ["x86_64", "i386"]
    private static let deviceArchs: Set<String> = ["arm64", "arm64e", "armv7", "armv7s"]

    /// A prebuilt `.framework` (device and simulator slices fat in one binary, as vendored by pods):
    /// adds Info.plist when missing, splits per SDK, injects simulator arm64 from device arm64 when absent,
    /// converts object binaries to `ar`, then `xcodebuild -create-xcframework -framework … -framework …`.
    /// The vendored framework is not modified.
    /// - Returns: `<output>/<Module>.xcframework`.
    func assemblePrebuilt(framework: URL, podVersion: Version, minimumOS: String, output: URL) async throws -> URL {
        let module = framework.deletingPathExtension().lastPathComponent
        let staging = try reset(workDirectory.appendingPathComponent("prebuilt").appendingPathComponent(module))
        let thinDirectory = staging.appendingPathComponent("thin")
        try FileManager.default.createDirectory(at: thinDirectory, withIntermediateDirectories: true)

        let binary = framework.appendingPathComponent(module)
        var slices: [SDK: [String: URL]] = [:]
        for arch in try await archs(of: binary) {
            let thin = thinDirectory.appendingPathComponent(arch)
            try await extract(arch, from: binary, to: thin)
            guard try MachO.kind(of: thin) != .image else {
                throw PodsError("dynamic prebuilt frameworks are not supported by swiftpods package yet: \(framework.lastPathComponent)")
            }
            let platforms = try MachO.platforms(of: thin)
            let sdk: SDK
            if platforms.isEmpty {
                // No platform load command at all, or only LC_VERSION_MIN_*: the arch decides, and the
                // slice gets an LC_BUILD_VERSION so the xcframework can be created and patched.
                sdk = try self.sdk(ofArch: arch, in: binary)
                try await setBuildVersion(of: thin, arch: arch, sdk: sdk, minimumOS: minimumOS)
            } else {
                sdk = try self.sdk(of: platforms, arch: arch, in: binary)
            }
            slices[sdk, default: [:]][arch] = thin
        }

        // Apple Silicon simulators need arm64 code; the device code runs there once the platform the
        // linker checks says simulator. Must happen before the `ar` conversion below.
        if slices[.simulator]?["arm64"] == nil, let deviceArm64 = slices[.device]?["arm64"] {
            let injected = thinDirectory.appendingPathComponent("arm64-simulator")
            try FileManager.default.copyItem(at: deviceArm64, to: injected)
            try MachO.rewritePlatform(of: injected, to: SDK.simulator.platform)
            slices[.simulator, default: [:]]["arm64"] = injected
        }

        let hasInfoPlist = FileManager.default.fileExists(atPath: framework.appendingPathComponent("Info.plist").path)
        var arguments = ["xcodebuild", "-create-xcframework"]
        for sdk in SDK.allCases {
            guard let archSlices = slices[sdk] else { continue }
            let sdkFramework = staging.appendingPathComponent(sdk.directory).appendingPathComponent(framework.lastPathComponent)
            try FileManager.default.createDirectory(at: sdkFramework.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: framework, to: sdkFramework)

            var archives: [URL] = []
            for (_, slice) in archSlices.sorted(by: { $0.key < $1.key }) { archives.append(try await makeStatic(slice)) }
            let sdkBinary = sdkFramework.appendingPathComponent(module)
            try FileManager.default.removeItem(at: sdkBinary)
            try await merge(archives, into: sdkBinary)

            if !hasInfoPlist {
                try FrameworkInfoPlist.make(module: module, podVersion: podVersion, platformName: sdk.platformName, minimumOS: minimumOS)
                    .write(to: sdkFramework.appendingPathComponent("Info.plist"))
            }
            arguments += ["-framework", sdkFramework.path]
        }

        let xcframework = try await create(module: module, arguments: arguments, output: output)
        try FileManager.default.removeItem(at: staging)
        return xcframework
    }

    /// A source pod built per SDK into `<build>/Release-<sdk>/<target>/<Module>.framework` (static):
    /// library xcframework from `lib<Module>.a` + `Headers` of each SDK. A framework bundle would make
    /// Xcode embed a stub, which App Store review rejects for common third-party SDKs (ITMS-91065).
    /// - Returns: `<output>/<module>.xcframework`.
    func assembleSource(module: String, deviceFramework: URL, simulatorFramework: URL, output: URL) async throws -> URL {
        for framework in [deviceFramework, simulatorFramework] {
            let modules = framework.appendingPathComponent("Modules")
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: modules.path)) ?? []
            if contents.contains(where: { $0.hasSuffix(".swiftmodule") }) {
                throw PodsError("Swift source pods are not supported by swiftpods package yet: \(module)")
            }
        }
        let staging = try reset(workDirectory.appendingPathComponent("source").appendingPathComponent(module))
        var arguments = ["xcodebuild", "-create-xcframework"]
        for (sdk, framework) in [(SDK.device, deviceFramework), (.simulator, simulatorFramework)] {
            let directory = staging.appendingPathComponent(sdk.directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let library = directory.appendingPathComponent("lib\(module).a")
            try FileManager.default.copyItem(at: framework.appendingPathComponent(module), to: library)
            arguments += ["-library", library.path]

            let headers = framework.appendingPathComponent("Headers")
            if FileManager.default.fileExists(atPath: headers.path) {
                let staged = directory.appendingPathComponent("Headers")
                try FileManager.default.copyItem(at: headers, to: staged)
                arguments += ["-headers", staged.path]
            }
        }

        let xcframework = try await create(module: module, arguments: arguments, output: output)
        try FileManager.default.removeItem(at: staging)
        return xcframework
    }

    /// Runs `xcodebuild -create-xcframework`, replacing an existing `<output>/<module>.xcframework`.
    private func create(module: String, arguments: [String], output: URL) async throws -> URL {
        let xcframework = output.appendingPathComponent("\(module).xcframework")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: xcframework.path) { try FileManager.default.removeItem(at: xcframework) }
        try await shell.run("xcrun", arguments + ["-output", xcframework.path])
        return xcframework
    }

    private func reset(_ directory: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func archs(of binary: URL) async throws -> [String] {
        try await shell.run("xcrun", ["lipo", "-archs", binary.path]).stdout.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Writes the `arch` slice of `binary` to `output` as a thin file.
    private func extract(_ arch: String, from binary: URL, to output: URL) async throws {
        if try MachO.kind(of: binary) == .fat {
            try await shell.run("xcrun", ["lipo", "-thin", arch, binary.path, "-output", output.path])
        } else {
            try FileManager.default.copyItem(at: binary, to: output)
        }
    }

    private func sdk(of platforms: Set<UInt32>, arch: String, in binary: URL) throws -> SDK {
        if Self.intelArchs.contains(arch) { return .simulator }
        if let sdk = SDK.allCases.first(where: { platforms == [$0.platform] }) { return sdk }
        let named = platforms.sorted().map(String.init).joined(separator: ", ")
        throw PodsError("Cannot tell whether the \(arch) slice of \(binary.path) is for devices or the simulator (LC_BUILD_VERSION platforms: \(named))")
    }

    private func sdk(ofArch arch: String, in binary: URL) throws -> SDK {
        if Self.intelArchs.contains(arch) { return .simulator }
        if Self.deviceArchs.contains(arch) { return .device }
        throw PodsError("Cannot tell whether the \(arch) slice of \(binary.path) is for devices or the simulator (no LC_BUILD_VERSION)")
    }

    /// Gives a thin object file without LC_BUILD_VERSION one for `sdk`, replacing any LC_VERSION_MIN_*.
    private func setBuildVersion(of thin: URL, arch: String, sdk: SDK, minimumOS: String) async throws {
        guard try MachO.kind(of: thin) == .object else {
            throw PodsError("The \(arch) slice \(thin.path) has no LC_BUILD_VERSION and is not an object file; its platform cannot be set")
        }
        let sdkVersion = try await shell.run("xcrun", ["--sdk", sdk.directory, "--show-sdk-version"]).stdout.trimmingWhitespace()
        let patched = thin.appendingPathExtension("platform")
        let vtool = try await shell.execute(["xcrun", "vtool", "-arch", arch, "-set-build-version", String(sdk.platform),
                                             minimumOS, sdkVersion, "-replace", "-output", patched.path, thin.path])
        if vtool.status != 0 {
            // vtool edits in place and fails when the header has no room for the larger command, which
            // is the norm for compiler output; relinking the object lays out a new header instead.
            // `-keep_private_externs` keeps hidden symbols linkable from the rest of the library.
            let linker = try await shell.execute(["xcrun", "ld", "-r", "-keep_private_externs", "-arch", arch,
                                                  "-platform_version", sdk.linkerPlatform, minimumOS, sdkVersion,
                                                  "-o", patched.path, thin.path])
            guard linker.status == 0 else {
                throw PodsError("""
                Could not set the platform of the \(arch) slice \(thin.path):
                vtool: \(vtool.stderr.trimmingWhitespace())
                ld -r: \(linker.stderr.trimmingWhitespace())
                """)
            }
        }
        try FileManager.default.removeItem(at: thin)
        try FileManager.default.moveItem(at: patched, to: thin)
    }

    /// An `ar` archive of a thin object file, or the file itself when it is not an object file.
    /// Xcode treats a framework whose binary is an object file as dynamic and relinks it with
    /// dead-stripping, which drops data nothing references (such as embedded models).
    private func makeStatic(_ thin: URL) async throws -> URL {
        guard try MachO.kind(of: thin) == .object else { return thin }
        let archive = thin.appendingPathExtension("a")
        try await shell.run("xcrun", ["libtool", "-static", "-o", archive.path, thin.path])
        return archive
    }

    /// Combines thin files into `output`, keeping a single slice thin.
    private func merge(_ slices: [URL], into output: URL) async throws {
        if slices.count == 1 {
            try FileManager.default.copyItem(at: slices[0], to: output)
        } else {
            try await shell.run("xcrun", ["lipo", "-create"] + slices.map(\.path) + ["-output", output.path])
        }
    }
}
