import Foundation
import PathKit
import PodsCore
@testable import PodsInstaller
import PodsLockfile
import PodsSources
import Testing
import XcodeProj

/// Local git repositories standing in for a library published both as a pod and as a SwiftPM package.
struct SwiftPackageFixture {
    static let shell = Shell(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"])

    /// `file://` URL of `Lib` (pod `Lib` and package `lib`, product `LibCore`).
    let libURL: String
    /// `file://` URL of `Wrapper`, a package depending on `Lib` `from: "1.0.0"`.
    let wrapperURL: String
    let libDirectory: URL

    /// Creates `Repos/Lib`, `Repos/Wrapper` and the `:path` pod `LocalPods/Binary` (which requires `Lib ~> 1.0`).
    static func create(in root: URL) async throws -> SwiftPackageFixture {
        let lib = root.appendingPathComponent("Repos/Lib")
        try write("""
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Lib",
            products: [.library(name: "LibCore", targets: ["LibCore"])],
            targets: [.target(name: "LibCore", path: ".", sources: ["Sources/LibCore"], publicHeadersPath: "include")]
        )
        """, to: lib.appendingPathComponent("Package.swift"))
        try write("""
        Pod::Spec.new do |s|
          s.name = 'Lib'
          s.version = '1.0.0'
          s.source = { :git => 'file://\(lib.path)', :tag => "CocoaPods-#{s.version}" }
          s.source_files = 'Sources/LibCore/*.m', 'include/*.h'
        end
        """, to: lib.appendingPathComponent("Lib.podspec"))
        try write("#import \"Lib.h\"\n\nint LibValue(void) { return 1; }\n", to: lib.appendingPathComponent("Sources/LibCore/Lib.m"))
        try write("int LibValue(void);\n", to: lib.appendingPathComponent("include/Lib.h"))
        try await git(lib, "init", "--quiet", "-b", "main")
        try await commit(lib, tags: ["1.0.0", "CocoaPods-1.0.0"])
        try write("int LibValue(void);\nint LibValue2(void);\n", to: lib.appendingPathComponent("include/Lib.h"))
        try await commit(lib, tags: ["2.0.0"])

        let wrapper = root.appendingPathComponent("Repos/Wrapper")
        try write("""
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Wrapper",
            products: [.library(name: "Wrapper", targets: ["Wrapper"])],
            dependencies: [.package(url: "file://\(lib.path)", from: "1.0.0")],
            targets: [.target(name: "Wrapper", dependencies: [.product(name: "LibCore", package: "Lib")])]
        )
        """, to: wrapper.appendingPathComponent("Package.swift"))
        try write("public let wrapped = 1\n", to: wrapper.appendingPathComponent("Sources/Wrapper/Wrapper.swift"))
        try await git(wrapper, "init", "--quiet", "-b", "main")
        try await commit(wrapper, tags: ["1.0.0"])

        try write("""
        {"name":"Binary","version":"1.0.0","platforms":{"ios":"12.0"},"source":{"git":"https://example.com/Binary.git","tag":"1.0.0"},
         "source_files":"*.m","dependencies":{"Lib":["~> 1.0"]}}
        """, to: root.appendingPathComponent("LocalPods/Binary/Binary.podspec.json"))
        try write("int BinaryValue(void) { return 2; }\n", to: root.appendingPathComponent("LocalPods/Binary/Binary.m"))

        return SwiftPackageFixture(libURL: "file://" + lib.path, wrapperURL: "file://" + wrapper.path, libDirectory: lib)
    }

    /// Adds a commit to `Lib` tagged `1.0.1` and `CocoaPods-1.0.1`.
    func addLibPatchRelease() async throws {
        try Self.write("int LibValue(void);\nint LibPatch(void);\n", to: libDirectory.appendingPathComponent("include/Lib.h"))
        try await Self.commit(libDirectory, tags: ["1.0.1", "CocoaPods-1.0.1"])
    }

    /// The spec of pod `Lib` at `version`, downloaded from the `CocoaPods-<version>` tag.
    func libSpec(_ version: String, dependencies: String = "{}") -> String {
        #"{"name":"Lib","version":"\#(version)","platforms":{"ios":"12.0"},"source":{"git":"\#(libURL)","tag":"CocoaPods-\#(version)"},"source_files":"Sources/LibCore/*.m","dependencies":\#(dependencies)}"#
    }

    private static func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func git(_ repo: URL, _ arguments: String...) async throws {
        try await shell.run("git", ["-C", repo.path] + arguments)
    }

    private static func commit(_ repo: URL, tags: [String]) async throws {
        try await git(repo, "add", ".")
        try await git(repo, "commit", "--quiet", "-m", "release")
        for tag in tags { try await git(repo, "tag", tag) }
    }
}

@Suite(.serialized)
struct SwiftPackageTests {
    let root: URL
    let cache: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-spm-\(UUID().uuidString)")
        cache = root.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try FixtureProject.create(in: root)
    }

