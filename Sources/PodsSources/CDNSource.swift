import CryptoKit
public import Foundation
public import PodsCore
public import PodsSpec

/// The CocoaPods trunk CDN (`https://cdn.cocoapods.org/`).
///
/// Layout: pods are sharded by the MD5 of their name. `all_pods_versions_a_b_c.txt`
/// lists `Name/1.0/1.1/...` for every pod whose hash starts with `abc`, and podspecs
/// live at `Specs/a/b/c/Name/1.0/Name.podspec.json`.
public actor CDNSource: SpecSource {
    public nonisolated let url: String
    public nonisolated let lockfileName = "trunk"
    private let baseURL: URL
    private let client: any HTTPClient
    private let cacheDirectory: URL
    private var prefixLengths: [Int]?
    /// Shard file name → (pod name → versions).
    private var shards: [String: [String: [Version]]] = [:]
    /// In-flight shard downloads, so concurrent lookups share one request.
    private var pendingShards: [String: Task<[String: [Version]], any Error>] = [:]
    private var specs: [String: Specification] = [:]
    /// Whether shards may be revalidated against the server during this run.
    private var refreshed: Set<String> = []

    public init(
        url: String = "https://cdn.cocoapods.org/",
        client: any HTTPClient = URLSessionHTTPClient(),
        cacheDirectory: URL = CacheLocations.root.appendingPathComponent("CDN", isDirectory: true)
    ) {
        self.url = url
        self.baseURL = URL(string: url.hasSuffix("/") ? url : url + "/")!
        self.client = client
        self.cacheDirectory = cacheDirectory
    }

    public func versions(of name: String) async throws -> [Version] {
        let shard = try await shardFileName(for: name)
        let index = try await loadShard(shard)
        return index[name] ?? []
    }

    public func specification(of name: String, version: Version) async throws -> Specification {
        let key = "\(name)/\(version)"
        if let cached = specs[key] { return cached }
        let path = try await shardPath(for: name).joined(separator: "/")
        let relative = "Specs/\(path)/\(name)/\(version.rawValue)/\(name).podspec.json"
        // Published podspecs are immutable, so the disk cache never needs revalidation.
        let data = try await fetch(relative, revalidate: false)
        let spec = try SpecLoader.load(jsonData: data)
        specs[key] = spec
        return spec
    }

    public func update() async throws {
        // Index shards are revalidated lazily with ETags; forget what we already checked.
        refreshed.removeAll()
        shards.removeAll()
    }

    // MARK: - Sharding

    private func shardPath(for name: String) async throws -> [String] {
        let lengths = try await loadPrefixLengths()
        let hash = Insecure.MD5.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        var components: [String] = []
        var index = hash.startIndex
        for length in lengths {
            let end = hash.index(index, offsetBy: length)
            components.append(String(hash[index..<end]))
            index = end
        }
        return components
    }

    private func shardFileName(for name: String) async throws -> String {
        "all_pods_versions_" + (try await shardPath(for: name)).joined(separator: "_") + ".txt"
    }

    private func loadPrefixLengths() async throws -> [Int] {
        if let prefixLengths { return prefixLengths }
        let data = try await fetch("CocoaPods-version.yml", revalidate: true)
        let lengths = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .drop { !$0.hasPrefix("prefix_lengths") }
            .dropFirst()
            .prefix { $0.trimmingWhitespace().hasPrefix("-") }
            .compactMap { Int($0.trimmingWhitespace().dropFirst().trimmingWhitespace()) }
        let result = lengths.isEmpty ? [1, 1, 1] : lengths
        prefixLengths = result
        return result
    }

    private func loadShard(_ file: String) async throws -> [String: [Version]] {
        if let shard = shards[file] { return shard }
        if let pending = pendingShards[file] { return try await pending.value }
        let task = Task { try await self.downloadShard(file) }
        pendingShards[file] = task
        defer { pendingShards[file] = nil }
        let shard = try await task.value
        shards[file] = shard
        return shard
    }

    private func downloadShard(_ file: String) async throws -> [String: [Version]] {
        let data = try await fetch(file, revalidate: true)
        var index: [String: [Version]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "/")
            guard let name = parts.first else { continue }
            index[String(name)] = parts.dropFirst().compactMap { Version(String($0)) }
        }
        return index
    }

    // MARK: - HTTP with disk cache

    /// Fetches a CDN file, using the disk cache and ETag revalidation when `revalidate` is true.
    private func fetch(_ relativePath: String, revalidate: Bool) async throws -> Data {
        let cacheFile = cacheDirectory.appendingPathComponent(relativePath)
        let etagFile = cacheFile.appendingPathExtension("etag")
        let fileManager = FileManager.default
        let cached = fileManager.contents(atPath: cacheFile.path)

        if let cached, !revalidate || refreshed.contains(relativePath) {
            return cached
        }

        var headers: [String: String] = [:]
        if cached != nil, let etag = fileManager.contents(atPath: etagFile.path).map({ String(decoding: $0, as: UTF8.self) }) {
            headers["If-None-Match"] = etag
        }
        let response: HTTPResponse
        do {
            response = try await client.get(baseURL.appendingPathComponent(relativePath), headers: headers)
        } catch {
            // Offline: fall back to whatever we have.
            if let cached { return cached }
            throw error
        }
        refreshed.insert(relativePath)
        switch response.status {
        case 304:
            if let cached { return cached }
            throw PodsError("CDN returned 304 for \(relativePath) without a cached copy")
        case 200:
            try fileManager.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try response.body.write(to: cacheFile, options: .atomic)
            if let etag = response.headers["etag"] { try Data(etag.utf8).write(to: etagFile, options: .atomic) }
            return response.body
        case 404:
            if relativePath.hasPrefix("all_pods_versions") { return Data() } // empty shard
            throw PodsError("`\(relativePath)` was not found on \(url)")
        default:
            if let cached { return cached }
            throw PodsError("CDN request for \(relativePath) failed with HTTP \(response.status)")
        }
    }
}
