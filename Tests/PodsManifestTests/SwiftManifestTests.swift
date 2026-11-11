import Foundation
import PodsCore
@testable import PodsManifest
import Testing

/// These tests invoke the Swift compiler, so they are slower than the rest of the suite.
@Suite(.serialized)
struct SwiftManifestTests {
    let directory: URL
    let evaluator: SwiftManifestEvaluator

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        evaluator = SwiftManifestEvaluator(cacheDirectory: directory.appendingPathComponent("cache"))
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func evaluatesPodfile() async throws {
        let url = try write("Podfile.swift", """
        import SwiftPodsDescription

        let useLocal = false

        let podfile = Podfile(
            sources: [.trunk],
            platform: .iOS(.v15),
            useFrameworks: .static,
            targets: [
                .target(
                    name: "App",
                    dependencies: [
                        .pod(name: "Alamofire", from: "5.9.0"),
                        useLocal
                            ? .pod(name: "MyKit", path: "../MyKit")
                            : .pod(name: "MyKit", git: "https://example.com/MyKit.git", tag: "1.0.0"),
                        .pod(name: "FLEX", "~> 5.0", configurations: ["Debug"]),
                        .pod(name: "Nuke", "12.0.0"..<"13.0.0"),
                    ],
                    targets: [
                        .target(name: "AppTests", inherit: .searchPaths, dependencies: [.pod(name: "Quick")]),
                    ]
                ),
            ]
        )

        // Like Package.swift, the manifest can be modified after creation.
        podfile.targets.append(.target(name: "Widget", platform: .iOS("16.4")))
        """)
        let json = try await evaluator.evaluatePodfile(at: url)
        #expect(json["sources"]?.stringList == ["https://cdn.cocoapods.org/"])
        let root = try #require(json["target_definitions"]?.array?.first)
        #expect(root["name"]?.string == "Pods")
        #expect(root["abstract"]?.bool == true)
        #expect(root["platform"]?["ios"]?.string == "15.0")
        #expect(root["uses_frameworks"]?["linkage"]?.string == "static")
        let children = try #require(root["children"]?.array)
        #expect(children.map { $0["name"]?.string } == ["App", "Widget"])
        #expect(children[1]["platform"]?["ios"]?.string == "16.4")
        let dependencies = try #require(children[0]["dependencies"]?.array)
        #expect(dependencies[0]["Alamofire"]?.stringList == [">= 5.9.0", "< 6.0.0"])
        #expect(dependencies[1]["MyKit"]?.array?.first?["tag"]?.string == "1.0.0")
        #expect(dependencies[2]["FLEX"]?.array?.first?.string == "~> 5.0")
        #expect(dependencies[2]["FLEX"]?.array?.last?["configurations"]?.stringList == ["Debug"])
        #expect(dependencies[3]["Nuke"]?.stringList == [">= 12.0.0", "< 13.0.0"])
        let tests = try #require(children[0]["children"]?.array?.first)
        #expect(tests["inheritance"]?.string == "search_paths")
        #expect(tests["dependencies"]?.array?.first?.string == "Quick")
    }

    @Test func evaluatesPodspec() async throws {
        let url = try write("MyKit.podspec.swift", """
        import SwiftPodsDescription

        let podspec = PodSpec(
            name: "MyKit",
            version: "1.0.0",
            summary: "My kit",
            license: .mit(file: "LICENSE"),
            authors: ["Jane": "jane@example.com"],
            source: .git(url: "https://example.com/MyKit.git", tag: "1.0.0"),
            platforms: [.iOS(.v15), .macOS("13.0")],
            swiftVersions: ["5.9"],
            sourceFiles: ["Sources/**/*.swift"],
            dependencies: [.pod(name: "Alamofire", from: "5.9.0")],
            platformSpecific: [.iOS(.init(frameworks: ["UIKit"]))],
            subspecs: [
                .subspec(name: "Core", sourceFiles: ["Sources/Core/**/*.swift"]),
            ],
            testSpecs: [
                .testSpec(sourceFiles: ["Tests/**/*.swift"]),
            ]
        )
        """)
        let json = try await evaluator.evaluateSpec(at: url)
        #expect(json["name"]?.string == "MyKit")
        #expect(json["version"]?.string == "1.0.0")
        #expect(json["license"]?["type"]?.string == "MIT")
        #expect(json["platforms"]?["ios"]?.string == "15.0")
        #expect(json["platforms"]?["osx"]?.string == "13.0")
        #expect(json["ios"]?["frameworks"]?.stringList == ["UIKit"])
        #expect(json["dependencies"]?["Alamofire"]?.stringList == [">= 5.9.0", "< 6.0.0"])
        #expect(json["subspecs"]?.array?.first?["name"]?.string == "Core")
        #expect(json["testspecs"]?.array?.first?["test_type"]?.string == "unit")
    }

    @Test func diagnosticsPointAtTheManifest() async throws {
        let url = try write("Broken.podspec.swift", """
        import SwiftPodsDescription

        let podspec = PodSpec(
            name: "X",
            version: "1.0",
            notAnAttribute: 1
        )
        """)
        do {
            _ = try await evaluator.evaluateSpec(at: url)
            Issue.record("Expected a compilation error")
        } catch let error as SwiftManifestEvaluator.CompilationError {
            #expect(error.diagnostics.contains("Broken.podspec.swift:6:"), "\(error.diagnostics)")
        }
    }

    @Test func wrongManifestKindIsRejected() async throws {
        let url = try write("Podfile.swift", """
        import SwiftPodsDescription
        let podspec = PodSpec(name: "X", version: "1.0")
        """)
        await #expect(throws: PodsError.self) {
            _ = try await evaluator.evaluatePodfile(at: url)
        }
    }
}
