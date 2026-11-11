public import Foundation
public import PodsCore

/// The ordered set of spec sources declared by a Podfile.
public struct SourcesManager: Sendable {
    /// Repository URLs that are served by the trunk CDN.
    static let trunkAliases: Set<String> = [
        "https://cdn.cocoapods.org/", "https://cdn.cocoapods.org", "trunk",
        "https://github.com/CocoaPods/Specs.git", "https://github.com/cocoapods/specs.git",
    ]

    public let sources: [any SpecSource]

    public init(sources: [any SpecSource]) {
        self.sources = sources
    }

    /// Creates sources for the URLs in a Podfile. The CocoaPods master repo is served by the CDN.
    public init(urls: [String], client: any HTTPClient = URLSessionHTTPClient(), cacheRoot: URL = CacheLocations.root) {
        var cdn: CDNSource?
        var sources: [any SpecSource] = []
        for url in urls {
            if Self.trunkAliases.contains(url) || Self.trunkAliases.contains(url.lowercased()) {
                if cdn == nil {
                    let source = CDNSource(client: client, cacheDirectory: cacheRoot.appendingPathComponent("CDN", isDirectory: true))
                    cdn = source
                    sources.append(source)
                }
            } else {
                sources.append(GitSpecRepoSource(url: url, cacheDirectory: cacheRoot.appendingPathComponent("Repos", isDirectory: true)))
            }
        }
        self.sources = sources
    }

    /// A version of a pod together with the source that provides it.
    public struct Candidate: Sendable {
        public let version: Version
        public let source: any SpecSource

        public init(version: Version, source: any SpecSource) {
            self.version = version
            self.source = source
        }
    }

    /// Every version of `name` across sources; for duplicates the earlier source wins.
    /// Sources are queried concurrently.
    public func candidates(for name: String, restrictedTo sourceURL: String? = nil) async throws -> [Candidate] {
        let selected = sourceURL.map { url in sources.filter { $0.url == url || $0.lockfileName == url } } ?? sources
        let results = try await withThrowingTaskGroup(of: (Int, [Version]).self) { group in
            for (index, source) in selected.enumerated() {
                group.addTask { (index, try await source.versions(of: name)) }
            }
            var results: [(Int, [Version])] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        var seen = Set<Version>()
        var candidates: [Candidate] = []
        for (index, versions) in results {
            for version in versions where seen.insert(version).inserted {
                candidates.append(Candidate(version: version, source: selected[index]))
            }
        }
        return candidates.sorted { $0.version > $1.version }
    }

    public func source(named lockfileName: String) -> (any SpecSource)? {
        sources.first { $0.lockfileName == lockfileName || $0.url == lockfileName }
    }

    /// Updates every source concurrently.
    public func update() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in sources { group.addTask { try await source.update() } }
            try await group.waitForAll()
        }
    }
}