    /// Writes `Podfile.json` with target `App` depending on `Binary` and the given `swift_packages`.
    private func writePodfile(packages: [(url: String, requirement: [String])]) throws {
        let packagesJSON = packages.map { package in
            #"{"url":"\#(package.url)","requirement":[\#(package.requirement.map { #""\#($0)""# }.joined(separator: ","))]}"#
        }.joined(separator: ",")
        try """
        {"swift_packages":[\(packagesJSON)],
         "target_definitions":[{"name":"Pods","abstract":true,"platform":{"ios":"16.0"},"children":[
           {"name":"App","dependencies":[{"Binary":[{"path":"LocalPods/Binary"}]}]}]}]}
        """.write(to: root.appendingPathComponent("Podfile.json"), atomically: true, encoding: .utf8)
    }

    private func context(specs: [String]) throws -> InstallerContext {
        try InstallerContext(projectDirectory: root, cacheRoot: cache, ui: .capturing(),
                             sources: SourcesManager(sources: [try MemorySource(specs)]), shell: SwiftPackageFixture.shell)
    }

    private func analyze(specs: [String], update: InstallOptions.UpdateMode = .none) async throws -> Analysis {
        try await Analyzer(context: try context(specs: specs), options: InstallOptions(update: update)).analyze()
    }

    @Test func unifiesDeclaredPackage() async throws {
        let fixture = try await SwiftPackageFixture.create(in: root)
        try writePodfile(packages: [(fixture.libURL, [">= 1.0.0", "< 2.0.0"])])
        let specs = [fixture.libSpec("1.0.0"), fixture.libSpec("2.0.0")]

        let analysis = try await analyze(specs: specs)
        #expect(analysis.pods.map(\.name) == ["Binary"])
        let unification = try #require(analysis.unifications.first)
        #expect(analysis.unifications.count == 1)
        #expect(unification.podRoot == "Lib")
        #expect(unification.packageURL == fixture.libURL)
        #expect(unification.allowedVersions == [Version(1, 0, 0)])
        #expect(unification.upperBound == Version(1, 0, 1))
        let packages = try #require(analysis.swiftPackages)
        let pin = try #require(packages.pins.first { $0.identity == "lib" })
        #expect(pin.version == Version(1, 0, 0))
        #expect(packages.libraryProducts["lib"] == ["LibCore"])
        #expect(!packages.resolvedFile.isEmpty)

        // The whole install goes through even though `Binary` depends on the unified pod.
        let plan = try await Installer(context: try context(specs: specs), options: InstallOptions()).install()
        #expect(plan.podTargets.map(\.name) == ["Binary"])
    }

    @Test func unifiesIndirectPackage() async throws {
        let fixture = try await SwiftPackageFixture.create(in: root)
        try writePodfile(packages: [(fixture.wrapperURL, [">= 1.0.0", "< 2.0.0"])])

        let analysis = try await analyze(specs: [fixture.libSpec("1.0.0"), fixture.libSpec("2.0.0")])
        #expect(analysis.pods.map(\.name) == ["Binary"])
        #expect(analysis.unifications.map(\.podRoot) == ["Lib"])
        #expect(analysis.unifications.first?.allowedVersions == [Version(1, 0, 0)])
        let packages = try #require(analysis.swiftPackages)
        #expect(packages.pins.map(\.identity) == ["lib", "wrapper"])
        #expect(packages.pins.first { $0.identity == "lib" }?.version == Version(1, 0, 0))
        #expect(packages.libraryProducts["wrapper"] == ["Wrapper"])
    }

