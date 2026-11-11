/// Where a pod is fetched from when it does not come from a spec source.
public enum ExternalSource: Sendable, Hashable, CustomStringConvertible {
    public enum GitReference: Sendable, Hashable {
        case tag(String)
        case branch(String)
        case commit(String)
        case defaultBranch
    }

    /// `pod 'X', :git => '...', :tag => '...'`
    case git(url: String, reference: GitReference)
    /// `pod 'X', :path => '../X'`
    case path(String)
    /// `pod 'X', :podspec => 'https://.../X.podspec'`
    case podspec(String)

    /// Key/value pairs as written in Podfile.lock (`EXTERNAL SOURCES`).
    public var lockfileEntries: [(key: String, value: String)] {
        switch self {
        case .git(let url, let reference):
            var entries = [(key: ":git", value: url)]
            switch reference {
            case .tag(let tag): entries.append((":tag", tag))
            case .branch(let branch): entries.append((":branch", branch))
            case .commit(let commit): entries.append((":commit", commit))
            case .defaultBranch: break
            }
            return entries
        case .path(let path): return [(":path", path)]
        case .podspec(let podspec): return [(":podspec", podspec)]
        }
    }

    /// Restores an external source from Podfile.lock style keys (with or without leading colon).
    public init?(entries: [String: String]) {
        func value(_ key: String) -> String? { entries[":" + key] ?? entries[key] }
        if let url = value("git") {
            let reference: GitReference =
                if let tag = value("tag") { .tag(tag) }
                else if let commit = value("commit") { .commit(commit) }
                else if let branch = value("branch") { .branch(branch) }
                else { .defaultBranch }
            self = .git(url: url, reference: reference)
        } else if let path = value("path") {
            self = .path(path)
        } else if let podspec = value("podspec") {
            self = .podspec(podspec)
        } else {
            return nil
        }
    }

    /// Human readable form used by Podfile.lock: `` `url`, tag `1.0` ``.
    public var description: String {
        switch self {
        case .git(let url, let reference):
            switch reference {
            case .tag(let tag): "`\(url)`, tag `\(tag)`"
            case .branch(let branch): "`\(url)`, branch `\(branch)`"
            case .commit(let commit): "`\(url)`, commit `\(commit)`"
            case .defaultBranch: "`\(url)`"
            }
        case .path(let path): "`\(path)`"
        case .podspec(let podspec): "`\(podspec)`"
        }
    }
}

/// A dependency on a pod (or one of its subspecs).
public struct Dependency: Sendable, Hashable, CustomStringConvertible {
    /// Full name, possibly including subspecs (`Firebase/Analytics`).
    public let name: String
    public let requirement: Requirement
    public let externalSource: ExternalSource?

    public init(name: String, requirement: Requirement = .any, externalSource: ExternalSource? = nil) {
        self.name = name
        self.requirement = requirement
        self.externalSource = externalSource
    }

    /// Name of the root specification (`Firebase` for `Firebase/Analytics`).
    public var rootName: String { Self.rootName(of: name) }

    public static func rootName(of name: String) -> String {
        if let slash = name.firstIndex(of: "/") { String(name[..<slash]) } else { name }
    }

    public var description: String {
        if let externalSource { "\(name) (from \(externalSource))" }
        else if requirement.isAny { name }
        else { "\(name) (\(requirement))" }
    }

    /// Representation used in the `DEPENDENCIES` section of Podfile.lock.
    public var lockfileDescription: String {
        if let externalSource { return "\(name) (from \(externalSource))" }
        return requirement.isAny ? name : "\(name) \(requirement.lockfileDescription)"
    }
}
