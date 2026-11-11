import Foundation
import PathKit
import PodsCore
@testable import PodsInstaller
import PodsLockfile
import PodsSources
import Testing
import XcodeProj

@Suite(.serialized)
struct InstallerTests {
    let root: URL
    let cache: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-install-\(UUID().uuidString)")
        cache = root.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try FixtureProject.create(in: root)
        try FixtureProject.createLocalPods(in: root)
        try """
        platform :ios, '16.0'

        target 'App' do
          pod 'Greeter', :path => 'LocalPods/Greeter'
          pod 'Decorator', :path => 'LocalPods/Decorator'

          target 'AppTests' do
            inherit! :search_paths
          end
        end
        """.write(to: root.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func install(_ options: InstallOptions = InstallOptions()) async throws -> InstallationPlan {
        let context = try InstallerContext(projectDirectory: root, cacheRoot: cache, ui: .capturing(), sources: SourcesManager(sources: []))
        return try await Installer(context: context, options: options).install()
    }

    @Test func installsLocalPodsAndIntegratesTheProject() async throws {
        let plan = try await install()
        #expect(plan.podTargets.map(\.name) == ["Decorator", "Greeter"])
        #expect(plan.aggregateTargets.map(\.label) == ["Pods-App", "Pods-App-AppTests"])

        // Lockfile
        let lockfile = try Lockfile(contentsOf: root.appendingPathComponent("Podfile.lock"))
        #expect(lockfile.podNames == ["Decorator", "Greeter"])
        #expect(lockfile.externalSources["Greeter"] == [":path": "LocalPods/Greeter"])
        #expect(lockfile.pods.first { $0.name == "Greeter" }?.dependencies == ["Decorator"])
        #expect(try String(contentsOf: root.appendingPathComponent("Pods/Manifest.lock"), encoding: .utf8)
            == String(contentsOf: root.appendingPathComponent("Podfile.lock"), encoding: .utf8))

        // Pods project
        let pods = try XcodeProj(path: Path(root.appendingPathComponent("Pods/Pods.xcodeproj").path))
        let targetNames = Set(pods.pbxproj.nativeTargets.map(\.name))
        #expect(targetNames == ["Decorator", "Greeter", "Greeter-GreeterResources", "Pods-App", "Pods-App-AppTests"])
        let greeter = try #require(pods.pbxproj.nativeTargets.first { $0.name == "Greeter" })
        #expect(greeter.dependencies.compactMap(\.target?.name).sorted() == ["Decorator", "Greeter-GreeterResources"])
        let sources = try #require(try greeter.sourcesBuildPhase()?.files?.compactMap { $0.file?.path })
        #expect(sources.contains("Greeter.swift"))

        // Aggregate xcconfig
        let xcconfig = try String(contentsOf: root.appendingPathComponent("Pods/Target Support Files/Pods-App/Pods-App.debug.xcconfig"), encoding: .utf8)
        #expect(xcconfig.contains(#"-l"Greeter""#))
        #expect(xcconfig.contains(#"-l"Decorator""#))
        #expect(xcconfig.contains("PODS_ROOT = ${SRCROOT}/Pods"))
        #expect(xcconfig.contains(#"SWIFT_INCLUDE_PATHS = $(inherited) "${PODS_CONFIGURATION_BUILD_DIR}/Greeter""#))
        #expect(xcconfig.contains("Decorator.modulemap"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Pods/Headers/Public/Decorator/SPDecorator.h").path))

        // User project
        let app = try XcodeProj(path: Path(root.appendingPathComponent("App.xcodeproj").path))
        let appTarget = try #require(app.pbxproj.nativeTargets.first { $0.name == "App" })
        let base = appTarget.buildConfigurationList?.buildConfigurations.first { $0.name == "Debug" }?.baseConfiguration?.path
        #expect(base == "Pods/Target Support Files/Pods-App/Pods-App.debug.xcconfig")
        let phases = appTarget.buildPhases.compactMap { ($0 as? PBXShellScriptBuildPhase)?.name }
        #expect(phases == ["[CP] Check Pods Manifest.lock", "[CP] Copy Pods Resources"])
        #expect(try appTarget.frameworksBuildPhase()?.files?.compactMap { $0.file?.path } == ["libPods-App.a"])

        // Workspace
        let workspace = try String(contentsOf: root.appendingPathComponent("App.xcworkspace/contents.xcworkspacedata"), encoding: .utf8)
        #expect(workspace.contains("group:App.xcodeproj"))
        #expect(workspace.contains("group:Pods/Pods.xcodeproj"))
    }

