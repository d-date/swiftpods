import Foundation
import PodsCore
import PodsManifest
@testable import PodsPodfile
import Testing

private func ruby(_ source: String, environment: [String: String] = [:]) throws -> Podfile {
    let json = try RubyPodfileEvaluator.evaluate(source: source, file: "Podfile", directory: URL(fileURLWithPath: "/tmp"), environment: environment)
    return try Podfile(json: json)
}

struct PodfileTests {
    @Test func rubyPodfile() throws {
        let podfile = try ruby("""
        source 'https://cdn.cocoapods.org/'
        platform :ios, '15.0'
        use_frameworks! :linkage => :static
        inhibit_all_warnings!

        def shared
          pod 'Alamofire', '~> 5.9'
        end

        target 'App' do
          shared
          pod 'MyKit', :path => '../MyKit'
          pod 'FLEX', '~> 5.0', :configurations => ['Debug']
          pod 'Firebase', :subspecs => ['Analytics', 'Crashlytics']

          target 'AppTests' do
            inherit! :search_paths
            pod 'Quick'
          end
        end

        abstract_target 'Extensions' do
          pod 'Common'
          target 'Widget' do
            platform :ios, '16.0'
          end
        end

        post_install do |installer|
          puts 'hi'
        end
        """)
        #expect(podfile.sources == ["https://cdn.cocoapods.org/"])
        #expect(podfile.unsupportedHooks == ["post_install"])

        let targets = podfile.resolvedTargets
        #expect(targets.map(\.name) == ["App", "AppTests", "Widget"])
        #expect(targets.map(\.label) == ["Pods-App", "Pods-App-AppTests", "Pods-Extensions-Widget"])

        let app = targets[0]
        #expect(app.platform == Platform(.ios, Version(15, 0)))
        #expect(app.usesFrameworks == FrameworkSettings(linkage: .static))
        #expect(app.inhibitAllWarnings)
        #expect(app.dependencies.map(\.name) == ["Alamofire", "MyKit", "FLEX", "Firebase/Analytics", "Firebase/Crashlytics"])
        #expect(app.dependencies[1].dependency.externalSource == .path("../MyKit"))
        #expect(app.dependencies[2].configurations == ["Debug"])

        // `inherit! :search_paths` does not link the host's pods.
        let tests = targets[1]
        #expect(tests.dependencies.map(\.name) == ["Quick"])
        #expect(tests.searchPathsTargets == ["Pods-App"])

        let widget = targets[2]
        #expect(widget.platform == Platform(.ios, Version(16, 0)))
        #expect(widget.dependencies.map(\.name) == ["Common"])
    }

    @Test func requirementAndExternalSourceConflict() {
        #expect(throws: Podfile.FormatError.self) {
            _ = try ruby("pod 'A', '~> 1.0', :path => '../A'")
        }
    }

    @Test func rejectsProductOfUndeclaredPackage() throws {
        let json = try JSON(parsing: """
        {"swift_packages":[],"target_definitions":[{"name":"Pods","abstract":true,"children":[{"name":"App",
        "swift_package_products":[{"name":"X","package":"Missing"}]}]}]}
        """)
        #expect {
            _ = try Podfile(json: json)
        } throws: { error in
            (error as? Podfile.FormatError)?.message.contains("`Missing`") == true
        }
    }

    @Test func podfileJSONFromCocoaPods() throws {
        // Output of `pod ipc podfile-json` for a small Podfile.
        let json = try JSON(parsing: """
        {"sources":["https://cdn.cocoapods.org/"],"target_definitions":[{"name":"Pods","abstract":true,
        "platform":{"ios":"14.0"},"children":[{"name":"App","uses_frameworks":true,
        "dependencies":["SnapKit",{"Kingfisher":["~> 7.0"]},{"Local":[{":path":"Local"}]}]}]}]}
        """)
        let podfile = try Podfile(json: json)
        let app = try #require(podfile.resolvedTargets.first)
        #expect(app.platform == Platform(.ios, Version(14, 0)))
        #expect(app.usesFrameworks == FrameworkSettings(linkage: .dynamic))
        #expect(app.dependencies.map(\.name) == ["SnapKit", "Kingfisher", "Local"])
        #expect(app.dependencies[2].dependency.externalSource == .path("Local"))
    }

    @Test func loaderPrefersSwiftManifest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "".write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        #expect(PodfileLoader.podfileURL(in: directory)?.lastPathComponent == "Podfile")
        try "".write(to: directory.appendingPathComponent("Podfile.swift"), atomically: true, encoding: .utf8)
        #expect(PodfileLoader.podfileURL(in: directory)?.lastPathComponent == "Podfile.swift")
    }

    /// The Ruby and Swift manifests describing the same project must produce the same model.
    @Test func swiftAndRubyManifestsAreEquivalent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let swiftURL = directory.appendingPathComponent("Podfile.swift")
        try """
        import SwiftPodsDescription

        let podfile = Podfile(
            sources: [.trunk],
            platform: .iOS(.v15),
            useFrameworks: .static,
            targets: [
                .target(
                    name: "App",
                    dependencies: [
                        .pod(name: "Alamofire", "~> 5.9"),
                        .pod(name: "MyKit", path: "../MyKit"),
                    ],
                    targets: [
                        .target(name: "AppTests", inherit: .searchPaths, dependencies: [.pod(name: "Quick")]),
                    ]
                ),
            ]
        )
        """.write(to: swiftURL, atomically: true, encoding: .utf8)
        let loader = PodfileLoader(environment: [:], swiftEvaluator: .init(cacheDirectory: directory.appendingPathComponent("cache")))
        let fromSwift = try await loader.load(swiftURL)
        let fromRuby = try ruby("""
        source 'https://cdn.cocoapods.org/'
        platform :ios, '15.0'
        use_frameworks! :linkage => :static
        target 'App' do
          pod 'Alamofire', '~> 5.9'
          pod 'MyKit', :path => '../MyKit'
          target 'AppTests' do
            inherit! :search_paths
            pod 'Quick'
          end
        end
        """)
        #expect(fromSwift.resolvedTargets == fromRuby.resolvedTargets)
        #expect(fromSwift.effectiveSources == fromRuby.effectiveSources)
    }
}
