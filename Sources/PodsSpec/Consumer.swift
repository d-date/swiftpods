public import PodsCore

/// The attributes of a specification resolved for a single platform.
///
/// Mirrors `Pod::Specification::Consumer`: values declared under a platform key
/// (`"ios": { ... }`) are merged with the multi-platform values, and attributes marked
/// as *inherited* also include the values of parent specifications.
public struct Consumer: Sendable {
    public let spec: Specification
    public let platform: Platform.Name

    /// Attributes whose values from parent specs apply to subspecs.
    static let inheritedAttributes: Set<String> = [
        "dependencies", "frameworks", "weak_frameworks", "libraries", "compiler_flags",
        "pod_target_xcconfig", "user_target_xcconfig", "xcconfig", "requires_arc",
        "header_dir", "header_mappings_dir", "prefix_header_contents", "prefix_header_file",
        "module_map", "info_plist", "script_phases",
    ]

    /// Singular aliases accepted in podspecs.
    static let aliases: [String: String] = [
        "framework": "frameworks", "weak_framework": "weak_frameworks", "library": "libraries",
        "resource": "resources", "vendored_framework": "vendored_frameworks",
        "vendored_library": "vendored_libraries", "preserve_path": "preserve_paths",
        "script_phase": "script_phases", "dependency": "dependencies",
    ]

    init(spec: Specification, platform: Platform.Name) {
        self.spec = spec
        self.platform = platform
    }

    /// Raw values for `key`, ordered from the outermost spec to this one.
    private func values(_ key: String) -> [JSON] {
        let chain = Consumer.inheritedAttributes.contains(key) ? spec.ancestors + [spec.attributes] : [spec.attributes]
        let keys = [key] + Consumer.aliases.filter { $0.value == key }.map(\.key)
        var result: [JSON] = []
        for object in chain {
            for k in keys {
                if let value = object[k] { result.append(value) }
                if let platformValue = object[platform.rawValue]?[k] { result.append(platformValue) }
            }
        }
        return result
    }

    /// A string-or-list attribute, concatenated across the chain.
    public func list(_ key: String) -> [String] {
        var seen = Set<String>()
        return values(key).flatMap(\.stringList).filter { seen.insert($0).inserted }
    }

    /// A scalar attribute; the innermost declaration wins.
    public func string(_ key: String) -> String? {
        values(key).last?.string
    }

    public func bool(_ key: String) -> Bool? {
        values(key).last?.bool
    }

