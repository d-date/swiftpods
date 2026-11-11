public import Foundation
public import PodsCore
import Yams

/// `Podfile.lock` / `Pods/Manifest.lock`.
public struct Lockfile: Sendable, Equatable {
    /// An installed pod (`PODS` section entry).
    public struct Pod: Sendable, Equatable {
        /// Full name, possibly a subspec (`Firebase/Core`).
        public var name: String
        public var version: Version
        /// Dependencies in lockfile notation (`FirebaseAnalytics (~> 11.0.0)`).
        public var dependencies: [String]

        public init(name: String, version: Version, dependencies: [String] = []) {
            self.name = name
            self.version = version
            self.dependencies = dependencies
        }
    }

    public var pods: [Pod]
    /// Podfile dependencies in lockfile notation (`Alamofire (~> 5.9)`).
    public var dependencies: [String]
    /// Source URL (or `trunk`) → root pod names taken from it.
    public var specRepos: [String: [String]]
    /// Root pod name → external source (`:path`, `:git`, ...).
    public var externalSources: [String: [String: String]]
    /// Root pod name → resolved checkout (`:git`, `:commit`) for git-based pods.
    public var checkoutOptions: [String: [String: String]]
    public var specChecksums: [String: String]
    public var podfileChecksum: String?
    public var cocoapodsVersion: String

    /// Version written to the `COCOAPODS` key. SwiftPods writes a CocoaPods-compatible version.
    public static let compatibleCocoaPodsVersion = "1.16.2"

    public init(
        pods: [Pod] = [], dependencies: [String] = [], specRepos: [String: [String]] = [:],
        externalSources: [String: [String: String]] = [:], checkoutOptions: [String: [String: String]] = [:],
        specChecksums: [String: String] = [:], podfileChecksum: String? = nil,
        cocoapodsVersion: String = Lockfile.compatibleCocoaPodsVersion
    ) {
        self.pods = pods
        self.dependencies = dependencies
        self.specRepos = specRepos
        self.externalSources = externalSources
        self.checkoutOptions = checkoutOptions
        self.specChecksums = specChecksums
        self.podfileChecksum = podfileChecksum
        self.cocoapodsVersion = cocoapodsVersion
    }

    // MARK: - Queries

    /// Locked version of a pod (by root or full name).
    public func version(of name: String) -> Version? {
        let root = Dependency.rootName(of: name)
        return pods.first { Dependency.rootName(of: $0.name) == root }?.version
    }

    /// Names of every locked pod, including subspecs.
    public var podNames: [String] { pods.map(\.name) }

    /// The Podfile dependencies recorded in the lockfile, as `Dependency` values.
    public var parsedDependencies: [Dependency] {
        dependencies.compactMap { Self.parseDependency($0, externalSources: externalSources) }
    }

    /// Parses `Name`, `Name (~> 1.0)`, `Name (= 1.0)` or `Name (from `...`)`.
    public static func parseDependency(_ string: String, externalSources: [String: [String: String]] = [:]) -> Dependency? {
        guard let open = string.firstIndex(of: "(") else {
            let name = string.trimmingWhitespace()
            return name.isEmpty ? nil : Dependency(name: name)
        }
        let name = string[..<open].trimmingWhitespace()
        let inner = string[string.index(after: open)...].dropLast(string.hasSuffix(")") ? 1 : 0)
        if inner.hasPrefix("from ") {
            let source = externalSources[Dependency.rootName(of: name)].flatMap(ExternalSource.init(entries:))
            return Dependency(name: name, externalSource: source)
        }
        guard let requirement = try? Requirement(parsing: String(inner)) else { return nil }
        return Dependency(name: name, requirement: requirement)
    }

    /// Parses `Name (1.2.3)` as used in the `PODS` section.
    static func parsePodEntry(_ string: String) -> (name: String, version: Version)? {
        guard let open = string.lastIndex(of: "("), string.hasSuffix(")") else { return nil }
        let name = string[..<open].trimmingWhitespace()
        guard let version = Version(String(string[string.index(after: open)..<string.index(before: string.endIndex)])) else { return nil }
        return (name, version)
    }

