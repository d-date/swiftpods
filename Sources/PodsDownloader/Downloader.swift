import CryptoKit
public import Foundation
public import PodsCore
public import PodsSpec

/// What to download for one pod.
public struct DownloadRequest: Sendable {
    public let name: String
    /// Version for released pods; `nil` for external sources (always re-fetched).
    public let version: Version?
    public let source: PodSource
    /// Run the spec's `prepare_command` after downloading.
    public let prepareCommand: String?

    public init(name: String, version: Version?, source: PodSource, prepareCommand: String? = nil) {
        self.name = name
        self.version = version
        self.source = source
        self.prepareCommand = prepareCommand
    }
}

public struct DownloadResult: Sendable {
    public let name: String
    /// Directory holding the pod's files (in the cache or, for `:path`, the original location).
    public let location: URL
    /// The exact checkout (e.g. the commit of a branch) for `CHECKOUT OPTIONS`.
    public let checkoutOptions: [String: String]
}

/// Downloads pod sources into a shared cache.
public actor Downloader {
    public let cacheDirectory: URL
    private let shell: Shell
    private let ui: UI
    private let session: URLSession
    private var inFlight: [String: Task<DownloadResult, any Error>] = [:]

    public init(cacheDirectory: URL, shell: Shell = Shell(), ui: UI = UI(), session: URLSession = .shared) {
        self.cacheDirectory = cacheDirectory
        self.shell = shell
        self.ui = ui
        self.session = session
    }

    /// Downloads every request with at most `maxConcurrent` downloads at a time.
    public func download(_ requests: [DownloadRequest], maxConcurrent: Int = 8) async throws -> [String: DownloadResult] {
        try await withThrowingTaskGroup(of: DownloadResult.self) { group in
            var results: [String: DownloadResult] = [:]
            var iterator = requests.makeIterator()
            for _ in 0..<maxConcurrent {
                guard let request = iterator.next() else { break }
                group.addTask { try await self.download(request) }
            }
            while let result = try await group.next() {
                results[result.name] = result
                if let request = iterator.next() {
                    group.addTask { try await self.download(request) }
                }
            }
            return results
        }
    }

    public func download(_ request: DownloadRequest) async throws -> DownloadResult {
        let key = cacheKey(for: request)
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await self.perform(request, key: key) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    private func cacheKey(for request: DownloadRequest) -> String {
        let sourceHash = SHA256.hash(data: Data(String(describing: request.source).utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
        let kind = request.version == nil ? "External" : "Release"
        return "\(kind)/\(request.name)/\(request.version?.rawValue ?? "head")-\(sourceHash)"
    }

    private func perform(_ request: DownloadRequest, key: String) async throws -> DownloadResult {
        let fileManager = FileManager.default
        if case .path(let path) = request.source {
            return DownloadResult(name: request.name, location: URL(fileURLWithPath: path).standardizedFileURL, checkoutOptions: [":path": path])
        }
        let destination = cacheDirectory.appendingPathComponent(key, isDirectory: true)
        let marker = destination.appendingPathComponent(".swiftpods-complete")
        // Released pods are immutable, so a complete cache entry can be reused.
        if request.version != nil, fileManager.fileExists(atPath: marker.path),
           let data = fileManager.contents(atPath: marker.path),
           let options = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            ui.verbose("Using cached \(request.name)")
            return DownloadResult(name: request.name, location: destination, checkoutOptions: options)
        }

        let staging = cacheDirectory.appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        ui.message("Downloading \(request.name)\(request.version.map { " (\($0))" } ?? "") from \(request.source)")
        let checkout: [String: String]
        switch request.source {
        case .git(let url, let reference, let submodules):
            checkout = try await gitClone(url: url, reference: reference, submodules: submodules, into: staging)
        case .http(let url, let type, let sha256):
            try await downloadArchive(url: url, type: type, sha256: sha256, into: staging)
            checkout = [":http": url]
        case .path:
            preconditionFailure("`:path` sources are returned before downloading")
        }
        try? fileManager.removeItem(at: staging.appendingPathComponent(".git"))

        if let command = request.prepareCommand {
            ui.verbose("Running prepare_command for \(request.name)")
            try await shell.run("/bin/bash", ["-c", "set -e\n" + command], in: staging)
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        try JSONSerialization.data(withJSONObject: checkout, options: [.sortedKeys]).write(to: marker)
        return DownloadResult(name: request.name, location: destination, checkoutOptions: checkout)
    }

    // MARK: - Git

    private func gitClone(url: String, reference: ExternalSource.GitReference, submodules: Bool, into directory: URL) async throws -> [String: String] {
        let path = directory.path
        switch reference {
        case .tag(let name), .branch(let name):
            try await shell.run("git", ["clone", "--depth", "1", "--quiet", "--branch", name, url, path])
        case .defaultBranch:
            try await shell.run("git", ["clone", "--depth", "1", "--quiet", url, path])
        case .commit(let commit):
            try await shell.run("git", ["init", "--quiet", path])
            try await shell.run("git", ["-C", path, "remote", "add", "origin", url])
            // Fetching a commit by SHA works on GitHub/GitLab; fall back to a full clone otherwise.
            do {
                try await shell.run("git", ["-C", path, "fetch", "--depth", "1", "--quiet", "origin", commit])
                try await shell.run("git", ["-C", path, "checkout", "--quiet", "FETCH_HEAD"])
            } catch {
                try await shell.run("git", ["-C", path, "fetch", "--quiet", "origin"])
                try await shell.run("git", ["-C", path, "checkout", "--quiet", commit])
            }
        }
        if submodules {
            try await shell.run("git", ["-C", path, "submodule", "update", "--init", "--recursive", "--depth", "1", "--quiet"])
        }
        let head = try await shell.run("git", ["-C", path, "rev-parse", "HEAD"]).stdout.trimmingWhitespace()
        var options = [":git": url]
        switch reference {
        case .tag(let tag): options[":tag"] = tag
        default: options[":commit"] = head
        }
        return options
    }

    // MARK: - HTTP archives

    private func downloadArchive(url: String, type: String?, sha256: String?, into directory: URL) async throws {
        guard let remote = URL(string: url) else { throw PodsError("Invalid URL `\(url)`") }
        let (temporary, response) = try await session.download(from: remote)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PodsError("Downloading \(url) failed with HTTP \(http.statusCode)")
        }
        if let sha256 {
            let digest = SHA256.hash(data: try Data(contentsOf: temporary)).map { String(format: "%02x", $0) }.joined()
            guard digest == sha256.lowercased() else {
                throw PodsError("SHA256 mismatch for \(url): expected \(sha256), got \(digest)")
            }
        }
        let kind = type ?? Self.archiveType(for: remote.lastPathComponent)
        let extracted = directory.appendingPathComponent(".extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        switch kind {
        case "zip":
            try await shell.run("unzip", ["-q", "-o", temporary.path, "-d", extracted.path])
        case "tgz", "tar", "tbz", "txz":
            try await shell.run("tar", ["-xf", temporary.path, "-C", extracted.path])
        default:
            // Not an archive: keep the file as-is.
            try FileManager.default.copyItem(at: temporary, to: extracted.appendingPathComponent(remote.lastPathComponent))
        }
        // Like CocoaPods, a single top-level directory is flattened.
        let fileManager = FileManager.default
        var root = extracted
        let entries = try fileManager.contentsOfDirectory(atPath: extracted.path).filter { $0 != "__MACOSX" }
        var isDirectory: ObjCBool = false
        if entries.count == 1, fileManager.fileExists(atPath: extracted.appendingPathComponent(entries[0]).path, isDirectory: &isDirectory), isDirectory.boolValue {
            root = extracted.appendingPathComponent(entries[0])
        }
        for entry in try fileManager.contentsOfDirectory(atPath: root.path) where entry != "__MACOSX" {
            try fileManager.moveItem(at: root.appendingPathComponent(entry), to: directory.appendingPathComponent(entry))
        }
        try fileManager.removeItem(at: extracted)
    }

    static func archiveType(for fileName: String) -> String? {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".zip") { return "zip" }
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return "tgz" }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz") { return "tbz" }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return "txz" }
        if lower.hasSuffix(".tar") { return "tar" }
        return nil
    }
}
