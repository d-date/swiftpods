import CryptoKit
import Foundation
import PodsCore
@testable import PodsInstaller
import PodsPodfile
import PodsSources
import Testing

@Suite(.serialized)
struct DistributionBuilderTests {
    let root: URL
    let cache: URL
    let shell = Shell()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-distribution-\(UUID().uuidString)")
        cache = root.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ contents: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes `Podfile.swift` for target `App` (iOS 15.0, static frameworks) depending on `Prebuilt` and `Source`.
    private func writePodfile(distribution: Bool = true, integrateTargets: Bool = false) throws {
        try write("""
        import SwiftPodsDescription

        let podfile = Podfile(
            platform: .iOS("15.0"),
            useFrameworks: .static,
            installationOptions: .init(integrateTargets: \(integrateTargets)),
            \(distribution ? #"distribution: .init(name: "Fixture", url: "https://example.com/fixture"),"# : "")
            targets: [
                .target(
                    name: "App",
                    dependencies: [
                        .pod(name: "Prebuilt", path: "LocalPods/Prebuilt"),
                        .pod(name: "Source", path: "LocalPods/Source"),
                    ]
                ),
            ]
        )
        """, "Podfile.swift")
    }

    /// `Source`: an Objective-C source pod. `Prebuilt`: a vendored static framework (clang-built objects, device
    /// arm64 + simulator x86_64, no Info.plist) calling into `Source`.
    private func writePods() async throws {
        try write("""
        {"name":"Source","version":"1.0.0","platforms":{"ios":"15.0"},"source":{"git":"https://example.com/Source.git","tag":"1.0.0"},
         "source_files":"*.{h,m}","public_header_files":"*.h"}
        """, "LocalPods/Source/Source.podspec.json")
        try write("int SourceValue(void);\n", "LocalPods/Source/SourceValue.h")
        try write("#import \"SourceValue.h\"\n\nint SourceValue(void) { return 1; }\n", "LocalPods/Source/SourceValue.m")

        try write("""
        {"name":"Prebuilt","version":"2.0.0","platforms":{"ios":"15.0"},"source":{"http":"https://example.com/Prebuilt.zip"},
         "vendored_frameworks":"Prebuilt.framework","dependencies":{"Source":[]}}
        """, "LocalPods/Prebuilt/Prebuilt.podspec.json")
        let framework = root.appendingPathComponent("LocalPods/Prebuilt/Prebuilt.framework")
        try write("int PrebuiltValue(void);\n", "LocalPods/Prebuilt/Prebuilt.framework/Headers/Prebuilt.h")
        let objects = root.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        let source = objects.appendingPathComponent("Prebuilt.c")
        try "int SourceValue(void);\nint PrebuiltValue(void) { return SourceValue() + 1; }\n".write(to: source, atomically: true, encoding: .utf8)
        var slices: [String] = []
        for target in ["arm64-apple-ios15.0", "x86_64-apple-ios15.0-simulator"] {
            let object = objects.appendingPathComponent("\(target).o").path
            try await shell.run("xcrun", ["clang", "-c", "-target", target, source.path, "-o", object])
            slices.append(object)
        }
        try await shell.run("xcrun", ["lipo", "-create"] + slices + ["-output", framework.appendingPathComponent("Prebuilt").path])
    }

    private func context() throws -> InstallerContext {
        try InstallerContext(projectDirectory: root, cacheRoot: cache, ui: .capturing(), sources: SourcesManager(sources: []))
    }

    @Test func requiresDistributionSettings() async throws {
        try writePodfile(distribution: false)
        try await writePodsWithoutBinaries()

        let builder = DistributionBuilder(context: try context(), options: DistributionOptions(version: "1.0.0", outputDirectory: nil))
        let error = await #expect(throws: PodsError.self) { try await builder.build() }

        #expect(error?.description.contains("`distribution`") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Pods").path))
    }

    @Test func requiresTargetsNotIntegrated() async throws {
        try writePodfile(integrateTargets: true)
        try await writePodsWithoutBinaries()

        let builder = DistributionBuilder(context: try context(), options: DistributionOptions(version: "1.0.0", outputDirectory: nil))
        let error = await #expect(throws: PodsError.self) { try await builder.build() }

        #expect(error?.description.contains("integrateTargets: false") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Pods").path))
    }

    /// The pod directories the Podfile names, without the prebuilt binary (the build must fail before using them).
    private func writePodsWithoutBinaries() async throws {
        try write(#"{"name":"Source","version":"1.0.0","source_files":"*.m"}"#, "LocalPods/Source/Source.podspec.json")
        try write(#"{"name":"Prebuilt","version":"2.0.0","vendored_frameworks":"Prebuilt.framework"}"#, "LocalPods/Prebuilt/Prebuilt.podspec.json")
    }

    @Test func packageDependencies() throws {
        let libURL = "https://example.com/Lib.git"
        let toolURL = "https://example.com/Tool.git"
        func range(_ lower: Version, _ upper: Version) -> Requirement {
            Requirement(constraints: [.init(.greaterThanOrEqual, lower), .init(.lessThan, upper)])
        }
        let unification = PackageUnifier.Unification(
            podRoot: "Lib", packageURL: libURL, allowedVersions: [Version(1, 0, 0), Version(1, 0, 1)],
            lowerBound: Version(1, 0, 0), upperBound: Version(1, 0, 2), allowedCommits: [],
            taggedVersions: [Version(0, 9, 0), Version(1, 0, 0), Version(1, 0, 1), Version(1, 1, 0)],
            podAcceptedVersions: [Version(1, 0, 0), Version(1, 0, 1)], podfileRequirement: range(Version(1, 0, 0), Version(2, 0, 0)),
            unsafeOverrideReason: nil)
        let resolved = SwiftPackageResolver.Result(
            pins: [.init(identity: "tool", url: toolURL, version: Version(1, 5, 0), revision: "b"),
                   .init(identity: "lib", url: libURL, version: Version(1, 0, 1), revision: "a")],
            libraryProducts: ["lib": ["LibCore", "LibExtra"], "tool": ["Tool"]], resolvedFile: Data())

        let dependencies = try DistributionBuilder.packageDependencies(
            declared: [SwiftPackageDependency(url: toolURL, requirement: range(Version(1, 2, 0), Version(2, 0, 0))),
                       SwiftPackageDependency(url: libURL, requirement: range(Version(1, 0, 0), Version(2, 0, 0)))],
            unifications: [unification], resolved: resolved)

        // The unified package is narrowed (once, although it is also declared); the other declared package keeps its range.
        #expect(dependencies == [
            .init(url: libURL, requirement: .closedRange(Version(1, 0, 0), Version(1, 0, 1)), products: ["LibCore", "LibExtra"]),
            .init(url: toolURL, requirement: .range(Version(1, 2, 0), Version(2, 0, 0)), products: ["Tool"]),
        ])
    }

