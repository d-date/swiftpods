import Foundation
import PodsCore
@testable import PodsInstaller
import PodsSpec
import Testing

/// A package checkout and the podspec of the same library, split differently: the package has a product per part and
/// one bundling two parts, a target only reached as a dependency, a target in no product and a test target.
@Suite(.serialized)
struct PackageProductSelectorTests {
    static let url = "https://example.com/Kit.git"
    let root: URL
    let package: PackageContents
    let spec: Specification

    init() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-selector-\(UUID().uuidString)")
        self.root = root
        func write(_ contents: String, _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("""
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Kit",
            products: [
                .library(name: "Kit", targets: ["KitCore", "KitFull"]),
                .library(name: "KitCore", targets: ["KitCore"]),
                .library(name: "KitFull", targets: ["KitFull"]),
                .library(name: "KitTestHelpers", targets: ["KitTestHelpers"]),
            ],
            targets: [
                .target(name: "KitCore", dependencies: ["Internal"], path: "Sources/Core", exclude: ["README.md"]),
                .target(name: "Internal", path: "third_party/Internal"),
                .target(name: "KitFull", dependencies: ["KitCore"], path: "Sources/Full"),
                .target(name: "KitTestHelpers", dependencies: ["KitCore"], path: "Sources/TestHelpers"),
                .target(name: "Orphan", path: "Sources/Orphan"),
                .testTarget(name: "KitTests", dependencies: ["KitCore"], path: "Tests"),
            ]
        )
        """, "Package.swift")
        for (directory, name) in [("Sources/Core", "Core"), ("third_party/Internal", "Internal"), ("Sources/Full", "Full"),
                                  ("Sources/TestHelpers", "TestHelpers"), ("Sources/Orphan", "Orphan")] {
            try write("int \(name)Value(void) { return 1; }\n", "\(directory)/\(name).c")
            try write("int \(name)Value(void);\n", "\(directory)/include/\(name).h")
        }
        try write("Read me.\n", "Sources/Core/README.md")
        try write("int TestValue(void) { return 1; }\n", "Tests/KitTests.c")
        try write("int UnusedValue(void) { return 1; }\n", "Unused/Unused.c")

        let dump = try await Shell().run("swift", ["package", "dump-package"], in: root)
        package = PackageContents(dump: try JSON(parsing: dump.stdout), checkout: root)
        spec = try Specification(json: JSON(parsing: """
        {"name": "Kit", "version": "1.0.0", "platforms": {"ios": "15.0"}, "subspecs": [
          {"name": "Core", "source_files": ["Sources/Core/**/*.{c,h}", "third_party/Internal/*.c"]},
          {"name": "Full", "source_files": "Sources/Full/**/*.{c,h}", "dependencies": {"Kit/Core": []}},
          {"name": "Resources", "resource_bundles": {"Kit": "Resources/*"}},
          {"name": "Orphan", "source_files": "Sources/Orphan/*.c"},
          {"name": "Unused", "source_files": "Unused/*.c"},
          {"name": "Tests", "source_files": "Tests/*.c"}
        ]}
        """))
    }

    private func select(_ subspecs: String...) throws -> [String] {
        try PackageProductSelector.select(podRoot: "Kit", specs: subspecs.map { try #require(spec.subspec(named: "Kit/\($0)")) },
                                          platforms: [.ios], package: package, packageURL: Self.url)
    }

    @Test func readsTargetsAndLibraryProducts() {
        #expect(package.targets.map(\.name).sorted() == ["Internal", "KitCore", "KitFull", "KitTestHelpers", "Orphan"])
        #expect(package.targets.first { $0.name == "KitCore" }?.dependencies == ["Internal"])
        #expect(package.libraryProducts.map(\.name) == ["Kit", "KitCore", "KitFull", "KitTestHelpers"])
        let core = package.targets.first { $0.name == "KitCore" }!
        #expect(package.files(of: core) == ["Sources/Core/Core.c", "Sources/Core/include/Core.h"])
    }

    /// The smallest product listing the matched target; `Internal`, in no product, comes with `KitCore`'s dependencies.
    @Test func choosesSmallestProductPerMatchedTarget() throws {
        #expect(try select("Core") == ["KitCore"])
        #expect(try select("Core", "Full") == ["KitCore", "KitFull"])
        // A spec without source files needs no product.
        #expect(try select("Core", "Resources") == ["KitCore"])
    }

    @Test func rejectsSpecMatchingNoTarget() {
        #expect(throws: PodsError.self) { try select("Unused") }
        // Test targets are not library code.
        #expect(throws: PodsError.self) { try select("Tests") }
    }

    @Test func rejectsTargetInNoProduct() {
        let error = #expect(throws: PodsError.self) { try select("Orphan") }
        #expect(error?.message.contains("Orphan") == true)
    }
}