    /// A dictionary of string values (xcconfigs); later values are appended, as CocoaPods does.
    public func stringDictionary(_ key: String) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        for case .object(let object) in values(key) {
            for pair in object.pairs {
                guard let value = pair.value.string ?? pair.value.array.map({ $0.compactMap(\.string).joined(separator: " ") }) else { continue }
                if let index = result.firstIndex(where: { $0.key == pair.key }) {
                    if result[index].value != value { result[index].value += " " + value }
                } else {
                    result.append((pair.key, value))
                }
            }
        }
        return result
    }

    // MARK: - File patterns

    public var sourceFiles: [String] { list("source_files") }
    public var excludeFiles: [String] { list("exclude_files") }
    public var publicHeaderFiles: [String] { list("public_header_files") }
    public var privateHeaderFiles: [String] { list("private_header_files") }
    public var projectHeaderFiles: [String] { list("project_header_files") }
    public var resources: [String] { list("resources") }
    public var preservePaths: [String] { list("preserve_paths") }
    public var vendoredFrameworks: [String] { list("vendored_frameworks") }
    public var vendoredLibraries: [String] { list("vendored_libraries") }

    /// `resource_bundles`: bundle name → file patterns.
    public var resourceBundles: [(name: String, patterns: [String])] {
        var result: [(name: String, patterns: [String])] = []
        for case .object(let object) in values("resource_bundles") {
            for pair in object.pairs {
                if let index = result.firstIndex(where: { $0.name == pair.key }) {
                    result[index].patterns += pair.value.stringList
                } else {
                    result.append((pair.key, pair.value.stringList))
                }
            }
        }
        return result
    }

    // MARK: - Build settings

    public var frameworks: [String] { list("frameworks") }
    public var weakFrameworks: [String] { list("weak_frameworks") }
    public var libraries: [String] { list("libraries") }
    public var compilerFlags: [String] { list("compiler_flags") }
    public var podTargetXCConfig: [(key: String, value: String)] { stringDictionary("pod_target_xcconfig") + stringDictionary("xcconfig") }
    public var userTargetXCConfig: [(key: String, value: String)] { stringDictionary("user_target_xcconfig") + stringDictionary("xcconfig") }
    public var requiresARC: Bool { bool("requires_arc") ?? true }
    public var headerDir: String? { string("header_dir") }
    public var headerMappingsDir: String? { string("header_mappings_dir") }
    /// Custom module map path; `nil` when absent or disabled with `module_map = false`.
    public var moduleMap: String? {
        guard let value = values("module_map").last, value.bool == nil else { return nil }
        return value.string
    }
    /// `module_map = false` disables module map generation.
    public var isModuleMapDisabled: Bool { values("module_map").last?.bool == false }
    /// The prefix header path; `nil` when absent or disabled with `prefix_header_file = false`.
    public var prefixHeaderFile: String? {
        guard let value = values("prefix_header_file").last, value.bool == nil else { return nil }
        return value.string
    }
    /// `prefix_header_file = false` disables the generated prefix header.
    public var isPrefixHeaderDisabled: Bool { values("prefix_header_file").last?.bool == false }
    public var prefixHeaderContents: String? {
        let contents = list("prefix_header_contents")
        return contents.isEmpty ? nil : contents.joined(separator: "\n")
    }

    /// Declared dependencies (including inherited ones).
    public var dependencies: [Dependency] {
        var result: [Dependency] = []
        for case .object(let object) in values("dependencies") {
            for pair in object.pairs {
                let requirement = (try? Requirement(parsing: pair.value.stringList)) ?? .any
                if let index = result.firstIndex(where: { $0.name == pair.key }) {
                    result[index] = Dependency(name: pair.key, requirement: result[index].requirement.merging(requirement))
                } else {
                    result.append(Dependency(name: pair.key, requirement: requirement))
                }
            }
        }
        // A subspec never depends on itself or its ancestors.
        return result.filter { !spec.name.hasPrefix($0.name + "/") && $0.name != spec.name }
    }

    /// `script_phases`.
    public var scriptPhases: [ScriptPhase] {
        values("script_phases").flatMap { value -> [JSON] in
            if case .array(let items) = value { items } else { [value] }
        }.compactMap(ScriptPhase.init(json:))
    }
}

/// A custom build phase declared with `script_phases`.
public struct ScriptPhase: Sendable, Hashable {
    public enum Position: String, Sendable {
        case beforeCompile = "before_compile", afterCompile = "after_compile"
        case beforeHeaders = "before_headers", afterHeaders = "after_headers"
        case any
    }

    public let name: String
    public let script: String
    public let shellPath: String
    public let inputFiles: [String]
    public let outputFiles: [String]
    public let position: Position
    public let alwaysOutOfDate: Bool

    public init?(json: JSON) {
        guard let name = json["name"]?.string, let script = json["script"]?.string else { return nil }
        self.name = name
        self.script = script
        self.shellPath = json["shell_path"]?.string ?? "/bin/sh"
        self.inputFiles = json["input_files"]?.stringList ?? []
        self.outputFiles = json["output_files"]?.stringList ?? []
        self.position = json["execution_position"]?.string.flatMap(Position.init(rawValue:)) ?? .any
        self.alwaysOutOfDate = json["always_out_of_date"]?.bool ?? (json["always_out_of_date"]?.string == "1")
    }
}
