public import PodsCore

/// A pod specification (podspec) or one of its subspecs.
///
/// The podspec JSON format published on trunk is the canonical representation;
/// Ruby and Swift podspecs are converted to it before being loaded.
public struct Specification: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        case library, test, app
    }

    public enum SpecError: Error, CustomStringConvertible, Equatable {
        case missingAttribute(String, spec: String)
        case invalidVersion(String, spec: String)
        case invalidRequirement(String, dependency: String, spec: String)

        public var description: String {
            switch self {
            case .missingAttribute(let attribute, let spec): "The podspec of `\(spec)` is missing the required attribute `\(attribute)`."
            case .invalidVersion(let version, let spec): "The podspec of `\(spec)` has an invalid version `\(version)`."
            case .invalidRequirement(let requirement, let dependency, let spec):
                "The podspec of `\(spec)` has an invalid requirement `\(requirement)` for `\(dependency)`."
            }
        }
    }

    /// Full name including parents, e.g. `Firebase/Core`.
    public let name: String
    /// Version of the root specification.
    public let version: Version
    public let kind: Kind
    /// This specification's own attributes (excluding nested specs).
    public let attributes: OrderedObject
    /// Attributes of the ancestors, root first. Used for inheritance and root-only attributes.
    let ancestors: [OrderedObject]
    public let subspecs: [Specification]
    public let testSpecs: [Specification]
    public let appSpecs: [Specification]
    /// SHA1 of the podspec file, recorded in Podfile.lock (`SPEC CHECKSUMS`).
    public let checksum: String?

    /// Creates a root specification from podspec JSON.
    public init(json: JSON, checksum: String? = nil) throws(SpecError) {
        guard case .object(let object) = json else { throw .missingAttribute("name", spec: "<unknown>") }
        guard let name = object["name"]?.string else { throw .missingAttribute("name", spec: "<unknown>") }
        guard let versionString = object["version"]?.string else { throw .missingAttribute("version", spec: name) }
        guard let version = Version(versionString) else { throw .invalidVersion(versionString, spec: name) }
        try self.init(name: name, version: version, kind: .library, object: object, ancestors: [], checksum: checksum)
    }

    private init(name: String, version: Version, kind: Kind, object: OrderedObject, ancestors: [OrderedObject], checksum: String?) throws(SpecError) {
        var own = object
        own["subspecs"] = nil
        own["testspecs"] = nil
        own["appspecs"] = nil
        self.name = name
        self.version = version
        self.kind = kind
        self.attributes = own
        self.ancestors = ancestors
        self.checksum = checksum
        let childAncestors = ancestors + [own]
        func children(_ key: String, _ kind: Kind) throws(SpecError) -> [Specification] {
            var result: [Specification] = []
            for child in object[key]?.array ?? [] {
                guard case .object(let childObject) = child, let childName = childObject["name"]?.string else {
                    throw .missingAttribute("name", spec: "\(name)/<subspec>")
                }
                result.append(try Specification(
                    name: name + "/" + childName, version: version, kind: kind,
                    object: childObject, ancestors: childAncestors, checksum: checksum
                ))
            }
            return result
        }
        self.subspecs = try children("subspecs", .library)
        self.testSpecs = try children("testspecs", .test)
        self.appSpecs = try children("appspecs", .app)
        _ = try dependencyList(attributes) // validate requirements eagerly
    }

    public var description: String { "\(name) (\(version))" }

    // MARK: - Names

    public var isRoot: Bool { ancestors.isEmpty }
    public var rootName: String { Dependency.rootName(of: name) }
    /// Last path component of the name (`Core` for `Firebase/Core`).
    public var baseName: String { String(name.split(separator: "/").last ?? Substring(name)) }

    /// Value of a root attribute (looked up on the root spec).
    public func rootAttribute(_ key: String) -> JSON? {
        (ancestors.first ?? attributes)[key]
    }

    /// The Clang/Swift module name.
    public var moduleName: String {
        if let explicit = rootAttribute("module_name")?.string { return explicit }
        if let headerDir = rootAttribute("header_dir")?.string, !headerDir.isEmpty {
            return Self.c99Identifier(headerDir)
        }
        return Self.c99Identifier(rootName)
    }

    /// Converts a name into a valid C99 extended identifier, as Xcode does for `PRODUCT_MODULE_NAME`.
    public static func c99Identifier(_ name: String) -> String {
        var result = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if let first = result.first, first.isNumber { result = "_" + result }
        return result
    }

    // MARK: - Root attributes

    public var summary: String? { rootAttribute("summary")?.string }
    public var homepage: String? { rootAttribute("homepage")?.string }
    public var source: PodSource? { rootAttribute("source").flatMap(PodSource.init(json:)) }
    public var isStaticFramework: Bool { rootAttribute("static_framework")?.bool ?? false }
    public var isDeprecated: Bool {
        (rootAttribute("deprecated")?.bool ?? false) || rootAttribute("deprecated_in_favor_of") != nil
    }
    public var prepareCommand: String? { rootAttribute("prepare_command")?.string }

    /// Swift versions the pod supports.
    public var swiftVersions: [Version] {
        var strings = rootAttribute("swift_versions")?.stringList ?? []
        if strings.isEmpty, let single = rootAttribute("swift_version")?.string { strings = [single] }
        return strings.compactMap(Version.init)
    }

    /// Names (relative) of the subspecs used when depending on this spec without a subspec.
    public var defaultSubspecNames: [String]? {
        guard let value = attributes["default_subspecs"] ?? attributes["default_subspec"] else { return nil }
        let names = value.stringList
        return names == [":none"] || names == ["none"] ? [] : names
    }

    // MARK: - Platforms

    /// Platforms this spec explicitly declares; `nil` means every platform is supported.
    public var declaredPlatforms: [Platform]? {
        // A subspec may restrict the platforms of its parent.
        for object in ([attributes] + ancestors.reversed()) {
            if case .object(let platforms)? = object["platforms"] {
                return platforms.pairs.compactMap { pair in
                    guard let name = Platform.Name(podfileName: pair.key) else { return nil }
                    return Platform(name, pair.value.string.flatMap(Version.init))
                }
            }
        }
        return nil
    }

    public var availablePlatforms: [Platform] {
        declaredPlatforms ?? Platform.Name.allCases.map { Platform($0) }
    }

    /// Minimum deployment target declared for `platform`, if any.
    public func deploymentTarget(for platform: Platform.Name) -> Version? {
        availablePlatforms.first { $0.name == platform }?.deploymentTarget
    }

    /// Whether the spec can be used by a target built for `platform`.
    public func supports(_ platform: Platform) -> Bool {
        guard let declared = availablePlatforms.first(where: { $0.name == platform.name }) else { return false }
        return platform.supports(declared)
    }

    // MARK: - Subspecs and dependencies

    /// Every library subspec, depth-first.
    public var recursiveSubspecs: [Specification] {
        subspecs.flatMap { [$0] + $0.recursiveSubspecs }
    }

    /// Finds a nested spec by full name (`Root/A/B`), including test and app specs.
    public func subspec(named fullName: String) -> Specification? {
        if fullName == name { return self }
        guard fullName.hasPrefix(name + "/") else { return nil }
        for child in subspecs + testSpecs + appSpecs {
            if let found = child.subspec(named: fullName) { return found }
        }
        return nil
    }

    /// The subspecs pulled in when this spec is depended upon directly.
    public var defaultSubspecs: [Specification] {
        if let names = defaultSubspecNames {
            return names.compactMap { subspec(named: name + "/" + $0) }
        }
        return subspecs
    }

    /// Dependencies for `platform`: declared ones (inherited from parents) plus the implicit
    /// dependencies on default subspecs.
    public func dependencies(for platform: Platform.Name) -> [Dependency] {
        let declared = consumer(for: platform).dependencies
        let implicit = defaultSubspecs
            .filter { subspec in subspec.availablePlatforms.contains { $0.name == platform } }
            .map { Dependency(name: $0.name, requirement: .exact(version)) }
        return declared + implicit
    }

    /// Dependencies across every platform the spec supports (used by the resolver before platforms are known).
    public var allDependencies: [Dependency] {
        var seen = Set<String>()
        var result: [Dependency] = []
        for platform in availablePlatforms {
            for dependency in dependencies(for: platform.name) where seen.insert(dependency.name).inserted {
                result.append(dependency)
            }
        }
        return result
    }

    func dependencyList(_ object: OrderedObject) throws(SpecError) -> [Dependency] {
        guard case .object(let dependencies)? = object["dependencies"] else { return [] }
        var result: [Dependency] = []
        for pair in dependencies.pairs {
            let strings = pair.value.stringList
            do {
                result.append(Dependency(name: pair.key, requirement: try Requirement(parsing: strings)))
            } catch {
                throw .invalidRequirement(strings.joined(separator: ", "), dependency: pair.key, spec: name)
            }
        }
        return result
    }

    /// Attribute values resolved for one platform.
    public func consumer(for platform: Platform.Name) -> Consumer {
        Consumer(spec: self, platform: platform)
    }

    // MARK: - Serialization

    /// The spec as podspec JSON (root specs include nested specs).
    public var json: JSON {
        var object = attributes
        if !subspecs.isEmpty { object["subspecs"] = .array(subspecs.map(\.json)) }
        if !testSpecs.isEmpty { object["testspecs"] = .array(testSpecs.map(\.json)) }
        if !appSpecs.isEmpty { object["appspecs"] = .array(appSpecs.map(\.json)) }
        return .object(object)
    }

    public static func == (lhs: Specification, rhs: Specification) -> Bool {
        lhs.name == rhs.name && lhs.version == rhs.version && lhs.attributes == rhs.attributes
            && lhs.subspecs == rhs.subspecs && lhs.testSpecs == rhs.testSpecs && lhs.appSpecs == rhs.appSpecs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(version)
    }
}

