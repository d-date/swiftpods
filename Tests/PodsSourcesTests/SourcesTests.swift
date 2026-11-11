import CryptoKit
import Foundation
import PodsCore
import PodsSpec
@testable import PodsSources
import Synchronization
import Testing

/// Serves a fake CDN from memory and records requests.
final class FakeCDN: HTTPClient {
    let files: [String: String]
    let requests = Mutex<[String]>([])

    init(files: [String: String]) { self.files = files }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        let path = String(url.path.dropFirst())
        requests.withLock { $0.append(path) }
        if headers["If-None-Match"] == "\"v1\"" { return HTTPResponse(status: 304, body: Data()) }
        guard let body = files[path] else { return HTTPResponse(status: 404, body: Data()) }
        return HTTPResponse(status: 200, body: Data(body.utf8), headers: ["etag": "\"v1\""])
    }
}

func shard(_ name: String) -> [String] {
    let hash = Insecure.MD5.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    return hash.prefix(3).map(String.init)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct CDNSourceTests {
    let shards = shard("Alamofire")

    var cdn: FakeCDN {
        FakeCDN(files: [
            "CocoaPods-version.yml": "---\nmin: 1.0.0\nlast: 1.16.2\nprefix_lengths:\n- 1\n- 1\n- 1\n",
            "all_pods_versions_\(shards.joined(separator: "_")).txt": "Alamofire/5.8.0/5.9.0/5.9.1/6.0.0-beta.1\nOther/1.0\n",
            "Specs/\(shards.joined(separator: "/"))/Alamofire/5.9.1/Alamofire.podspec.json":
                #"{"name":"Alamofire","version":"5.9.1","source":{"git":"https://github.com/Alamofire/Alamofire.git","tag":"5.9.1"}}"#,
        ])
    }

    @Test func resolvesVersionsAndSpecs() async throws {
        let cache = try temporaryDirectory()
        let client = cdn
        let source = CDNSource(client: client, cacheDirectory: cache)
        let versions = try await source.versions(of: "Alamofire")
        #expect(versions.map(\.rawValue) == ["5.8.0", "5.9.0", "5.9.1", "6.0.0-beta.1"])
        #expect(try await source.versions(of: "Missing").isEmpty)
        let spec = try await source.specification(of: "Alamofire", version: Version(5, 9, 1))
        #expect(spec.name == "Alamofire")

        // A second source instance revalidates with ETags and serves podspecs from disk.
        let second = CDNSource(client: client, cacheDirectory: cache)
        _ = try await second.versions(of: "Alamofire")
        _ = try await second.specification(of: "Alamofire", version: Version(5, 9, 1))
        let podspecRequests = client.requests.withLock { $0.filter { $0.hasSuffix(".podspec.json") } }
        #expect(podspecRequests.count == 1)
    }

    @Test func concurrentLookupsShareShardDownloads() async throws {
        let client = cdn
        let source = CDNSource(client: client, cacheDirectory: try temporaryDirectory())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await source.versions(of: "Alamofire") } }
            try await group.waitForAll()
        }
        let shardRequests = client.requests.withLock { $0.filter { $0.hasPrefix("all_pods_versions") } }
        #expect(shardRequests.count == 1)
    }

    @Test func managerMapsMasterRepoToCDN() {
        let manager = SourcesManager(urls: ["https://github.com/CocoaPods/Specs.git", "https://cdn.cocoapods.org/"], client: cdn, cacheRoot: URL(fileURLWithPath: "/tmp/x"))
        #expect(manager.sources.count == 1)
        #expect(manager.sources[0].lockfileName == "trunk")
    }
}

struct GitSpecRepoTests {
    @Test func readsFlatLayoutAndPrefersEarlierSources() async throws {
        let repo = try temporaryDirectory()
        let podDir = repo.appendingPathComponent("Specs/Private/1.2.0")
        try FileManager.default.createDirectory(at: podDir, withIntermediateDirectories: true)
        try """
        Pod::Spec.new do |s|
          s.name = 'Private'
          s.version = '1.2.0'
          s.source = { :git => 'https://example.com/private.git', :tag => s.version.to_s }
        end
        """.write(to: podDir.appendingPathComponent("Private.podspec"), atomically: true, encoding: .utf8)
        let source = GitSpecRepoSource(url: "https://example.com/specs.git", localDirectory: repo)
        #expect(try await source.versions(of: "Private") == [Version(1, 2, 0)])
        let spec = try await source.specification(of: "Private", version: Version(1, 2, 0))
        #expect(spec.source == .git(url: "https://example.com/private.git", reference: .tag("1.2.0"), submodules: false))

        let manager = SourcesManager(sources: [source])
        let candidates = try await manager.candidates(for: "Private")
        #expect(candidates.map(\.version) == [Version(1, 2, 0)])
        #expect(candidates.first?.source.lockfileName == "https://example.com/specs.git")
    }
}
