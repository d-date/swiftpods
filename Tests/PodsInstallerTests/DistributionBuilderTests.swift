import CryptoKit
import Foundation
import PodsCore
@testable import PodsInstaller
import PodsPodfile
import PodsSources
import PodsSpec
import Synchronization
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

    /// `Source`: an Objective-C source pod with a resource bundle. `Prebuilt`: a vendored static framework (clang-built objects, device
    /// arm64 + simulator x86_64, no Info.plist, a module map) calling into `Source` and CoreMedia. Its objects are
    /// built without modules, so like ML Kit's they carry no autolink entry: CoreMedia is linked only because
    /// the module's header imports it.
    private func writePods() async throws {
        try write("""
        {"name":"Source","version":"1.0.0","platforms":{"ios":"15.0"},"source":{"git":"https://example.com/Source.git","tag":"1.0.0"},
         "source_files":"*.{h,m}","public_header_files":"*.h","resource_bundles":{"SourceResources":"Resources/*.txt"}}
        """, "LocalPods/Source/Source.podspec.json")
        try write("data\n", "LocalPods/Source/Resources/data.txt")
        try write("int SourceValue(void);\n", "LocalPods/Source/SourceValue.h")
        try write("#import \"SourceValue.h\"\n\nint SourceValue(void) { return 1; }\n", "LocalPods/Source/SourceValue.m")

        try write("""
        {"name":"Prebuilt","version":"2.0.0","platforms":{"ios":"15.0"},"source":{"http":"https://example.com/Prebuilt.zip"},
         "vendored_frameworks":"Prebuilt.framework","frameworks":"CoreMedia","dependencies":{"Source":[]}}
        """, "LocalPods/Prebuilt/Prebuilt.podspec.json")
        let framework = root.appendingPathComponent("LocalPods/Prebuilt/Prebuilt.framework")
        try write("#import <CoreMedia/CoreMedia.h>\n\nint PrebuiltValue(void);\nCMTime PrebuiltTime(void);\n",
                  "LocalPods/Prebuilt/Prebuilt.framework/Headers/Prebuilt.h")
        try write("framework module Prebuilt {\n  umbrella header \"Prebuilt.h\"\n  export *\n}\n",
                  "LocalPods/Prebuilt/Prebuilt.framework/Modules/module.modulemap")
        let objects = root.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        let source = objects.appendingPathComponent("Prebuilt.c")
        try """
        #include <CoreMedia/CoreMedia.h>

        int SourceValue(void);
        int PrebuiltValue(void) { return SourceValue() + 1; }
        CMTime PrebuiltTime(void) { return CMTimeMake(1, 1); }

        """.write(to: source, atomically: true, encoding: .utf8)
        var slices: [String] = []
        for (sdk, target) in [("iphoneos", "arm64-apple-ios15.0"), ("iphonesimulator", "x86_64-apple-ios15.0-simulator")] {
            let object = objects.appendingPathComponent("\(target).o").path
            try await shell.run("xcrun", ["--sdk", sdk, "clang", "-c", "-target", target, source.path, "-o", object])
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

    static let libURL = "https://example.com/Lib.git"
    static let toolURL = "https://example.com/Tool.git"

    static func range(_ lower: Version, _ upper: Version) -> Requirement {
        Requirement(constraints: [.init(.greaterThanOrEqual, lower), .init(.lessThan, upper)])
    }

    /// Pod `Lib` unified with package `Lib`, which tags 1.0.0 and 1.0.1 at commits of accepted pod versions.
    static func libUnification(declared: Bool = true, unsafeOverrideReason: String? = nil) -> PackageUnifier.Unification {
        PackageUnifier.Unification(
            podRoot: "Lib", packageURL: libURL, allowedVersions: [Version(1, 0, 0), Version(1, 0, 1)],
            lowerBound: Version(1, 0, 0), upperBound: Version(1, 0, 2), allowedCommits: [],
            taggedVersions: [Version(0, 9, 0), Version(1, 0, 0), Version(1, 0, 1), Version(1, 1, 0)],
            podAcceptedVersions: [Version(1, 0, 0), Version(1, 0, 1)], podfileRequirement: declared ? range(Version(1, 0, 0), Version(2, 0, 0)) : nil,
            unsafeOverrideReason: unsafeOverrideReason)
    }

    static func resolved(lib: Version = Version(1, 0, 1)) -> SwiftPackageResolver.Result {
        SwiftPackageResolver.Result(
            pins: [.init(identity: "tool", url: toolURL, version: Version(1, 5, 0), revision: "b"),
                   .init(identity: "lib", url: libURL, version: lib, revision: "a")],
            packages: [:], resolvedFile: Data())
    }

    static let declared = [SwiftPackageDependency(url: toolURL, requirement: range(Version(1, 2, 0), Version(2, 0, 0))),
                           SwiftPackageDependency(url: libURL, requirement: range(Version(1, 0, 0), Version(2, 0, 0)))]

    @Test func packageDependencies() throws {
        let dependencies = try DistributionBuilder.packageDependencies(
            declared: Self.declared, unifications: [Self.libUnification()], unifiedProducts: ["Lib": ["LibCore"]],
            targetProducts: [PackageProductDependency(name: "Tool", package: "Tool")], resolved: Self.resolved())

        // The unified package is narrowed (once, although it is also declared) and gets the products holding its pod's
        // code; the other declared package keeps its range and gets the products the target uses.
        #expect(dependencies == [
            .init(url: Self.libURL, requirement: .closedRange(Version(1, 0, 0), Version(1, 0, 1)), products: ["LibCore"]),
            .init(url: Self.toolURL, requirement: .range(Version(1, 2, 0), Version(2, 0, 0)), products: ["Tool"]),
        ])
    }

    /// A declared package no pod is unified with and whose products the target does not use is not a dependency.
    @Test func leavesOutDeclaredPackagesTheTargetDoesNotUse() throws {
        let dependencies = try DistributionBuilder.packageDependencies(
            declared: Self.declared, unifications: [Self.libUnification()], unifiedProducts: ["Lib": ["LibCore"]],
            targetProducts: [], resolved: Self.resolved())

        #expect(dependencies.map(\.url) == [Self.libURL])
    }

    /// A package only reached through other packages (not declared) is a dependency when a pod is unified with it.
    @Test func unifiedIndirectPackage() throws {
        let dependencies = try DistributionBuilder.packageDependencies(
            declared: [Self.declared[0]], unifications: [Self.libUnification(declared: false)], unifiedProducts: ["Lib": ["LibCore"]],
            targetProducts: [], resolved: Self.resolved(lib: Version(1, 0, 0)))

        #expect(dependencies == [.init(url: Self.libURL, requirement: .closedRange(Version(1, 0, 0), Version(1, 0, 1)), products: ["LibCore"])])
    }

    /// Products the target declares for a package replace the ones chosen from its pod's sources.
    @Test func targetProductsOverrideChosenProducts() throws {
        let dependencies = try DistributionBuilder.packageDependencies(
            declared: Self.declared, unifications: [Self.libUnification()], unifiedProducts: ["Lib": ["LibCore"]],
            targetProducts: [PackageProductDependency(name: "LibExtra", package: "Lib")], resolved: Self.resolved())

        #expect(dependencies.map(\.products) == [["LibExtra"]])
    }

    @Test func rejectsTargetProductsOfUndeclaredPackages() {
        #expect(throws: PodsError.self) {
            try DistributionBuilder.packageDependencies(
                declared: Self.declared, unifications: [], unifiedProducts: [:],
                targetProducts: [PackageProductDependency(name: "Other", package: "Other")], resolved: Self.resolved())
        }
    }

    /// With an unsafe override resolved outside the versions the pod accepts, the checkout is not the pod's code, so
    /// the chosen products come with a warning, unless the target declares them.
    @Test(arguments: [false, true])
    func warnsAboutProductsChosenOutsidePodVersions(declaresProducts: Bool) throws {
        let warnings = Mutex<[String]>([])
        let dependencies = try DistributionBuilder.packageDependencies(
            declared: Self.declared, unifications: [Self.libUnification(unsafeOverrideReason: "checked")], unifiedProducts: ["Lib": ["LibCore"]],
            targetProducts: declaresProducts ? [PackageProductDependency(name: "LibCore", package: "Lib")] : [],
            resolved: Self.resolved(lib: Version(1, 1, 0)), warn: { warning in warnings.withLock { $0.append(warning) } })

        #expect(dependencies.map(\.products) == [["LibCore"]])
        let messages = warnings.withLock { $0 }
        if declaresProducts {
            #expect(messages.isEmpty)
        } else {
            #expect(messages.count == 1)
            #expect(messages.first?.contains("LibCore") == true)
            #expect(messages.first?.contains("1.1.0") == true)
        }
    }

    /// The activated specs' system frameworks and libraries, inherited ones included; specs not activated add nothing.
    @Test func linkerSettingsOfActivatedSpecs() throws {
        let spec = try Specification(json: JSON(parsing: """
        {"name": "Pod", "version": "1.0.0", "platforms": {"ios": "15.0"}, "frameworks": "UIKit", "subspecs": [
          {"name": "A", "weak_frameworks": "CoreMotion", "libraries": ["z", "c++"]},
          {"name": "B", "frameworks": "WebKit"}
        ]}
        """))
        let pod = InstalledPod(spec: spec, activatedSpecs: ["Pod/A"], sourceName: nil, externalSource: nil,
                               location: root, isLocal: true, checkoutOptions: [:])

        #expect(DistributionBuilder.linkerSettings(of: [pod], platform: .ios)
            == .init(frameworks: ["CoreMotion", "UIKit"], libraries: ["c++", "z"]))
    }

    /// Artifacts of an earlier run must not survive into the output, where they would be uploaded with the new ones.
    @Test func removesStaleArtifacts() throws {
        let output = root.appendingPathComponent("output")
        for directory in ["Old.xcframework", "Old.bundle", "Sources/Common"] {
            try FileManager.default.createDirectory(at: output.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in ["Old.xcframework.zip", "Old.bundle.zip", "Package.swift", "notes.txt"] {
            try Data().write(to: output.appendingPathComponent(file))
        }

        let removed = try DistributionBuilder.removeStaleArtifacts(in: output)

        #expect(removed == ["Old.bundle", "Old.bundle.zip", "Old.xcframework", "Old.xcframework.zip"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["Package.swift", "Sources", "notes.txt"])
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

    /// A log without undefined symbols or `error:` lines still explains the failure: its last 30 lines.
    @Test func failureSummariesFallBackToLogTail() {
        let log = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let tail = (11...40).map { "line \($0)" }.joined(separator: "\n")

        #expect(ProductLinkVerifier.failureSummary(log) == tail)
        #expect(DistributionBuilder.buildFailureSummary(log) == tail)
        #expect(DistributionBuilder.buildFailureSummary("CompileC x\nfoo.m:1:1: error: bad\n** BUILD FAILED **") == "foo.m:1:1: error: bad")
    }

    /// Runs install, xcodebuild and xcframework assembly end to end. Slow, so opt-in: `SWIFTPODS_XCODEBUILD=1 swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTPODS_XCODEBUILD"] == "1"))
    func buildsFixtureDistribution() async throws {
        try writePodfile()
        try await writePods()
        try write("stale", "build/distribution/Gone.xcframework.zip")

        let output = try await DistributionBuilder(context: try context(), options: DistributionOptions(version: "1.0.0", outputDirectory: nil)).build()
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("Gone.xcframework.zip").path))

        #expect(output.standardizedFileURL.path == root.appendingPathComponent("build/distribution").standardizedFileURL.path)
        for file in ["Prebuilt.xcframework.zip", "Source.xcframework.zip", "SourceResources.bundle.zip", "Package.swift"] {
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
        // `Prebuilt`'s objects carry no autolink entry for CoreMedia; Common links it.
        #expect(manifest.contains(#".linkedFramework("CoreMedia")"#))
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