/// Where a pod's files are downloaded from (`s.source`).
public enum PodSource: Sendable, Hashable, CustomStringConvertible {
    case git(url: String, reference: ExternalSource.GitReference, submodules: Bool)
    case http(url: String, type: String?, sha256: String?)
    case path(String)

    public init?(json: JSON) {
        if let url = json["git"]?.string {
            let reference: ExternalSource.GitReference =
                if let tag = json["tag"]?.string { .tag(tag) }
                else if let commit = json["commit"]?.string { .commit(commit) }
                else if let branch = json["branch"]?.string { .branch(branch) }
                else { .defaultBranch }
            self = .git(url: url, reference: reference, submodules: json["submodules"]?.bool ?? false)
        } else if let url = json["http"]?.string {
            self = .http(url: url, type: json["type"]?.string, sha256: json["sha256"]?.string)
        } else if let path = json["path"]?.string {
            self = .path(path)
        } else {
            return nil
        }
    }

    public var description: String {
        switch self {
        case .git(let url, let reference, _):
            switch reference {
            case .tag(let tag): "\(url) (tag \(tag))"
            case .branch(let branch): "\(url) (branch \(branch))"
            case .commit(let commit): "\(url) (commit \(commit))"
            case .defaultBranch: url
            }
        case .http(let url, _, _): url
        case .path(let path): path
        }
    }
}