    // MARK: - Reading

    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { "Invalid lockfile: \(message)" }
    }

    public init(contentsOf url: URL) throws {
        try self.init(yaml: try String(contentsOf: url, encoding: .utf8))
    }

    public init(yaml: String) throws {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ParseError(message: "expected a mapping at the top level")
        }
        var pods: [Pod] = []
        for entry in root["PODS"] as? [Any] ?? [] {
            if let string = entry as? String, let parsed = Self.parsePodEntry(string) {
                pods.append(Pod(name: parsed.name, version: parsed.version))
            } else if let hash = entry as? [String: Any], let (key, value) = hash.first, let parsed = Self.parsePodEntry(key) {
                pods.append(Pod(name: parsed.name, version: parsed.version, dependencies: (value as? [Any] ?? []).map { "\($0)" }))
            } else {
                throw ParseError(message: "invalid PODS entry `\(entry)`")
            }
        }
        func stringMap(_ value: Any?) -> [String: [String: String]] {
            var result: [String: [String: String]] = [:]
            for (key, nested) in value as? [String: Any] ?? [:] {
                result[key] = (nested as? [String: Any] ?? [:]).mapValues { "\($0)" }
            }
            return result
        }
        self.init(
            pods: pods,
            dependencies: (root["DEPENDENCIES"] as? [Any] ?? []).map { "\($0)" },
            specRepos: (root["SPEC REPOS"] as? [String: Any] ?? [:]).mapValues { ($0 as? [Any] ?? []).map { "\($0)" } },
            externalSources: stringMap(root["EXTERNAL SOURCES"]),
            checkoutOptions: stringMap(root["CHECKOUT OPTIONS"]),
            specChecksums: (root["SPEC CHECKSUMS"] as? [String: Any] ?? [:]).mapValues { "\($0)" },
            podfileChecksum: root["PODFILE CHECKSUM"].map { "\($0)" },
            cocoapodsVersion: root["COCOAPODS"].map { "\($0)" } ?? Self.compatibleCocoaPodsVersion
        )
    }

    // MARK: - Writing

    /// Serializes like CocoaPods' `YAMLHelper`, so files written by either tool are identical.
    public var yaml: String {
        var sections: [String] = []
        func section(_ title: String, _ body: [String]) {
            guard !body.isEmpty else { return }
            sections.append(([title + ":"] + body).joined(separator: "\n"))
        }

        var podLines: [String] = []
        for pod in pods.sorted(by: { YAMLWriter.sortKey($0.name) < YAMLWriter.sortKey($1.name) }) {
            let entry = YAMLWriter.scalar("\(pod.name) (\(pod.version))")
            if pod.dependencies.isEmpty {
                podLines.append("  - \(entry)")
            } else {
                podLines.append("  - \(entry):")
                podLines += YAMLWriter.sorted(pod.dependencies).map { "    - \(YAMLWriter.scalar($0))" }
            }
        }
        section("PODS", podLines)
        section("DEPENDENCIES", YAMLWriter.sorted(dependencies).map { "  - \(YAMLWriter.scalar($0))" })
        section("SPEC REPOS", YAMLWriter.sortedKeys(specRepos).flatMap { repo in
            ["  \(YAMLWriter.scalar(repo)):"] + YAMLWriter.sorted(specRepos[repo]!).map { "    - \(YAMLWriter.scalar($0))" }
        })
        func nested(_ map: [String: [String: String]]) -> [String] {
            YAMLWriter.sortedKeys(map).flatMap { name in
                ["  \(YAMLWriter.scalar(name)):"] + YAMLWriter.sortedKeys(map[name]!).map { key in
                    "    \(key): \(YAMLWriter.scalar(map[name]![key]!))"
                }
            }
        }
        section("EXTERNAL SOURCES", nested(externalSources))
        section("CHECKOUT OPTIONS", nested(checkoutOptions))
        section("SPEC CHECKSUMS", YAMLWriter.sortedKeys(specChecksums).map { "  \(YAMLWriter.scalar($0)): \(YAMLWriter.scalar(specChecksums[$0]!))" })
        if let podfileChecksum { sections.append("PODFILE CHECKSUM: \(YAMLWriter.scalar(podfileChecksum))") }
        sections.append("COCOAPODS: \(YAMLWriter.scalar(cocoapodsVersion))")
        return sections.joined(separator: "\n\n") + "\n"
    }

    public func write(to url: URL) throws {
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Reproduces the formatting rules of CocoaPods' `Pod::YAMLHelper`.
enum YAMLWriter {
    /// CocoaPods sorts case-insensitively.
    static func sortKey(_ string: String) -> String { string.lowercased() }

    static func sorted(_ strings: [String]) -> [String] {
        strings.sorted { sortKey($0) == sortKey($1) ? $0 < $1 : sortKey($0) < sortKey($1) }
    }

    static func sortedKeys<V>(_ dictionary: [String: V]) -> [String] { sorted(Array(dictionary.keys)) }

    /// Quotes a string when YAML would otherwise read it as something else.
    static func scalar(_ string: String) -> String {
        needsQuotes(string) ? quoted(string) : string
    }

    static func needsQuotes(_ string: String) -> Bool {
        if string.trimmingWhitespace().isEmpty { return true }
        if string != string.trimmingWhitespace() { return true }
        let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"]
        if reserved.contains(string.lowercased()) { return true }
        // Integers and floats (`1`, `1.0`, `.5`) would be read as numbers.
        if string.range(of: #"^[-+]?(\d+|\d*\.\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil { return true }
        if let first = string.unicodeScalars.first,
           !(CharacterSet.alphanumerics.contains(first) || first == "_" || first == "(" || first == "/") {
            return true
        }
        return string.contains(": ") || string.contains(" #") || string.hasSuffix(":")
    }

    static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
