public import PodsCore

/// A dependency declared in a Podfile, with its per-pod options.
public struct PodDependency: Sendable, Hashable {
    public var dependency: Dependency
    /// Build configurations the pod is linked into; empty means all.
    public var configurations: [String] = []
    public var modularHeaders: Bool?
    public var inhibitWarnings: Bool?
    public var testSpecs: [String] = []
    public var appSpecs: [String] = []
    /// Spec source URL to take the pod from (`:source => '...'`).
    public var source: String?

    public init(_ dependency: Dependency) { self.dependency = dependency }

    public var name: String { dependency.name }
}

/// A SwiftPM package declared in the Podfile (`packages:`).
public struct SwiftPackageDependency: Sendable, Hashable {
    public let url: String
    public let requirement: Requirement
    /// Set when the Podfile deliberately overrides the pods' requirement; holds the stated reason.
    public let unsafeOverrideReason: String?

    public init(url: String, requirement: Requirement, unsafeOverrideReason: String? = nil) {
        self.url = url
        self.requirement = requirement
        self.unsafeOverrideReason = unsafeOverrideReason
    }

    /// The SwiftPM identity: the last path component of the URL without `.git`, lowercased.
    public var identity: String {
        var name = url.lastPathComponent
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return name.lowercased()
    }
}

/// Settings for generating a distribution `Package.swift`.
public struct DistributionSettings: Sendable, Hashable {
    public let name: String
    public let url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

/// A product of a declared SwiftPM package that a target links (`.product(name:package:)`).
public struct PackageProductDependency: Sendable, Hashable {
    public let name: String
    public let package: String

    public init(name: String, package: String) {
        self.name = name
        self.package = package
    }
}

/// How a child target inherits from its parent (`inherit!`).
public enum Inheritance: String, Sendable, Hashable {
    case complete
    case none
    case searchPaths = "search_paths"
}

/// `use_frameworks!` settings.
public struct FrameworkSettings: Sendable, Hashable {
    public enum Linkage: String, Sendable, Hashable { case dynamic, `static` }
    public var linkage: Linkage
    public init(linkage: Linkage) { self.linkage = linkage }
}

/// A node in the Podfile's target tree (CocoaPods' `TargetDefinition`).
public struct TargetDefinition: Sendable, Hashable {
    public var name: String
    public var isAbstract: Bool
    public var platform: Platform?
    public var inheritance: Inheritance = .complete
    /// `nil` = inherit from parent; `.some(nil)` = explicitly disabled.
    public var usesFrameworks: FrameworkSettings??
    public var inhibitAllWarnings: Bool?
    public var inhibitWarningsForPods: [String] = []
    public var useModularHeadersForAll: Bool?
    public var modularHeadersForPods: [String] = []
    public var userProjectPath: String?
    /// Build configuration name → `debug` / `release`.
    public var buildConfigurations: [String: String] = [:]
    public var dependencies: [PodDependency] = []
    public var packageProducts: [PackageProductDependency] = []
    public var children: [TargetDefinition] = []

    public init(name: String, isAbstract: Bool) {
        self.name = name
        self.isAbstract = isAbstract
    }
}

/// A non-abstract target with every inherited setting resolved.
public struct ResolvedTarget: Sendable, Hashable {
    public let name: String
    public let platform: Platform?
    public let usesFrameworks: FrameworkSettings?
    public let inhibitAllWarnings: Bool
    public let inhibitWarningsForPods: Set<String>
    public let useModularHeadersForAll: Bool
    public let modularHeadersForPods: Set<String>
    public let userProjectPath: String?
    public let buildConfigurations: [String: String]
    /// Pods linked into the target (own plus inherited with `:complete`).
    public let dependencies: [PodDependency]
    /// SwiftPM package products linked into the target (own plus inherited with `:complete`).
    public let packageProducts: [PackageProductDependency]
    /// Labels of ancestor targets whose pods are only visible through search paths.
    public let searchPathsTargets: [String]
    /// The path of target names from the root, used for aggregate target naming.
    public let path: [String]

    /// `Pods-App` style label used for the aggregate target.
    public var label: String { Podfile.label(for: path) }
}

/// The parsed Podfile.
public struct Podfile: Sendable, Hashable {
    public static let trunkURL = "https://cdn.cocoapods.org/"

