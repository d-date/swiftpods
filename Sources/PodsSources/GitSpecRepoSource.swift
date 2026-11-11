import CryptoKit
public import Foundation
public import PodsCore
public import PodsSpec

/// A git spec repository (private specs repos, or any `source 'https://…/Specs.git'`).
///
/// The repo is cloned once into the cache and pulled on `update()`. Both the flat
/// (`Specs/Name/1.0/Name.podspec`) and the sharded (`Specs/a/b/c/Name/…`) layouts are supported.
public actor GitSpecRepoSource: SpecSource {
    public nonisolated let url: String
    public nonisolated var lockfileName: String { url }
    private let directory: URL
    private let shell: Shell
    private let loader: SpecLoader
    private var cloned = false
    private var specs: [String: Specification] = [:]

    public init(url: String, cacheDirectory: URL = CacheLocations.root.appendingPathComponent("Repos", isDirectory: true), shell: Shell = Shell(), loader: SpecLoader = SpecLoader()) {
        self.url = url
        let hash = SHA256.hash(data: Data(url.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = URL(string: url)?.deletingPathExtension().lastPathComponent ?? "repo"
        self.directory = cacheDirectory.appendingPathComponent("\(name)-\(hash)", isDirectory: true)
        self.shell = shell
        self.loader = loader
    }

    /// Creates a source backed by an existing local checkout (used by tests and `file://` repos).
    public init(url: String, localDirectory: URL, shell: Shell = Shell(), loader: SpecLoader = SpecLoader()) {
        self.url = url
        self.directory = localDirectory
        self.shell = shell
        self.loader = loader
        self.cloned = true
    }

    public func versions(of name: String) async throws -> [Version] {
        try await ensureCloned()
        guard let podDirectory = podDirectory(for: name) else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: podDirectory.path)) ?? []
        return entries.compactMap(Version.init).sorted()
    }

    public func specification(of name: String, version: Version) async throws -> Specification {
        let key = "\(name)/\(version)"
        if let cached = specs[key] { return cached }
        try await ensureCloned()
        guard let versionDirectory = podDirectory(for: name)?.appendingPathComponent(version.rawValue),
              let file = SpecLoader.podspecURL(named: name, in: versionDirectory)
        else {
            throw PodsError("Unable to find a specification for `\(name) (\(version))` in \(url)")
        }
        let spec = try await loader.load(file)
        specs[key] = spec
        return spec
    }

    public func update() async throws {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            try await shell.run("git", ["-C", directory.path, "pull", "--ff-only", "--quiet"])
        } else {
            try await clone()
        }
        specs.removeAll()
    }

    private func ensureCloned() async throws {
        guard !cloned else { return }
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            try await clone()
        }
        cloned = true
    }

    private func clone() async throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: directory)
        try await shell.run("git", ["clone", "--depth", "1", "--quiet", url, directory.path])
        cloned = true
    }

    private func podDirectory(for name: String) -> URL? {
        let specsRoot = FileManager.default.fileExists(atPath: directory.appendingPathComponent("Specs").path)
            ? directory.appendingPathComponent("Specs") : directory
        let flat = specsRoot.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: flat.path) { return flat }
        // Sharded layout as used by the CocoaPods master repo.
        let hash = Insecure.MD5.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let chars = Array(hash)
        let sharded = specsRoot.appendingPathComponent("\(chars[0])/\(chars[1])/\(chars[2])/\(name)")
        return FileManager.default.fileExists(atPath: sharded.path) ? sharded : nil
    }
}
