public import PodsCore

/// Conversion from the hash format of CocoaPods' `Podfile#to_hash`, which is shared by
/// `Podfile.json`, Swift manifests and the Ruby DSL evaluator.
extension Podfile {
    public struct FormatError: Error, CustomStringConvertible, Equatable {
        public let message: String
        public var description: String { "Invalid Podfile: \(message)" }
    }

    public init(json: JSON) throws(FormatError) {
        guard let definitions = json["target_definitions"]?.array, let rootJSON = definitions.first else {
            throw FormatError(message: "missing `target_definitions`")
        }
        var options: [String: JSON] = [:]
        for pair in json["installation_method"]?["options"]?.object?.pairs ?? [] { options[pair.key] = pair.value }
        self.init(
            sources: json["sources"]?.stringList ?? [],
            workspacePath: json["workspace"]?.string,
            installationOptions: options,
            root: try Self.targetDefinition(rootJSON)
        )
        self.swiftPackages = try Self.swiftPackages(json["swift_packages"])
        let declared = Set(swiftPackages.map(\.identity))
        for definition in allTargetDefinitions {
            for product in definition.packageProducts where !declared.contains(product.package.lowercased()) {
                throw FormatError(message: "product `\(product.name)` of target `\(definition.name)` refers to the undeclared package `\(product.package)`")
            }
        }
        self.plugins = json["plugins"]?.object?.keys ?? []
        self.unsupportedHooks = json["hooks"]?.stringList ?? []
    }

    private static func targetDefinition(_ json: JSON) throws(FormatError) -> TargetDefinition {
        guard let name = json["name"]?.string else { throw FormatError(message: "target without a name") }
        var definition = TargetDefinition(name: name, isAbstract: json["abstract"]?.bool ?? false)
        if case .object(let platform)? = json["platform"], let first = platform.pairs.first {
            guard let platformName = Platform.Name(podfileName: first.key) else {
                throw FormatError(message: "unknown platform `\(first.key)`")
            }
            definition.platform = Platform(platformName, first.value.string.flatMap(Version.init))
        } else if let platformName = json["platform"]?.string {
            guard let name = Platform.Name(podfileName: platformName) else {
                throw FormatError(message: "unknown platform `\(platformName)`")
            }
            definition.platform = Platform(name)
        }
        if let inheritance = json["inheritance"]?.string {
            guard let value = Inheritance(rawValue: inheritance) else {
                throw FormatError(message: "unknown inheritance `\(inheritance)`")
            }
            definition.inheritance = value
        }
        switch json["uses_frameworks"] {
        case .bool(true)?: definition.usesFrameworks = .some(FrameworkSettings(linkage: .dynamic))
        case .bool(false)?: definition.usesFrameworks = .some(nil)
        case .object(let settings)?:
            let linkage = settings["linkage"]?.string.flatMap(FrameworkSettings.Linkage.init(rawValue:)) ?? .dynamic
            definition.usesFrameworks = .some(FrameworkSettings(linkage: linkage))
        default: break
        }
        if let inhibit = json["inhibit_warnings"] {
            definition.inhibitAllWarnings = inhibit["all"]?.bool
            definition.inhibitWarningsForPods = inhibit["for_pods"]?.stringList ?? []
        }
        if let modular = json["use_modular_headers"] {
            definition.useModularHeadersForAll = modular["all"]?.bool
            definition.modularHeadersForPods = modular["for_pods"]?.stringList ?? []
        }
        definition.userProjectPath = json["user_project_path"]?.string
        for pair in json["build_configurations"]?.object?.pairs ?? [] {
            definition.buildConfigurations[pair.key] = pair.value.string
        }
        for entry in json["dependencies"]?.array ?? [] {
            definition.dependencies += try dependencies(entry)
        }
        for entry in json["swift_package_products"]?.array ?? [] {
            guard let name = entry["name"]?.string, let package = entry["package"]?.string else {
                throw FormatError(message: "invalid `swift_package_products` entry")
            }
            definition.packageProducts.append(PackageProductDependency(name: name, package: package))
        }
        for child in json["children"]?.array ?? [] {
            definition.children.append(try targetDefinition(child))
        }
        return definition
    }

    private static func swiftPackages(_ json: JSON?) throws(FormatError) -> [SwiftPackageDependency] {
        var result: [SwiftPackageDependency] = []
        for entry in json?.array ?? [] {
            guard let url = entry["url"]?.string else { throw FormatError(message: "swift package without a `url`") }
            let constraints = entry["requirement"]?.stringList ?? []
            do {
                result.append(SwiftPackageDependency(url: url, requirement: try Requirement(parsing: constraints)))
            } catch {
                throw FormatError(message: "invalid requirement for package `\(url)`: \(constraints.joined(separator: ", "))")
            }
        }
        return result
    }

    /// Parses `"Name"` or `{"Name": ["~> 1.0", {"git": "...", "configurations": [...]}]}`.
    private static func dependencies(_ json: JSON) throws(FormatError) -> [PodDependency] {
        if let name = json.string { return [PodDependency(Dependency(name: name))] }
        guard case .object(let object) = json, let pair = object.pairs.first else {
            throw FormatError(message: "invalid dependency entry")
        }
        let name = pair.key
        var requirements: [String] = []
        var options = OrderedObject()
        for item in pair.value.array ?? [pair.value] {
            if let requirement = item.string {
                requirements.append(requirement)
            } else if case .object(let hash) = item {
                for option in hash.pairs {
                    options[option.key.hasPrefix(":") ? String(option.key.dropFirst()) : option.key] = option.value
                }
            }
        }
        let requirement: Requirement
        do {
            requirement = try Requirement(parsing: requirements)
        } catch {
            throw FormatError(message: "invalid requirement for `\(name)`: \(requirements.joined(separator: ", "))")
        }
        var external: [String: String] = [:]
        for key in ["git", "tag", "branch", "commit", "path", "podspec"] {
            if let value = options[key]?.string { external[key] = value }
        }
        let externalSource = ExternalSource(entries: external)
        if externalSource != nil, !requirement.isAny {
            throw FormatError(message: "`\(name)` cannot have both a version requirement and an external source")
        }

        func make(_ fullName: String) -> PodDependency {
            var dependency = PodDependency(Dependency(name: fullName, requirement: requirement, externalSource: externalSource))
            dependency.configurations = (options["configurations"] ?? options["configuration"])?.stringList ?? []
            dependency.modularHeaders = options["modular_headers"]?.bool
            dependency.inhibitWarnings = options["inhibit_warnings"]?.bool
            dependency.testSpecs = options["testspecs"]?.stringList ?? []
            dependency.appSpecs = options["appspecs"]?.stringList ?? []
            dependency.source = options["source"]?.string
            return dependency
        }
        // `:subspecs => ['A', 'B']` expands into one dependency per subspec.
        if let subspecs = options["subspecs"]?.stringList, !subspecs.isEmpty {
            return subspecs.map { make(name + "/" + $0) }
        }
        return [make(name)]
    }
}
