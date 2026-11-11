import Foundation
import PodsCore
@testable import PodsInstaller
import PodsSources
import PodsSpec
import Testing

/// An in-memory spec source built from compact JSON specs.
private struct MemorySource: SpecSource {
    let url = "memory"
    let lockfileName = "trunk"
    let specs: [String: [Version: Specification]]

    init(_ jsonSpecs: [String]) throws {
        var specs: [String: [Version: Specification]] = [:]
        for json in jsonSpecs {
            let spec = try Specification(json: try JSON(parsing: json))
            specs[spec.name, default: [:]][spec.version] = spec
        }
        self.specs = specs
    }

    func versions(of name: String) async throws -> [Version] { Array(specs[name]?.keys ?? [:].keys) }
    func specification(of name: String, version: Version) async throws -> Specification {
        guard let spec = specs[name]?[version] else { throw PodsError("missing \(name) \(version)") }
        return spec
    }
    func update() async throws {}
}

private func spec(_ name: String, _ version: String, dependencies: [String: String] = [:]) -> String {
    let deps = dependencies.map { #""\#($0.key)": ["\#($0.value)"]"# }.joined(separator: ",")
    return #"{"name":"\#(name)","version":"\#(version)","platforms":{"ios":"12.0"},"dependencies":{\#(deps)}}"#
}

struct OutdatedTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-outdated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try FixtureProject.create(in: root)
        try """
        platform :ios, '16.0'

        target 'App' do
          pod 'Firebase', '~> 1.0'
        end
        """.write(to: root.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        try """
        PODS:
          - Core (1.0.0)
          - Firebase (1.0.0):
            - Core (~> 1.0)
          - Legacy (1.0.0)

        DEPENDENCIES:
          - Firebase (~> 1.0)

        SPEC REPOS:
          trunk:
            - Core
            - Firebase
            - Legacy

        SPEC CHECKSUMS:
          Core: 0000000000000000000000000000000000000000
          Firebase: 0000000000000000000000000000000000000000
          Legacy: 0000000000000000000000000000000000000000

        PODFILE CHECKSUM: 0000000000000000000000000000000000000000

        COCOAPODS: 1.16.2

        """.write(to: root.appendingPathComponent("Podfile.lock"), atomically: true, encoding: .utf8)
    }

    @Test func allowedVersionsRespectTransitiveRequirements() async throws {
        let source = try MemorySource([
            spec("Firebase", "1.0.0", dependencies: ["Core": "~> 1.0"]),
            spec("Firebase", "1.2.0", dependencies: ["Core": "~> 1.0"]),
            spec("Firebase", "2.0.0", dependencies: ["Core": "~> 2.0"]),
            spec("Core", "1.0.0"), spec("Core", "1.5.0"), spec("Core", "2.0.0"),
            spec("Legacy", "1.0.0"), spec("Legacy", "1.1.0"),
        ])
        let context = try InstallerContext(projectDirectory: root, cacheRoot: root.appendingPathComponent(".cache"),
                                           ui: .capturing(), sources: SourcesManager(sources: [source]))
        let entries = try await OutdatedChecker(context: context).check()

        #expect(entries == [
            // `Firebase ~> 1.0` (via Firebase 1.2.0) caps Core below 2.0.
            .init(name: "Core", current: Version(1, 0, 0), allowed: Version(1, 5, 0), latest: Version(2, 0, 0)),
            .init(name: "Firebase", current: Version(1, 0, 0), allowed: Version(1, 2, 0), latest: Version(2, 0, 0)),
            // No longer required by the Podfile.
            .init(name: "Legacy", current: Version(1, 0, 0), allowed: nil, latest: Version(1, 1, 0)),
        ])
    }
}
