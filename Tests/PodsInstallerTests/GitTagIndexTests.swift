import Foundation
import PodsCore
@testable import PodsInstaller
import Testing

struct GitTagIndexTests {
    let root: URL
    let shell = Shell(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test func peelsAnnotatedAndVPrefixedTags() async throws {
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await shell.run("git", ["init", "--quiet", "-b", "main", repo.path])
        try "1\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await shell.run("git", ["-C", repo.path, "add", "."])
        try await shell.run("git", ["-C", repo.path, "commit", "--quiet", "-m", "one"])
        let first = try await shell.run("git", ["-C", repo.path, "rev-parse", "HEAD"]).stdout.trimmingWhitespace()
        try await shell.run("git", ["-C", repo.path, "tag", "CocoaPods-1.0.0"])
        try await shell.run("git", ["-C", repo.path, "tag", "1.0.0"])
        try "2\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await shell.run("git", ["-C", repo.path, "commit", "--quiet", "-am", "two"])
        let second = try await shell.run("git", ["-C", repo.path, "rev-parse", "HEAD"]).stdout.trimmingWhitespace()
        try await shell.run("git", ["-C", repo.path, "tag", "-a", "v2.0.0", "-m", "x"])

        let index = GitTagIndex(shell: shell)
        let tags = try await index.tags(of: "file://" + repo.path)
        #expect(tags["1.0.0"] == first)
        #expect(tags["CocoaPods-1.0.0"] == first)
        #expect(tags["v2.0.0"] == second)

        // The second call is served from memory even if the repository disappears.
        try FileManager.default.removeItem(at: repo)
        #expect(try await index.tags(of: "file://" + repo.path) == tags)

        #expect(GitTagIndex.swiftPMVersion(fromTag: "v2.0.0") == Version(2, 0, 0))
        #expect(GitTagIndex.swiftPMVersion(fromTag: "CocoaPods-1.0.0") == nil)
    }

    @Test func ignoresTagsWithMoreThanThreeReleaseComponents() {
        // SwiftPM does not treat `1.2.3.4` as a version.
        #expect(GitTagIndex.swiftPMVersion(fromTag: "1.2.3.4") == nil)
        #expect(GitTagIndex.swiftPMVersion(fromTag: "v1.2.3.4") == nil)
        #expect(GitTagIndex.swiftPMVersion(fromTag: "1.2.3") == Version(1, 2, 3))
    }
}
