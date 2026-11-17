import Foundation
import PodsCore
@testable import PodsInstaller
import Testing

private func toolchainAvailable() async -> Bool {
    (try? await Shell().execute(["xcrun", "--find", "clang"]).status) == 0
}

private func plist(at url: URL) throws -> [String: Any] {
    try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
}

struct FrameworkInfoPlistTests {
    @Test func containsSpecKeys() throws {
        let data = FrameworkInfoPlist.make(module: "Fixture", podVersion: Version(1, 2, 3), platformName: "iPhoneOS", minimumOS: "15.0")
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(info["CFBundleExecutable"] as? String == "Fixture")
        #expect(info["CFBundleName"] as? String == "Fixture")
        #expect(info["CFBundleIdentifier"] as? String == "org.cocoapods.Fixture")
        #expect(info["CFBundlePackageType"] as? String == "FMWK")
        #expect(info["CFBundleShortVersionString"] as? String == "1.2.3")
        #expect(info["CFBundleVersion"] as? String == "1")
        #expect(info["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneOS"])
        #expect(info["MinimumOSVersion"] as? String == "15.0")
    }

    @Test func betaVersionUsesReleasePart() throws {
        let data = FrameworkInfoPlist.make(module: "Fixture", podVersion: try #require(Version("1.0.0-beta8")),
                                           platformName: "iPhoneSimulator", minimumOS: "15.0")
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(info["CFBundleShortVersionString"] as? String == "1.0.0")
    }
}