    public var sources: [String]
    public var workspacePath: String?
    public var installationOptions: [String: JSON]
    public var root: TargetDefinition
    /// SwiftPM packages resolved together with the pods.
    public var swiftPackages: [SwiftPackageDependency] = []
    /// Distribution `Package.swift` settings, if declared.
    public var distribution: DistributionSettings?
    /// Ruby hooks (`post_install`, ...) that were declared but cannot be run.
    public var unsupportedHooks: [String] = []
    /// Plugins (`plugin 'cocoapods-keys'`) that were declared but are not supported.
    public var plugins: [String] = []

    public init(sources: [String] = [], workspacePath: String? = nil, installationOptions: [String: JSON] = [:], root: TargetDefinition) {
        self.sources = sources
        self.workspacePath = workspacePath
        self.installationOptions = installationOptions
        self.root = root
    }

    /// Declared sources, defaulting to trunk.
    public var effectiveSources: [String] { sources.isEmpty ? [Self.trunkURL] : sources }

    public func installationOption(_ key: String) -> Bool? { installationOptions[key]?.bool }

    /// Every target definition, depth-first.
    public var allTargetDefinitions: [TargetDefinition] {
        func walk(_ definition: TargetDefinition) -> [TargetDefinition] {
            [definition] + definition.children.flatMap(walk)
        }
        return walk(root)
    }

    /// All dependencies across all targets, deduplicated by name and source.
    public var allDependencies: [PodDependency] {
        var seen = Set<PodDependency>()
        return allTargetDefinitions.flatMap(\.dependencies).filter { seen.insert($0).inserted }
    }

    static func label(for path: [String]) -> String {
        (["Pods"] + path.filter { $0 != "Pods" }).joined(separator: "-")
    }

    /// Non-abstract targets with inherited values applied.
    public var resolvedTargets: [ResolvedTarget] {
        var result: [ResolvedTarget] = []
        func walk(_ definition: TargetDefinition, ancestors: [TargetDefinition]) {
            let chain = ancestors + [definition]
            if !definition.isAbstract {
                result.append(resolve(chain))
            }
            for child in definition.children { walk(child, ancestors: chain) }
        }
        walk(root, ancestors: [])
        return result
    }

    private func resolve(_ chain: [TargetDefinition]) -> ResolvedTarget {
        let definition = chain.last!
        func inherited<T>(_ value: (TargetDefinition) -> T?) -> T? {
            for node in chain.reversed() { if let v = value(node) { return v } }
            return nil
        }
        // `:complete` links the parent's pods too; `:search_paths` only exposes the
        // nearest concrete parent's headers/modules (e.g. a test target hosted by an app).
        func linked(_ chain: ArraySlice<TargetDefinition>) -> [PodDependency] {
            let node = chain.last!
            guard chain.count > 1, node.inheritance == .complete else { return node.dependencies }
            return node.dependencies + linked(chain.dropLast())
        }
        func linkedProducts(_ chain: ArraySlice<TargetDefinition>) -> [PackageProductDependency] {
            let node = chain.last!
            guard chain.count > 1, node.inheritance == .complete else { return node.packageProducts }
            return node.packageProducts + linkedProducts(chain.dropLast())
        }
        let dependencies = linked(chain[...])
        var seenProducts = Set<PackageProductDependency>()
        let uniqueProducts = linkedProducts(chain[...]).filter { seenProducts.insert($0).inserted }
        var searchPaths: [String] = []
        if definition.inheritance == .searchPaths,
           let host = chain.dropLast().lastIndex(where: { !$0.isAbstract }) {
            searchPaths.append(Self.label(for: chain[...host].map(\.name)))
        }
        var seen = Set<String>()
        let uniqueDependencies = dependencies.filter { seen.insert($0.name).inserted }

        return ResolvedTarget(
            name: definition.name,
            platform: inherited(\.platform),
            usesFrameworks: inherited(\.usesFrameworks) ?? nil,
            inhibitAllWarnings: inherited(\.inhibitAllWarnings) ?? false,
            inhibitWarningsForPods: Set(chain.flatMap(\.inhibitWarningsForPods)),
            useModularHeadersForAll: inherited(\.useModularHeadersForAll) ?? false,
            modularHeadersForPods: Set(chain.flatMap(\.modularHeadersForPods)),
            userProjectPath: inherited(\.userProjectPath),
            buildConfigurations: chain.reduce(into: [:]) { $0.merge($1.buildConfigurations) { $1 } },
            dependencies: uniqueDependencies,
            packageProducts: uniqueProducts,
            searchPathsTargets: searchPaths,
            path: chain.map(\.name)
        )
    }
}