    @Test func verificationManifestUsesLocalXCFrameworks() throws {
        let manifest = """
            .binaryTarget(
              name: "Lib",
              url: "https://example.com/fixture/releases/download/1.0.0/Lib.xcframework.zip",
              checksum: "a783fcd83fa1d967d409187faf5d648e9aed61db7bd1376eb48674edb4e3d51b"),
            .target(
              name: "Common",
        """

        #expect(try ProductLinkVerifier.localManifest(manifest) == """
            .binaryTarget(
              name: "Lib",
              path: "Lib.xcframework"),
            .target(
              name: "Common",
        """)
        #expect(throws: PodsError.self) { try ProductLinkVerifier.localManifest(#"url: "Lib.zip", checksum: "00")"#) }
    }

    @Test func linkFailureSummary() {
        let log = """
        Ld /tmp/dd/Build/Intermediates.noindex/App.build/Binary/App normal x86_64
            /usr/bin/swiftc -emit-executable -o App
        Undefined symbols for architecture x86_64:
          "_SourceValue", referenced from:
              _PrebuiltValue in Prebuilt[x86_64][2](x86_64)
        ld: symbol(s) not found for architecture x86_64
        Package.swift: App-product: clang: error: linker command failed with exit code 1 (use -v to see invocation)
        Undefined symbols for architecture arm64:
          "_SourceValue", referenced from:
        """

        #expect(ProductLinkVerifier.failureSummary(log) == """
        Undefined symbols for architecture x86_64:
          "_SourceValue", referenced from:
              _PrebuiltValue in Prebuilt[x86_64][2](x86_64)
        """)
        #expect(ProductLinkVerifier.failureSummary("note: x\nerror: no such module") == "error: no such module")
    }

    /// Runs install, xcodebuild and xcframework assembly end to end. Slow, so opt-in: `SWIFTPODS_XCODEBUILD=1 swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTPODS_XCODEBUILD"] == "1"))
    func buildsFixtureDistribution() async throws {
        try writePodfile()
        try await writePods()

        let output = try await DistributionBuilder(context: try context(), options: DistributionOptions(version: "1.0.0", outputDirectory: nil)).build()

        #expect(output.standardizedFileURL.path == root.appendingPathComponent("build/distribution").standardizedFileURL.path)
        for file in ["Prebuilt.xcframework.zip", "Source.xcframework.zip", "Package.swift"] {
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(file).path), "\(file)")
        }
        let manifest = try String(contentsOf: output.appendingPathComponent("Package.swift"), encoding: .utf8)
        let zip = try Data(contentsOf: output.appendingPathComponent("Prebuilt.xcframework.zip"))
        let checksum = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        #expect(manifest.contains("""
              name: "Prebuilt",
              url: "https://example.com/fixture/releases/download/1.0.0/Prebuilt.xcframework.zip",
              checksum: "\(checksum)"),
        """))
        #expect(try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8) == manifest)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Common/export.swift").path))
        // The output directory is a complete package apart from the binary target URLs: verification builds it.
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Sources/Common/export.swift").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("build/work/verification/Prebuilt").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("build/work/verification/Source").path))
    }

    /// A product whose targets lack a binary target its other targets need fails verification with the linker's
    /// undefined symbols. Slow, so opt-in like `buildsFixtureDistribution`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTPODS_XCODEBUILD"] == "1"))
    func detectsProductMissingATarget() async throws {
        try writePodfile()
        try await writePods()
        let output = try await DistributionBuilder(context: try context(), options: DistributionOptions(version: "1.0.0", outputDirectory: nil, verify: false)).build()
        // `Prebuilt` calls `SourceValue`, which only the `Source` binary target defines.
        let manifestURL = output.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let broken = manifest.replacingOccurrences(of: #"targets: ["Prebuilt", "Source", "Common"]"#, with: #"targets: ["Prebuilt", "Common"]"#)
        #expect(broken != manifest)
        try broken.write(to: manifestURL, atomically: true, encoding: .utf8)

        let verifier = ProductLinkVerifier(shell: shell, workDirectory: root.appendingPathComponent("verification"), deploymentTarget: Version(15, 0, 0))
        let error = await #expect(throws: PodsError.self) {
            try await verifier.verify(products: ["Prebuilt", "Source"], packageDirectory: output)
        }

        let message = error?.description ?? ""
        #expect(message.contains("Prebuilt"), "\(message)")
        #expect(message.contains("Undefined symbols"), "\(message)")
        #expect(message.contains("_SourceValue"), "\(message)")
    }
}