/// Builds fake pod frameworks with the Xcode toolchain and assembles them into xcframeworks.
@Suite(.enabled("requires the Xcode toolchain") { await toolchainAvailable() })
struct XCFrameworkAssemblerTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-xcframework-\(UUID().uuidString)")
    let shell = Shell()

    var assembler: XCFrameworkAssembler {
        XCFrameworkAssembler(shell: shell, workDirectory: root.appendingPathComponent("work"))
    }

    var output: URL { root.appendingPathComponent("out") }

    /// Compiles `source` into an object file under `<root>/objects` for `target`.
    private func object(_ name: String, source: String, target: String) async throws -> URL {
        let directory = root.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).c")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("\(name).o")
        try await shell.run("xcrun", ["clang", "-c", "-target", target, file.path, "-o", output.path])
        return output
    }

    /// A `Fixture.framework` with a header and a fat binary made of `slices`.
    private func framework(at directory: String, slices: [URL]) async throws -> URL {
        let framework = root.appendingPathComponent(directory).appendingPathComponent("Fixture.framework")
        let headers = framework.appendingPathComponent("Headers")
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        try "int fixture(void);\n".write(to: headers.appendingPathComponent("Fixture.h"), atomically: true, encoding: .utf8)
        try await shell.run("xcrun", ["lipo", "-create"] + slices.map(\.path) + ["-output", framework.appendingPathComponent("Fixture").path])
        return framework
    }

    /// The xcframework's AvailableLibraries keyed by "<platform>[-<variant>]".
    private func libraries(of xcframework: URL) throws -> [String: [String: Any]] {
        let libraries = try #require(plist(at: xcframework.appendingPathComponent("Info.plist"))["AvailableLibraries"] as? [[String: Any]])
        var result: [String: [String: Any]] = [:]
        for library in libraries {
            let platform = library["SupportedPlatform"] as? String ?? "?"
            let key = (library["SupportedPlatformVariant"] as? String).map { "\(platform)-\($0)" } ?? platform
            result[key] = library
        }
        return result
    }

    private func sliceDirectory(_ library: [String: Any]?, in xcframework: URL) throws -> URL {
        let identifier = try #require(library?["LibraryIdentifier"] as? String)
        return xcframework.appendingPathComponent(identifier)
    }

    private func thin(_ binary: URL, arch: String) async throws -> URL {
        let output = root.appendingPathComponent("thin-\(UUID().uuidString)-\(arch)")
        try await shell.run("xcrun", ["lipo", "-thin", arch, binary.path, "-output", output.path])
        return output
    }

    @Test func injectsSimulatorArm64KeepingX86() async throws {
        let device = try await object("device", source: "int fixture(void) { return 1; }\n", target: "arm64-apple-ios15.0")
        let intel = try await object("intel", source: "int fixture(void) { return 2; }\n", target: "x86_64-apple-ios15.0-simulator")
        let fw = try await framework(at: "pod", slices: [device, intel])

        let xcf = try await assembler.assemblePrebuilt(framework: fw, podVersion: Version(1, 2, 3), minimumOS: "15.0", output: output)

        #expect(xcf.path == output.appendingPathComponent("Fixture.xcframework").path)
        let libraries = try libraries(of: xcf)
        #expect(libraries.count == 2)
        #expect(libraries["ios"]?["SupportedArchitectures"] as? [String] == ["arm64"])
        #expect((libraries["ios-simulator"]?["SupportedArchitectures"] as? [String])?.sorted() == ["arm64", "x86_64"])

        let simulator = try sliceDirectory(libraries["ios-simulator"], in: xcf).appendingPathComponent("Fixture.framework")
        for arch in ["arm64", "x86_64"] {
            let slice = try await thin(simulator.appendingPathComponent("Fixture"), arch: arch)
            #expect(try MachO.kind(of: slice) == .archive, "simulator \(arch)")
            #expect(try MachO.platforms(of: slice) == [7], "simulator \(arch)")
        }
        let deviceFramework = try sliceDirectory(libraries["ios"], in: xcf).appendingPathComponent("Fixture.framework")
        let deviceBinary = deviceFramework.appendingPathComponent("Fixture")
        #expect(try MachO.kind(of: deviceBinary) == .archive)
        #expect(try MachO.platforms(of: deviceBinary) == [2])
        #expect(FileManager.default.fileExists(atPath: deviceFramework.appendingPathComponent("Headers/Fixture.h").path))

        for (framework, platform) in [(deviceFramework, "iPhoneOS"), (simulator, "iPhoneSimulator")] {
            let info = try plist(at: framework.appendingPathComponent("Info.plist"))
            #expect(info["CFBundleIdentifier"] as? String == "org.cocoapods.Fixture")
            #expect(info["CFBundleShortVersionString"] as? String == "1.2.3")
            #expect(info["CFBundleSupportedPlatforms"] as? [String] == [platform])
        }
        // The vendored framework is left untouched.
        #expect(try MachO.kind(of: fw.appendingPathComponent("Fixture")) == .fat)
        #expect(!FileManager.default.fileExists(atPath: fw.appendingPathComponent("Info.plist").path))
    }

    @Test func keepsExistingInfoPlist() async throws {
        let device = try await object("device", source: "int fixture(void) { return 1; }\n", target: "arm64-apple-ios15.0")
        let intel = try await object("intel", source: "int fixture(void) { return 2; }\n", target: "x86_64-apple-ios15.0-simulator")
        let fw = try await framework(at: "pod", slices: [device, intel])
        let existing: [String: Any] = [
            "CFBundleExecutable": "Fixture", "CFBundleIdentifier": "com.example.fixture",
            "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "9.9.9",
        ]
        try PropertyListSerialization.data(fromPropertyList: existing, format: .xml, options: 0)
            .write(to: fw.appendingPathComponent("Info.plist"))

        let xcf = try await assembler.assemblePrebuilt(framework: fw, podVersion: Version(1, 2, 3), minimumOS: "15.0", output: output)

        let libraries = try libraries(of: xcf)
        for key in ["ios", "ios-simulator"] {
            let info = try plist(at: sliceDirectory(libraries[key], in: xcf).appendingPathComponent("Fixture.framework/Info.plist"))
            #expect(info["CFBundleIdentifier"] as? String == "com.example.fixture", "\(key)")
            #expect(info["CFBundleShortVersionString"] as? String == "9.9.9", "\(key)")
        }
    }

    @Test func keepsExistingSimulatorArm64() async throws {
        // A fat binary cannot hold two arm64 slices, so a framework that already has an arm64
        // simulator slice has no device arm64 slice to inject from.
        let simulator = try await object("simulator", source: "int fixture(void) { return 1; }\nint simulatorOnly(void) { return 3; }\n",
                                         target: "arm64-apple-ios15.0-simulator")
        let fw = try await framework(at: "pod", slices: [simulator])

        let xcf = try await assembler.assemblePrebuilt(framework: fw, podVersion: Version(1, 2, 3), minimumOS: "15.0", output: output)

        let libraries = try libraries(of: xcf)
        // No device arm64 slice: nothing is injected and no device slice appears.
        #expect(Array(libraries.keys) == ["ios-simulator"])
        #expect(libraries["ios-simulator"]?["SupportedArchitectures"] as? [String] == ["arm64"])
        let binary = try sliceDirectory(libraries["ios-simulator"], in: xcf).appendingPathComponent("Fixture.framework/Fixture")
        #expect(try MachO.platforms(of: binary) == [7])
        #expect(try await shell.run("xcrun", ["nm", binary.path]).stdout.contains("_simulatorOnly"))
    }

    enum DevicePlatformCommand: String, CaseIterable { case versionMin, none }

    @Test(arguments: DevicePlatformCommand.allCases)
    func deviceSliceWithoutBuildVersionIsClassifiedByArch(_ command: DevicePlatformCommand) async throws {
        // A hidden symbol must stay a private external; relinking can otherwise demote it.
        let source = "__attribute__((visibility(\"hidden\"))) int helper(void) { return 7; }\nint fixture(void) { return helper(); }\n"
        let device: URL
        switch command {
        case .versionMin:
            // Deployment targets this old make clang emit LC_VERSION_MIN_IPHONEOS instead of LC_BUILD_VERSION.
            device = try await object("device", source: source, target: "arm64-apple-ios9.0")
        case .none:
            let modern = try await object("device", source: source, target: "arm64-apple-ios15.0")
            device = root.appendingPathComponent("objects/device-bare.o")
            try await shell.run("xcrun", ["vtool", "-arch", "arm64", "-remove-build-version", "2", "-output", device.path, modern.path])
            let load = try await shell.run("xcrun", ["otool", "-l", device.path]).stdout
            #expect(!load.contains("LC_BUILD_VERSION") && !load.contains("LC_VERSION_MIN"))
        }
        #expect(try MachO.platforms(of: device).isEmpty)
        let symbolsBefore = try await symbols(of: device)
        #expect(symbolsBefore.contains { $0.hasSuffix("(__TEXT,__text) private external _helper") })
        let intel = try await object("intel", source: "int fixture(void) { return 2; }\n", target: "x86_64-apple-ios15.0-simulator")
        let fw = try await framework(at: "pod", slices: [device, intel])

        let xcf = try await assembler.assemblePrebuilt(framework: fw, podVersion: Version(1, 2, 3), minimumOS: "15.0", output: output)

        let libraries = try libraries(of: xcf)
        #expect(libraries["ios"]?["SupportedArchitectures"] as? [String] == ["arm64"])
        #expect((libraries["ios-simulator"]?["SupportedArchitectures"] as? [String])?.sorted() == ["arm64", "x86_64"])
        let deviceBinary = try sliceDirectory(libraries["ios"], in: xcf).appendingPathComponent("Fixture.framework/Fixture")
        #expect(try MachO.kind(of: deviceBinary) == .archive)
        #expect(try MachO.platforms(of: deviceBinary) == [2])
        #expect(try await symbols(of: deviceBinary) == symbolsBefore)
        let simulator = try sliceDirectory(libraries["ios-simulator"], in: xcf).appendingPathComponent("Fixture.framework/Fixture")
        for arch in ["arm64", "x86_64"] {
            let slice = try await thin(simulator, arch: arch)
            #expect(try MachO.kind(of: slice) == .archive, "simulator \(arch)")
            #expect(try MachO.platforms(of: slice) == [7], "simulator \(arch)")
            if arch == "arm64" { #expect(try await symbols(of: slice) == symbolsBefore) }
        }
    }

    /// The `nm -m` symbol lines of an object or archive, without archive member headers and without the
    /// assembler's local `ltmp<N>` section labels, which every link (including `ld -r`) drops.
    private func symbols(of file: URL) async throws -> [String] {
        try await shell.run("xcrun", ["nm", "-m", file.path]).stdout
            .split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty && !$0.hasSuffix(":") && !$0.contains(" non-external ltmp") }
    }

    @Test func dynamicPrebuiltFrameworkThrows() async throws {
        let directory = root.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("dynamic.c")
        try "int fixture(void) { return 1; }\n".write(to: source, atomically: true, encoding: .utf8)
        let dylib = directory.appendingPathComponent("dynamic")
        try await shell.run("xcrun", ["--sdk", "iphoneos", "clang", "-dynamiclib", "-target", "arm64-apple-ios15.0",
                                      "-install_name", "@rpath/Fixture.framework/Fixture", source.path, "-o", dylib.path])
        let fw = try await framework(at: "pod", slices: [dylib])

        let error = await #expect(throws: PodsError.self) {
            try await assembler.assemblePrebuilt(framework: fw, podVersion: Version(1, 2, 3), minimumOS: "15.0", output: output)
        }

        #expect(error?.message == "dynamic prebuilt frameworks are not supported by swiftpods package yet: Fixture.framework")
    }

    @Test func swiftSourcePodThrows() async throws {
        var frameworks: [URL] = []
        for (sdk, target) in [("iphoneos", "arm64-apple-ios15.0"), ("iphonesimulator", "arm64-apple-ios15.0-simulator")] {
            let object = try await object(sdk, source: "int fixture(void) { return 1; }\n", target: target)
            let archive = object.deletingPathExtension().appendingPathExtension("a")
            try await shell.run("xcrun", ["libtool", "-static", "-o", archive.path, object.path])
            let framework = try await framework(at: "build/Release-\(sdk)/Fixture", slices: [archive])
            try FileManager.default.createDirectory(at: framework.appendingPathComponent("Modules/Fixture.swiftmodule"),
                                                    withIntermediateDirectories: true)
            frameworks.append(framework)
        }

        let error = await #expect(throws: PodsError.self) {
            try await assembler.assembleSource(module: "Fixture", deviceFramework: frameworks[0],
                                               simulatorFramework: frameworks[1], output: output)
        }

        #expect(error?.message == "Swift source pods are not supported by swiftpods package yet: Fixture")
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("Fixture.xcframework").path))
    }

    @Test func sourcePodBecomesLibraryXCFramework() async throws {
        var frameworks: [URL] = []
        for (sdk, targets) in [("iphoneos", ["arm64-apple-ios15.0"]),
                               ("iphonesimulator", ["arm64-apple-ios15.0-simulator", "x86_64-apple-ios15.0-simulator"])] {
            var archives: [URL] = []
            for target in targets {
                let object = try await object("\(sdk)-\(target)", source: "int fixture(void) { return 1; }\n", target: target)
                let archive = object.deletingPathExtension().appendingPathExtension("a")
                try await shell.run("xcrun", ["libtool", "-static", "-o", archive.path, object.path])
                archives.append(archive)
            }
            frameworks.append(try await framework(at: "build/Release-\(sdk)/Fixture", slices: archives))
        }

        let xcf = try await assembler.assembleSource(module: "Fixture", deviceFramework: frameworks[0],
                                                     simulatorFramework: frameworks[1], output: output)

        #expect(xcf.path == output.appendingPathComponent("Fixture.xcframework").path)
        let libraries = try libraries(of: xcf)
        #expect(Set(libraries.keys) == ["ios", "ios-simulator"])
        for (key, library) in libraries {
            #expect(library["LibraryPath"] as? String == "libFixture.a", "\(key)")
            #expect(library["HeadersPath"] as? String == "Headers", "\(key)")
            let slice = try sliceDirectory(library, in: xcf)
            #expect(FileManager.default.fileExists(atPath: slice.appendingPathComponent("Headers/Fixture.h").path), "\(key)")
        }
        let contents = try #require(FileManager.default.enumerator(atPath: xcf.path)).compactMap { $0 as? String }
        #expect(!contents.contains { $0.hasSuffix(".framework") })
    }
}
