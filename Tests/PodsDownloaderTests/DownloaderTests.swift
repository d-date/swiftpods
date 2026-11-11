import Foundation
import PodsCore
import PodsSpec
@testable import PodsDownloader
import Testing

struct DownloaderTests {
    let root: URL
    let shell = Shell(environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Creates a git repo with a tagged commit and returns its URL.
    private func makeRepository() async throws -> URL {
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "let x = 1\n".write(to: repo.appendingPathComponent("Sources/X.swift"), atomically: true, encoding: .utf8)
        try await shell.run("git", ["init", "--quiet", "-b", "main", repo.path])
        try await shell.run("git", ["-C", repo.path, "add", "."])
        try await shell.run("git", ["-C", repo.path, "commit", "--quiet", "-m", "init"])
        try await shell.run("git", ["-C", repo.path, "tag", "1.0.0"])
        return repo
    }

    @Test func clonesTagsAndCaches() async throws {
        let repo = try await makeRepository()
        let downloader = Downloader(cacheDirectory: root.appendingPathComponent("cache"), shell: shell, ui: .capturing())
        let request = DownloadRequest(name: "X", version: Version(1, 0, 0), source: .git(url: "file://" + repo.path, reference: .tag("1.0.0"), submodules: false))
        let result = try await downloader.download(request)
        #expect(FileManager.default.fileExists(atPath: result.location.appendingPathComponent("Sources/X.swift").path))
        #expect(!FileManager.default.fileExists(atPath: result.location.appendingPathComponent(".git").path))
        #expect(result.checkoutOptions[":tag"] == "1.0.0")

        // Second download is served from the cache even if the repository disappears.
        try FileManager.default.removeItem(at: repo)
        let cached = try await downloader.download(request)
        #expect(cached.location == result.location)
    }

    @Test(arguments: [false, true])
    func externalTagAndCommitCheckoutsAreCached(byCommit: Bool) async throws {
        let repo = try await makeRepository()
        let head = try await shell.run("git", ["-C", repo.path, "rev-parse", "HEAD"]).stdout.trimmingWhitespace()
        let downloader = Downloader(cacheDirectory: root.appendingPathComponent("cache"), shell: shell, ui: .capturing())
        let reference: ExternalSource.GitReference = byCommit ? .commit(head) : .tag("1.0.0")
        let request = DownloadRequest(name: "X", version: nil, source: .git(url: "file://" + repo.path, reference: reference, submodules: false))
        let result = try await downloader.download(request)

        // A tag or commit pins the contents, so `pod install` must not clone again.
        try FileManager.default.removeItem(at: repo)
        let cached = try await downloader.download(request)
        #expect(cached.location == result.location)
        #expect(cached.checkoutOptions == result.checkoutOptions)
    }

    @Test func externalBranchCheckoutsAreFetchedAgain() async throws {
        let repo = try await makeRepository()
        let downloader = Downloader(cacheDirectory: root.appendingPathComponent("cache"), shell: shell, ui: .capturing())
        let request = DownloadRequest(name: "X", version: nil, source: .git(url: "file://" + repo.path, reference: .branch("main"), submodules: false))
        _ = try await downloader.download(request)

        try "let y = 2\n".write(to: repo.appendingPathComponent("Sources/Y.swift"), atomically: true, encoding: .utf8)
        try await shell.run("git", ["-C", repo.path, "add", "."])
        try await shell.run("git", ["-C", repo.path, "commit", "--quiet", "-m", "next"])
        let updated = try await downloader.download(request)
        #expect(FileManager.default.fileExists(atPath: updated.location.appendingPathComponent("Sources/Y.swift").path))
    }

    @Test func branchCheckoutRecordsCommit() async throws {
        let repo = try await makeRepository()
        let head = try await shell.run("git", ["-C", repo.path, "rev-parse", "HEAD"]).stdout.trimmingWhitespace()
        let downloader = Downloader(cacheDirectory: root.appendingPathComponent("cache"), shell: shell, ui: .capturing())
        let results = try await downloader.download([
            DownloadRequest(name: "X", version: nil, source: .git(url: "file://" + repo.path, reference: .branch("main"), submodules: false)),
        ])
        #expect(results["X"]?.checkoutOptions[":commit"] == head)
    }

    @Test func extractsZipArchivesFlatteningTopLevelDirectory() async throws {
        let payload = root.appendingPathComponent("payload/Lib-1.0")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try "x".write(to: payload.appendingPathComponent("a.h"), atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("lib.zip")
        try await shell.run("zip", ["-q", "-r", zip.path, "Lib-1.0"], in: root.appendingPathComponent("payload"))
        let downloader = Downloader(cacheDirectory: root.appendingPathComponent("cache"), shell: shell, ui: .capturing())
        let result = try await downloader.download(DownloadRequest(name: "Lib", version: Version(1, 0), source: .http(url: zip.absoluteString, type: nil, sha256: nil)))
        #expect(FileManager.default.fileExists(atPath: result.location.appendingPathComponent("a.h").path))
    }

    @Test func rejectsChecksumMismatch() async throws {
        let file = root.appendingPathComponent("lib.zip")
        try Data("not really".utf8).write(to: file)
        let downloader = Downloader(cacheDirectory: root.appendingPathComponent("cache"), shell: shell, ui: .capturing())
        await #expect(throws: PodsError.self) {
            _ = try await downloader.download(DownloadRequest(name: "Lib", version: Version(1), source: .http(url: file.absoluteString, type: nil, sha256: "00")))
        }
    }
}