    @Test func failsWhenPodfileRangeExcludesBinaryRequirement() async throws {
        let fixture = try await SwiftPackageFixture.create(in: root)
        try writePodfile(packages: [(fixture.libURL, [">= 2.0.0", "< 3.0.0"])])

        let error = await #expect(throws: PodsError.self) {
            try await analyze(specs: [fixture.libSpec("1.0.0"), fixture.libSpec("2.0.0")])
        }
        let message = error?.message ?? ""
        #expect(message.contains("Binary"))
        #expect(message.contains("~> 1.0"))
    }

    @Test func reinstallKeepsSwiftPackagePins() async throws {
        let fixture = try await SwiftPackageFixture.create(in: root)
        try writePodfile(packages: [(fixture.libURL, [">= 1.0.0", "< 2.0.0"])])
        // `install` records the pins under Pods/.
        try await Installer(context: try context(specs: [fixture.libSpec("1.0.0"), fixture.libSpec("2.0.0")]), options: InstallOptions()).install()
        let lockfile = try Lockfile(contentsOf: root.appendingPathComponent("Podfile.lock"))
        #expect(lockfile.swiftPackages.first?.version == Version(1, 0, 0))

        try await fixture.addLibPatchRelease()
        let specs = [fixture.libSpec("1.0.0"), fixture.libSpec("1.0.1"), fixture.libSpec("2.0.0")]
        let reinstall = try await analyze(specs: specs)
        #expect(reinstall.unifications.first?.allowedVersions == [Version(1, 0, 0), Version(1, 0, 1)])
        #expect(reinstall.swiftPackages?.pins.first { $0.identity == "lib" }?.version == Version(1, 0, 0))

        let updated = try await analyze(specs: specs, update: .all)
        #expect(updated.swiftPackages?.pins.first { $0.identity == "lib" }?.version == Version(1, 0, 1))
    }

    /// Installs the `unifiesDeclaredPackage` setup: `Binary` requires `Lib ~> 1.0` and the Podfile declares `lib` `>= 1.0.0, < 2.0.0`.
    private func installUnifiedLib() async throws -> SwiftPackageFixture {
        let fixture = try await SwiftPackageFixture.create(in: root)
        try writePodfile(packages: [(fixture.libURL, [">= 1.0.0", "< 2.0.0"])])
        try await Installer(context: try context(specs: [fixture.libSpec("1.0.0"), fixture.libSpec("2.0.0")]), options: InstallOptions()).install()
        return fixture
    }

    @Test func writesPackageReferencesIntoPodsProject() async throws {
        let fixture = try await installUnifiedLib()
        let project = try XcodeProj(path: Path(root.appendingPathComponent("Pods/Pods.xcodeproj").path))
        let rootObject = try #require(project.pbxproj.rootObject)
        #expect(rootObject.remotePackages.count == 1)
        let reference = try #require(rootObject.remotePackages.first)
        #expect(reference.repositoryURL == fixture.libURL)
        #expect(reference.versionRequirement == .range(from: "1.0.0", to: "1.0.1"))

        let binary = try #require(project.pbxproj.nativeTargets.first { $0.name == "Binary" })
        #expect(binary.packageProductDependencies?.map(\.productName) == ["LibCore"])
        #expect(binary.packageProductDependencies?.first?.package === reference)
        let aggregate = try #require(project.pbxproj.nativeTargets.first { $0.name == "Pods-App" })
        let linked = try aggregate.frameworksBuildPhase()?.files?.compactMap { $0.product?.productName } ?? []
        #expect(linked == ["LibCore"])
        #expect(aggregate.packageProductDependencies?.map(\.productName) == ["LibCore"])
        // The pod target only depends on the product; linking happens once, in the aggregate.
        #expect(try binary.frameworksBuildPhase()?.files?.contains { $0.product != nil } != true)
        #expect(!project.pbxproj.nativeTargets.contains { $0.name == "Lib" })
    }

    @Test func writesPackageResolvedUnderPods() async throws {
        _ = try await installUnifiedLib()
        let resolved = root.appendingPathComponent("Pods/Pods.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(try SwiftPackageResolver.pins(fromResolved: Data(contentsOf: resolved)).map(\.identity) == ["lib"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("App.xcworkspace/xcshareddata/swiftpm/Package.resolved").path))
    }

    @Test func recordsSwiftPackagesInLockfile() async throws {
        let fixture = try await installUnifiedLib()
        let lockfile = try Lockfile(contentsOf: root.appendingPathComponent("Podfile.lock"))
        #expect(lockfile.swiftPackages.count == 1)
        let package = try #require(lockfile.swiftPackages.first)
        #expect(package.pods == ["Lib"])
        #expect(package.version == Version(1, 0, 0))
        #expect(package.requirement == "(< 1.0.1, >= 1.0.0)")
        #expect(!package.revision.isEmpty)
        #expect(!lockfile.podNames.contains("Lib"))
        #expect(lockfile.specRepos.values.allSatisfy { !$0.contains("Lib") })
        #expect(lockfile.specChecksums["Lib"] == nil)
        // The lockfile read back equals the one a reinstall computes.
        try await Installer(context: try context(specs: [fixture.libSpec("1.0.0"), fixture.libSpec("2.0.0")]),
                            options: InstallOptions(deployment: true)).install()
    }

    @Test func deintegrateRemovesPackageReferences() async throws {
        _ = try await installUnifiedLib()
        try Deintegrator(projectDirectory: root, ui: .capturing()).deintegrate()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Pods").path))
    }

    /// Builds the app with xcodebuild: `Binary` calls into `Lib`, which comes from SwiftPM and must be linked exactly once.
    /// With `indirect`, `Lib` is only a dependency of the declared `Wrapper` package.
    /// Slow, so opt-in: `SWIFTPODS_XCODEBUILD=1 swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTPODS_XCODEBUILD"] == "1"), arguments: [false, true])
    func linksUnifiedPackageOnce(indirect: Bool) async throws {
        let fixture = try await SwiftPackageFixture.create(in: root)
        let binary = root.appendingPathComponent("LocalPods/Binary")
        try """
        {"name":"Binary","version":"1.0.0","platforms":{"ios":"12.0"},"source":{"git":"https://example.com/Binary.git","tag":"1.0.0"},
         "source_files":"*.{h,m}","public_header_files":"Binary.h","dependencies":{"Lib":["~> 1.0"]}}
        """.write(to: binary.appendingPathComponent("Binary.podspec.json"), atomically: true, encoding: .utf8)
        try "int BinaryValue(void);\n".write(to: binary.appendingPathComponent("Binary.h"), atomically: true, encoding: .utf8)
        try """
        #import "Binary.h"
        @import LibCore;

        int BinaryValue(void) { return LibValue() + 1; }

        """.write(to: binary.appendingPathComponent("Binary.m"), atomically: true, encoding: .utf8)
        try writePodfile(packages: [(indirect ? fixture.wrapperURL : fixture.libURL, [">= 1.0.0", "< 2.0.0"])])
        try await Installer(context: try context(specs: [fixture.libSpec("1.0.0"), fixture.libSpec("2.0.0")]), options: InstallOptions()).install()
        try """
        import SwiftUI
        import Binary

        @main
        struct FixtureApp: App {
            var body: some Scene { WindowGroup { Text("\\(BinaryValue())") } }
        }
        """.write(to: root.appendingPathComponent("App/App.swift"), atomically: true, encoding: .utf8)

        let output = try await Shell().execute([
            "xcodebuild", "-workspace", "App.xcworkspace", "-scheme", "App", "-configuration", "Debug",
            "-sdk", "iphonesimulator", "-derivedDataPath", root.appendingPathComponent("DerivedData").path,
            "CODE_SIGNING_ALLOWED=NO", "build",
        ], in: root)
        let log = output.stdout + output.stderr
        #expect(output.status == 0, "\(output.stdout.suffix(4000))\n\(output.stderr.suffix(2000))")
        #expect(!log.contains("duplicate symbol"))
        #expect(!log.contains("Undefined symbols"))
    }

    @Test func secondResolutionNarrowsDeclaredRange() async throws {
        let fixture = try await SwiftPackageFixture.create(in: root)
        let declared = (url: fixture.libURL, requirement: [">= 1.0.0", "< 3.0.0"])
        try writePodfile(packages: [declared])

        // With only the declared range, SwiftPM picks 2.0.0.
        let direct = try await SwiftPackageResolver(workDirectory: root.appendingPathComponent("direct"), shell: SwiftPackageFixture.shell)
            .resolve([(declared.url, nil, nil, try Requirement(parsing: declared.requirement))], previousResolved: nil)
        #expect(direct.pins.map(\.version) == [Version(2, 0, 0)])

        let analysis = try await analyze(specs: [fixture.libSpec("1.0.0"), fixture.libSpec("2.0.0")])
        #expect(analysis.unifications.first?.allowedVersions == [Version(1, 0, 0)])
        #expect(analysis.swiftPackages?.pins.map(\.version) == [Version(1, 0, 0)])
    }

    @Test func dropsPodsOnlyReachableThroughUnifiedPods() async throws {
        let fixture = try await SwiftPackageFixture.create(in: root)
        try writePodfile(packages: [(fixture.libURL, [">= 1.0.0", "< 2.0.0"])])
        // `LibDep` has no downloadable source: installing it as a pod would fail.
        let libDep = #"{"name":"LibDep","version":"1.0.0","platforms":{"ios":"12.0"},"source":{"http":"https://example.invalid/LibDep.zip"}}"#
        let dependencies = #"{"LibDep":["~> 1.0"]}"#
        let analysis = try await analyze(specs: [fixture.libSpec("1.0.0", dependencies: dependencies), libDep])
        #expect(analysis.unifications.map(\.podRoot) == ["Lib"])
        #expect(analysis.pods.map(\.name) == ["Binary"])
    }

    @Test func skipsOldPodVersionsOfVanishedRepositories() async throws {
        let fixture = try await SwiftPackageFixture.create(in: root)
        try writePodfile(packages: [(fixture.libURL, [">= 1.0.0", "< 2.0.0"])])
        let gone = "file://" + root.appendingPathComponent("Repos/Gone").path
        // An old `Lib` released from a repository that no longer exists.
        let oldLib = #"{"name":"Lib","version":"0.9.0","platforms":{"ios":"12.0"},"source":{"git":"\#(gone)","tag":"0.9.0"}}"#
        let ui = UI.capturing()
        let context = try InstallerContext(projectDirectory: root, cacheRoot: cache, ui: ui,
                                           sources: SourcesManager(sources: [try MemorySource([oldLib, fixture.libSpec("1.0.0")])]),
                                           shell: SwiftPackageFixture.shell)
        let analysis = try await Analyzer(context: context, options: InstallOptions()).analyze()
        #expect(analysis.unifications.map(\.allowedVersions) == [[Version(1, 0, 0)]])
        #expect(ui.warnings.contains { $0.contains("Lib 0.9.0") && $0.contains(gone) })
    }

    @Test func podfileWithoutPackagesSkipsSwiftPM() async throws {
        let fixture = try await SwiftPackageFixture.create(in: root)
        try writePodfile(packages: [])
        let analysis = try await analyze(specs: [fixture.libSpec("1.0.0")])
        #expect(analysis.pods.map(\.name).sorted() == ["Binary", "Lib"])
        #expect(analysis.unifications.isEmpty)
        #expect(analysis.swiftPackages == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("SwiftPackages").path))
    }
}
