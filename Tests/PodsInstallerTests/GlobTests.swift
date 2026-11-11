import Foundation
@testable import PodsInstaller
import Testing

struct GlobTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-glob-\(UUID().uuidString)")
        for path in [
            "Sources/A.swift", "Sources/Nested/B.swift", "Sources/Nested/C.h", "Sources/Nested/C.m",
            "Sources/Docs.docc/Resources/code/Example.swift", "Sources/.hidden/D.swift",
            "Resources/en.lproj/Localizable.strings", "Resources/Images.xcassets/Contents.json",
            "Vendor/Lib.framework/Headers/Lib.h", "README.md",
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    func match(_ patterns: [String], extensions: Set<String>? = nil) -> [String] {
        let glob = Glob(root: root)
        return glob.match(patterns, directoryExtensions: extensions, in: glob.allPaths())
    }

    @Test func recursiveWildcardsAndBraces() {
        #expect(match(["Sources/**/*.{swift,h}"]) == ["Sources/A.swift", "Sources/Nested/B.swift", "Sources/Nested/C.h"])
        #expect(match(["Sources/*.swift"]) == ["Sources/A.swift"])
        #expect(match(["Sources/Nested/?.m"]) == ["Sources/Nested/C.m"])
    }

    @Test func opaqueDirectoriesAndHiddenFilesAreSkipped() {
        let all = match(["**/*.swift"])
        #expect(!all.contains { $0.contains(".docc") || $0.contains(".hidden") })
        #expect(match(["Resources/*"]) == ["Resources/Images.xcassets", "Resources/en.lproj"])
        #expect(match(["Resources/**/*.strings"]) == ["Resources/en.lproj/Localizable.strings"])
        #expect(match(["Vendor/*.framework"]) == ["Vendor/Lib.framework"])
    }

    @Test func directoryPatternsExpandToSourceFiles() {
        #expect(match(["Sources/Nested"], extensions: ["swift", "h", "m"]) == ["Sources/Nested/B.swift", "Sources/Nested/C.h", "Sources/Nested/C.m"])
        // Trailing slashes are allowed (e.g. Moya's `Sources/Moya/`).
        #expect(match(["Sources/Nested/"], extensions: ["swift"]) == ["Sources/Nested/B.swift"])
    }

    @Test func braceExpansion() {
        #expect(Glob.expandBraces("a/{b,c/{d,e}}.x") == ["a/b.x", "a/c/d.x", "a/c/e.x"])
    }
}
