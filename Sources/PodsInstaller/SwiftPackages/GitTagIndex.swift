import PodsCore

/// Maps the tags of a remote git repository to the commits they point at.
actor GitTagIndex {
    private let shell: Shell
    private var lookups: [String: Task<[String: String], any Error>] = [:]

    init(shell: Shell) {
        self.shell = shell
    }

    /// Returns tag name -> commit SHA. Annotated tags resolve to the commit they point at,
    /// not to the tag object. Each URL is listed once; later calls (including concurrent ones) share the result.
    func tags(of url: String) async throws -> [String: String] {
        if let existing = lookups[url] { return try await existing.value }
        let shell = shell
        let task = Task { try await Self.listTags(of: url, shell: shell) }
        lookups[url] = task
        do {
            return try await task.value
        } catch {
            lookups[url] = nil
            throw error
        }
    }

    /// Parses a tag as SwiftPM does: a single leading `v` or `V` is dropped before reading the version.
    static func swiftPMVersion(fromTag tag: String) -> Version? {
        var name = Substring(tag)
        if name.first == "v" || name.first == "V" { name = name.dropFirst() }
        return Version(String(name))
    }

    private static func listTags(of url: String, shell: Shell) async throws -> [String: String] {
        let output = try await shell.run("git", ["ls-remote", "--tags", url])
        var result: [String: String] = [:]
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].hasPrefix("refs/tags/") else { continue }
            var name = String(fields[1].dropFirst("refs/tags/".count))
            // A peeled "^{}" entry names the commit behind an annotated tag and overrides the tag object's SHA.
            if name.hasSuffix("^{}") { name.removeLast(3) }
            result[name] = String(fields[0])
        }
        return result
    }
}