    @Test func reinstallingIsIdempotent() async throws {
        try await install()
        let projectFile = root.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let first = try String(contentsOf: projectFile, encoding: .utf8)
        let firstPods = try String(contentsOf: root.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj"), encoding: .utf8)
        try await install()
        #expect(try String(contentsOf: projectFile, encoding: .utf8) == first)
        #expect(try String(contentsOf: root.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj"), encoding: .utf8) == firstPods)
    }

    @Test func frameworksModeEmbedsFrameworks() async throws {
        let podfile = root.appendingPathComponent("Podfile")
        try (try String(contentsOf: podfile, encoding: .utf8)).replacingOccurrences(of: "platform :ios, '16.0'", with: "platform :ios, '16.0'\nuse_frameworks!")
            .write(to: podfile, atomically: true, encoding: .utf8)
        let plan = try await install()
        #expect(plan.podTargets.allSatisfy { $0.buildType == .dynamicFramework })
        let xcconfig = try String(contentsOf: root.appendingPathComponent("Pods/Target Support Files/Pods-App/Pods-App.debug.xcconfig"), encoding: .utf8)
        #expect(xcconfig.contains(#"-framework "Greeter""#))
        let script = try String(contentsOf: root.appendingPathComponent("Pods/Target Support Files/Pods-App/Pods-App-frameworks.sh"), encoding: .utf8)
        #expect(script.contains(#"install_framework "${BUILT_PRODUCTS_DIR}/Greeter/Greeter.framework""#))
        let app = try XcodeProj(path: Path(root.appendingPathComponent("App.xcodeproj").path))
        let appTarget = try #require(app.pbxproj.nativeTargets.first { $0.name == "App" })
        #expect(appTarget.buildPhases.compactMap { ($0 as? PBXShellScriptBuildPhase)?.name } == ["[CP] Check Pods Manifest.lock", "[CP] Embed Pods Frameworks"])
        #expect(try appTarget.frameworksBuildPhase()?.files?.compactMap { $0.file?.path } == ["Pods_App.framework"])
    }

    @Test func deintegrateRemovesIntegration() async throws {
        try await install()
        try Deintegrator(projectDirectory: root, ui: .capturing()).deintegrate()
        let app = try XcodeProj(path: Path(root.appendingPathComponent("App.xcodeproj").path))
        let appTarget = try #require(app.pbxproj.nativeTargets.first { $0.name == "App" })
        #expect(appTarget.buildPhases.compactMap { $0 as? PBXShellScriptBuildPhase }.isEmpty)
        #expect(appTarget.buildConfigurationList?.buildConfigurations.allSatisfy { $0.baseConfiguration == nil } == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Pods").path))
    }

    /// Builds the integrated workspace with xcodebuild. Slow, so opt-in: `SWIFTPODS_XCODEBUILD=1 swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTPODS_XCODEBUILD"] == "1"), arguments: [false, true])
    func integratedWorkspaceBuilds(useFrameworks: Bool) async throws {
        if useFrameworks {
            let podfile = root.appendingPathComponent("Podfile")
            try (try String(contentsOf: podfile, encoding: .utf8)).replacingOccurrences(of: "platform :ios, '16.0'", with: "platform :ios, '16.0'\nuse_frameworks!")
                .write(to: podfile, atomically: true, encoding: .utf8)
        }
        try await install()
        // Use the pods from the app so that linking is exercised.
        try """
        import SwiftUI
        import Greeter

        @main
        struct FixtureApp: App {
            var body: some Scene { WindowGroup { Text(Greeter.greet("SwiftPods")) } }
        }
        """.write(to: root.appendingPathComponent("App/App.swift"), atomically: true, encoding: .utf8)
        let output = try await Shell().execute([
            "xcodebuild", "-workspace", "App.xcworkspace", "-scheme", "App", "-configuration", "Debug",
            "-sdk", "iphonesimulator", "-derivedDataPath", root.appendingPathComponent("DerivedData").path,
            "CODE_SIGNING_ALLOWED=NO", "build",
        ], in: root)
        #expect(output.status == 0, "\(output.stdout.suffix(4000))\n\(output.stderr.suffix(2000))")
    }
}
