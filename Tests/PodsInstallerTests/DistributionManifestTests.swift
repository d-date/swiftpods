import Foundation
import PodsCore
import PodsPodfile
@testable import PodsInstaller
import PodsSpec
import Testing

private func swiftAvailable() async -> Bool {
    (try? await Shell().execute(["swift", "--version"]).status) == 0
}

struct DistributionManifestTests {
    static let settings = DistributionSettings(name: "Acme", url: "https://github.com/acme/acme-dist")
    static let platform = Platform(.ios, Version(15, 0))
    static let layout = DistributionLayout(
        products: [
            .init(name: "Alpha", targets: ["Alpha", "Common"]),
            .init(name: "Beta", targets: ["Beta", "Shared", "Common"]),
        ],
        commonTargets: ["Core"],
        binaryTargets: ["Alpha", "Beta", "Core", "Shared"],
        unifiedPackageURLs: [],
        warnings: []
    )

    static func checksums(reversed: Bool = false) -> [String: String] {
        let names = ["Alpha", "Beta", "Core", "Shared"]
        var result: [String: String] = [:]
        for (index, name) in (reversed ? names.reversed() : names).enumerated() {
            result[name] = String(repeating: "0", count: 63) + String(names.firstIndex(of: name) ?? index)
        }
        return result
    }

    static let dependencies: [DistributionManifest.Dependency] = [
        .init(url: "https://github.com/google/promises.git", requirement: .exact(Version(2, 4, 0)), products: ["FBLPromises"]),
        .init(url: "https://github.com/google/GoogleUtilities.git", requirement: .closedRange(Version(8, 0, 0), Version(8, 1, 0)),
              products: ["GULNSData", "GULLogger"]),
        .init(url: "https://github.com/firebase/nanopb.git",
              requirement: .unsafe(lower: Version(2, 30910, 0), upper: Version(2, 30911, 0), warning: "nanopb is \"unsafe\"\nhere"),
              products: ["nanopb"]),
    ]

    static func render(dependencies: [DistributionManifest.Dependency] = dependencies, checksums: [String: String] = checksums()) -> String {
        DistributionManifest.render(settings: settings, version: "1.2.3", platform: platform, layout: layout,
                                    checksums: checksums, dependencies: dependencies)
    }

    private static var goldenURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Distribution/Package.swift.golden")
    }

    @Test func rendersGoldenManifest() throws {
        let golden = try String(contentsOf: Self.goldenURL, encoding: .utf8)
        #expect(Self.render() == golden)
    }

    @Test(.enabled("requires swift") { await swiftAvailable() })
    func goldenManifestParses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let common = root.appendingPathComponent("Sources/Common")
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        try Data("@_exported import Core\n".utf8).write(to: common.appendingPathComponent("export.swift"))
        try Data(Self.render().utf8).write(to: root.appendingPathComponent("Package.swift"))

        let output = try await Shell().run("swift", ["package", "dump-package"], in: root)
        #expect(output.stdout.contains("\"name\" : \"Acme\""))
    }

    @Test func renderingIsDeterministic() {
        let first = Self.render()
        let second = Self.render(dependencies: Self.dependencies.reversed(), checksums: Self.checksums(reversed: true))
        #expect(first == second)
    }

    @Test func warningPerUnsafeDependency() {
        let manifest = Self.render()
        #expect(manifest.components(separatedBy: "#warning(").count - 1 == 1)
        #expect(manifest.contains(#"#warning("nanopb is \"unsafe\"\nhere")"#))
    }

    @Test func commonExportsSorted() {
        let layout = DistributionLayout(products: [], commonTargets: ["Zeta", "Alpha"], binaryTargets: [], unifiedPackageURLs: [], warnings: [])
        #expect(DistributionManifest.renderCommonExports(layout: layout) == "@_exported import Alpha\n@_exported import Zeta\n")
    }
}

struct ResourceBundlesTests {
    private func makePod(_ name: String, in root: URL, json extra: String, directories: [String]) throws -> InstalledPod {
        let location = root.appendingPathComponent(name)
        for directory in directories {
            try FileManager.default.createDirectory(at: location.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let spec = try Specification(json: JSON(parsing: #"{"name": "\#(name)", "version": "1.0", "platforms": {"ios": "12.0"}\#(extra)}"#))
        return InstalledPod(spec: spec, activatedSpecs: [name], sourceName: nil, externalSource: nil, location: location,
                            isLocal: false, checkoutOptions: [:])
    }

    @Test func deduplicatesBundlesByName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-bundles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pod = try makePod("Pod", in: root,
                              json: #", "vendored_frameworks": "Frameworks/Pod.framework", "resource_bundles": {"A": "Resources/A/*"}"#,
                              directories: ["Resources/A", "Frameworks/Pod.framework/A.bundle", "Frameworks/Pod.framework/Sub/B.bundle"])
        let other = try makePod("Other", in: root, json: #", "resource_bundles": {"C": "Resources/C/*"}"#, directories: ["Resources/C"])
        let bundles = ResourceBundles.collect(pods: [pod, other], podsWithBinary: ["Pod"])

        #expect(bundles.map(\.name) == ["A", "B"])
        #expect(bundles[0].directory.path == root.appendingPathComponent("Pod/Resources/A").path)
        #expect(bundles[1].directory.lastPathComponent == "B.bundle")
    }
}
