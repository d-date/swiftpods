// SwiftPodsDescription: the API used by `Podfile.swift` manifests.
//
// This file is compiled together with the user's manifest (it is embedded into the
// `swiftpods` binary), so it must not depend on anything but the standard library.

/// A Podfile written in Swift, in the style of SwiftPM's `Package.swift`.
///
/// ```swift
/// let podfile = Podfile(
///     platform: .iOS(.v15),
///     useFrameworks: .static,
///     targets: [
///         .target(
///             name: "App",
///             dependencies: [
///                 .pod(name: "Alamofire", from: "5.9.0"),
///             ],
///             targets: [
///                 .target(name: "AppTests", inherit: .searchPaths),
///             ]
///         ),
///     ]
/// )
/// ```
public final class Podfile {
    /// Spec sources; defaults to the CocoaPods trunk when empty.
    public var sources: [Source]
    /// Default platform for every target.
    public var platform: SupportedPlatform?
    /// `use_frameworks!` setting for every target.
    public var useFrameworks: FrameworkLinkage?
    /// `use_modular_headers!` for every pod.
    public var useModularHeaders: Bool
    /// `inhibit_all_warnings!`
    public var inhibitAllWarnings: Bool
    /// `project 'App.xcodeproj'`
    public var project: Project?
    /// `workspace 'App.xcworkspace'`
    public var workspace: String?
    /// `install! 'cocoapods', ...`
    public var installationOptions: InstallationOptions
    /// SwiftPM packages resolved together with the pods.
    public var packages: [SwiftPackage]
    /// Settings for generating a distribution `Package.swift`.
    public var distribution: Distribution?
    /// Pods linked into every target.
    public var dependencies: [Pod]
    public var targets: [Target]

    public init(
        sources: [Source] = [],
        platform: SupportedPlatform? = nil,
        useFrameworks: FrameworkLinkage? = nil,
        useModularHeaders: Bool = false,
        inhibitAllWarnings: Bool = false,
        project: Project? = nil,
        workspace: String? = nil,
        installationOptions: InstallationOptions = .init(),
        packages: [SwiftPackage] = [],
        distribution: Distribution? = nil,
        dependencies: [Pod] = [],
        targets: [Target] = []
    ) {
        self.sources = sources
        self.platform = platform
        self.useFrameworks = useFrameworks
        self.useModularHeaders = useModularHeaders
        self.inhibitAllWarnings = inhibitAllWarnings
        self.project = project
        self.workspace = workspace
        self.installationOptions = installationOptions
        self.packages = packages
        self.distribution = distribution
        self.dependencies = dependencies
        self.targets = targets
        _ManifestRegistry.register(.podfile(self))
    }

    var json: _JSON {
        var object: [(String, _JSON)] = []
        if !sources.isEmpty { object.append(("sources", .array(sources.map { .string($0.url) }))) }
        if let workspace { object.append(("workspace", .string(workspace))) }
        let options = installationOptions.jsonPairs
        if !options.isEmpty {
            object.append(("installation_method", .object([("name", .string("cocoapods")), ("options", .object(options))])))
        }
        // The root of CocoaPods' target tree is the implicit abstract `Pods` target.
        let root = Target(
            name: "Pods", isAbstract: true, platform: platform, inherit: nil, useFrameworks: useFrameworks,
            useModularHeaders: useModularHeaders ? true : nil, inhibitAllWarnings: inhibitAllWarnings ? true : nil,
            project: project, dependencies: dependencies, targets: targets
        )
        if !packages.isEmpty { object.append(("swift_packages", .array(packages.map(\.json)))) }
        if let distribution { object.append(("distribution", distribution.json)) }
        object.append(("target_definitions", .array([root.json])))
        return .object(object)
    }
}

// MARK: - Sources

/// A spec source (`source '...'`).
public struct Source: Sendable, ExpressibleByStringLiteral {
    public let url: String

    public init(url: String) { self.url = url }
    public init(stringLiteral value: String) { self.url = value }

    /// The CocoaPods trunk CDN.
    public static let trunk = Source(url: "https://cdn.cocoapods.org/")
    /// A git spec repository.
    public static func git(_ url: String) -> Source { Source(url: url) }
}

// MARK: - Platforms

/// A platform and its deployment target, e.g. `.iOS(.v15)` or `.iOS("15.4")`.
public struct SupportedPlatform: Sendable {
    let name: String
    let version: String?

    public static func iOS(_ version: IOSVersion) -> SupportedPlatform { .init(name: "ios", version: version.value) }
    public static func iOS(_ version: String) -> SupportedPlatform { .init(name: "ios", version: version) }
    public static func macOS(_ version: MacOSVersion) -> SupportedPlatform { .init(name: "osx", version: version.value) }
    public static func macOS(_ version: String) -> SupportedPlatform { .init(name: "osx", version: version) }
    public static func tvOS(_ version: TVOSVersion) -> SupportedPlatform { .init(name: "tvos", version: version.value) }
    public static func tvOS(_ version: String) -> SupportedPlatform { .init(name: "tvos", version: version) }
    public static func watchOS(_ version: WatchOSVersion) -> SupportedPlatform { .init(name: "watchos", version: version.value) }
    public static func watchOS(_ version: String) -> SupportedPlatform { .init(name: "watchos", version: version) }
    public static func visionOS(_ version: VisionOSVersion) -> SupportedPlatform { .init(name: "visionos", version: version.value) }
    public static func visionOS(_ version: String) -> SupportedPlatform { .init(name: "visionos", version: version) }

    var json: _JSON { .object([(name, version.map(_JSON.string) ?? .null)]) }
}

public struct IOSVersion: Sendable {
    let value: String
    public static let v12 = IOSVersion(value: "12.0")
    public static let v13 = IOSVersion(value: "13.0")
    public static let v14 = IOSVersion(value: "14.0")
    public static let v15 = IOSVersion(value: "15.0")
    public static let v16 = IOSVersion(value: "16.0")
    public static let v17 = IOSVersion(value: "17.0")
    public static let v18 = IOSVersion(value: "18.0")
    public static let v26 = IOSVersion(value: "26.0")
}

public struct MacOSVersion: Sendable {
    let value: String
    public static let v10_13 = MacOSVersion(value: "10.13")
    public static let v10_15 = MacOSVersion(value: "10.15")
    public static let v11 = MacOSVersion(value: "11.0")
    public static let v12 = MacOSVersion(value: "12.0")
    public static let v13 = MacOSVersion(value: "13.0")
    public static let v14 = MacOSVersion(value: "14.0")
    public static let v15 = MacOSVersion(value: "15.0")
    public static let v26 = MacOSVersion(value: "26.0")
}

public struct TVOSVersion: Sendable {
    let value: String
    public static let v12 = TVOSVersion(value: "12.0")
    public static let v13 = TVOSVersion(value: "13.0")
    public static let v14 = TVOSVersion(value: "14.0")
    public static let v15 = TVOSVersion(value: "15.0")
    public static let v16 = TVOSVersion(value: "16.0")
    public static let v17 = TVOSVersion(value: "17.0")
    public static let v18 = TVOSVersion(value: "18.0")
    public static let v26 = TVOSVersion(value: "26.0")
}

public struct WatchOSVersion: Sendable {
    let value: String
    public static let v4 = WatchOSVersion(value: "4.0")
    public static let v6 = WatchOSVersion(value: "6.0")
    public static let v7 = WatchOSVersion(value: "7.0")
    public static let v8 = WatchOSVersion(value: "8.0")
    public static let v9 = WatchOSVersion(value: "9.0")
    public static let v10 = WatchOSVersion(value: "10.0")
    public static let v11 = WatchOSVersion(value: "11.0")
    public static let v26 = WatchOSVersion(value: "26.0")
}

public struct VisionOSVersion: Sendable {
    let value: String
    public static let v1 = VisionOSVersion(value: "1.0")
    public static let v2 = VisionOSVersion(value: "2.0")
    public static let v26 = VisionOSVersion(value: "26.0")
}

// MARK: - Settings

/// `use_frameworks!` linkage.
public enum FrameworkLinkage: Sendable {
    /// `use_frameworks!` (dynamic frameworks).
    case dynamic
    /// `use_frameworks! :linkage => :static`
    case `static`
    /// Explicitly disable frameworks for a target (static libraries).
    case disabled

    var json: _JSON {
        switch self {
        case .dynamic: .bool(true)
        case .static: .object([("linkage", .string("static")), ("packaging", .string("framework"))])
        case .disabled: .bool(false)
        }
    }
}

/// `project 'App.xcodeproj', 'Beta' => :release`
public struct Project: Sendable {
    public enum ConfigurationKind: String, Sendable { case debug, release }

    public var path: String
    public var configurations: [String: ConfigurationKind]

    public init(path: String, configurations: [String: ConfigurationKind] = [:]) {
        self.path = path
        self.configurations = configurations
    }
}

/// `install! 'cocoapods', ...` options.
public struct InstallationOptions: Sendable {
    public var generateMultiplePodProjects: Bool?
    public var incrementalInstallation: Bool?
    public var deterministicUUIDs: Bool?
    public var integrateTargets: Bool?
    public var warnForMultiplePodSources: Bool?
    public var disableInputOutputPaths: Bool?

    public init(
        generateMultiplePodProjects: Bool? = nil,
        incrementalInstallation: Bool? = nil,
        deterministicUUIDs: Bool? = nil,
        integrateTargets: Bool? = nil,
        warnForMultiplePodSources: Bool? = nil,
        disableInputOutputPaths: Bool? = nil
    ) {
        self.generateMultiplePodProjects = generateMultiplePodProjects
        self.incrementalInstallation = incrementalInstallation
        self.deterministicUUIDs = deterministicUUIDs
        self.integrateTargets = integrateTargets
        self.warnForMultiplePodSources = warnForMultiplePodSources
        self.disableInputOutputPaths = disableInputOutputPaths
    }

    var jsonPairs: [(String, _JSON)] {
        let all: [(String, Bool?)] = [
            ("generate_multiple_pod_projects", generateMultiplePodProjects),
            ("incremental_installation", incrementalInstallation),
            ("deterministic_uuids", deterministicUUIDs),
            ("integrate_targets", integrateTargets),
            ("warn_for_multiple_pod_sources", warnForMultiplePodSources),
            ("disable_input_output_paths", disableInputOutputPaths),
        ]
        return all.compactMap { key, value in value.map { (key, .bool($0)) } }
    }
}

// MARK: - Targets

/// Which settings a child target inherits from its parent (`inherit! :search_paths`).
public enum Inheritance: String, Sendable {
    case complete, none
    case searchPaths = "search_paths"
}

/// A user target (`target 'App' do ... end`) or an abstract target.
public struct Target: Sendable {
    public var name: String
    public var isAbstract: Bool
    public var platform: SupportedPlatform?
    public var inherit: Inheritance?
    public var useFrameworks: FrameworkLinkage?
    public var useModularHeaders: Bool?
    public var inhibitAllWarnings: Bool?
    public var project: Project?
    public var dependencies: [Pod]
    /// Nested targets (e.g. test targets).
    public var targets: [Target]

    init(
        name: String, isAbstract: Bool, platform: SupportedPlatform?, inherit: Inheritance?,
        useFrameworks: FrameworkLinkage?, useModularHeaders: Bool?, inhibitAllWarnings: Bool?,
        project: Project?, dependencies: [Pod], targets: [Target]
    ) {
        self.name = name
        self.isAbstract = isAbstract
        self.platform = platform
        self.inherit = inherit
        self.useFrameworks = useFrameworks
        self.useModularHeaders = useModularHeaders
        self.inhibitAllWarnings = inhibitAllWarnings
        self.project = project
        self.dependencies = dependencies
        self.targets = targets
    }

    /// `target 'App' do ... end`
    public static func target(
        name: String,
        platform: SupportedPlatform? = nil,
        inherit: Inheritance? = nil,
        useFrameworks: FrameworkLinkage? = nil,
        useModularHeaders: Bool? = nil,
        inhibitAllWarnings: Bool? = nil,
        project: Project? = nil,
        dependencies: [Pod] = [],
        targets: [Target] = []
    ) -> Target {
        Target(
            name: name, isAbstract: false, platform: platform, inherit: inherit, useFrameworks: useFrameworks,
            useModularHeaders: useModularHeaders, inhibitAllWarnings: inhibitAllWarnings, project: project,
            dependencies: dependencies, targets: targets
        )
    }

    /// `abstract_target 'Shared' do ... end`: shares pods and settings with its children.
    public static func abstractTarget(
        name: String,
        platform: SupportedPlatform? = nil,
        useFrameworks: FrameworkLinkage? = nil,
        useModularHeaders: Bool? = nil,
        inhibitAllWarnings: Bool? = nil,
        project: Project? = nil,
        dependencies: [Pod] = [],
        targets: [Target]
    ) -> Target {
        Target(
            name: name, isAbstract: true, platform: platform, inherit: nil, useFrameworks: useFrameworks,
            useModularHeaders: useModularHeaders, inhibitAllWarnings: inhibitAllWarnings, project: project,
            dependencies: dependencies, targets: targets
        )
    }

    var json: _JSON {
        var object: [(String, _JSON)] = [("name", .string(name))]
        if isAbstract { object.append(("abstract", .bool(true))) }
        if let platform { object.append(("platform", platform.json)) }
        if let inherit { object.append(("inheritance", .string(inherit.rawValue))) }
        if let useFrameworks { object.append(("uses_frameworks", useFrameworks.json)) }
        if let useModularHeaders { object.append(("use_modular_headers", .object([("all", .bool(useModularHeaders))]))) }
        if let inhibitAllWarnings { object.append(("inhibit_warnings", .object([("all", .bool(inhibitAllWarnings))]))) }
        if let project {
            object.append(("user_project_path", .string(project.path)))
            if !project.configurations.isEmpty {
                let sorted = project.configurations.sorted { $0.key < $1.key }
                object.append(("build_configurations", .object(sorted.map { ($0.key, .string($0.value.rawValue)) })))
            }
        }
        let pods = dependencies.filter { $0.productPackage == nil }
        let products = dependencies.filter { $0.productPackage != nil }
        if !pods.isEmpty { object.append(("dependencies", .array(pods.map(\.json)))) }
        if !products.isEmpty { object.append(("swift_package_products", .array(products.map(\.productJSON)))) }
        if !targets.isEmpty { object.append(("children", .array(targets.map(\.json)))) }
        return .object(object)
    }
}

// MARK: - Swift packages

/// A SwiftPM package that is resolved together with the pods (`.package(url:from:)`).
public struct SwiftPackage: Sendable {
    let url: String
    let requirement: [String]
    let unsafeOverrideReason: String?

    /// `from: "8.0.0"` — up to the next major version, like SwiftPM.
    public static func package(url: String, from version: String, overridingPodRequirements override: PodRequirementOverride? = nil) -> SwiftPackage {
        .package(url: url, .upToNextMajor(from: version), overridingPodRequirements: override)
    }

    /// `exact: "8.0.0"`
    public static func package(url: String, exact version: String, overridingPodRequirements override: PodRequirementOverride? = nil) -> SwiftPackage {
        .package(url: url, .exact(version), overridingPodRequirements: override)
    }

    /// `"1.0.0"..<"2.0.0"`
    public static func package(url: String, _ range: Range<String>, overridingPodRequirements override: PodRequirementOverride? = nil) -> SwiftPackage {
        .package(url: url, .range(range), overridingPodRequirements: override)
    }

    /// `"1.0.0"..."1.9.9"`
    public static func package(url: String, _ range: ClosedRange<String>, overridingPodRequirements override: PodRequirementOverride? = nil) -> SwiftPackage {
        .package(url: url, .range(range), overridingPodRequirements: override)
    }

    /// Any requirement, e.g. `.upToNextMinor(from: "1.2.0")`.
    public static func package(url: String, _ requirement: VersionRequirement, overridingPodRequirements override: PodRequirementOverride? = nil) -> SwiftPackage {
        var reason: String?
        if case .unsafe(let text)? = override { reason = text }
        return SwiftPackage(url: url, requirement: requirement.constraints, unsafeOverrideReason: reason)
    }

    var json: _JSON {
        var object: [(String, _JSON)] = [("url", .string(url)), ("requirement", .array(requirement.map(_JSON.string)))]
        if let unsafeOverrideReason { object.append(("unsafe_override", .object([("reason", .string(unsafeOverrideReason))]))) }
        return .object(object)
    }
}

/// Lets a package requirement replace the one the pods impose on it.
public enum PodRequirementOverride: Sendable {
    /// Replaces the pods' requirement; `reason` records why that is safe.
    case unsafe(reason: String)
}

/// Where and under which name the distribution `Package.swift` is published.
public struct Distribution: Sendable {
    let name: String
    let url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    var json: _JSON {
        .object([("name", .string(name)), ("url", .string(url))])
    }
}

// MARK: - Pods

/// A version requirement, in SwiftPM style (`from:`, ranges) or CocoaPods style (`"~> 5.0"`).
public struct VersionRequirement: Sendable, ExpressibleByStringLiteral {
    let constraints: [String]

    init(constraints: [String]) { self.constraints = constraints }

    /// A CocoaPods requirement string such as `"~> 5.0"` or `">= 1.0, < 2.0"`.
    public init(stringLiteral value: String) { self.constraints = [value] }

    /// `>= version, < next major`
    public static func upToNextMajor(from version: String) -> VersionRequirement {
        VersionRequirement(constraints: [">= \(version)", "< \(bump(version, at: 0))"])
    }

    /// `>= version, < next minor`
    public static func upToNextMinor(from version: String) -> VersionRequirement {
        VersionRequirement(constraints: [">= \(version)", "< \(bump(version, at: 1))"])
    }

    public static func exact(_ version: String) -> VersionRequirement {
        VersionRequirement(constraints: ["= \(version)"])
    }

    /// `"1.0.0"..<"2.0.0"`
    public static func range(_ range: Range<String>) -> VersionRequirement {
        VersionRequirement(constraints: [">= \(range.lowerBound)", "< \(range.upperBound)"])
    }

    /// `"1.0.0"..."1.9.9"`
    public static func range(_ range: ClosedRange<String>) -> VersionRequirement {
        VersionRequirement(constraints: [">= \(range.lowerBound)", "<= \(range.upperBound)"])
    }

    static func bump(_ version: String, at index: Int) -> String {
        var parts = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        while parts.count <= index { parts.append(0) }
        parts[index] += 1
        for i in (index + 1)..<parts.count { parts[i] = 0 }
        return parts.map(String.init).joined(separator: ".")
    }
}

/// A pod dependency (`pod 'Name', ...`).
public struct Pod: Sendable {
    public var name: String
    var requirement: [String]
    var externalSource: [(String, _JSON)]
    public var configurations: [String]
    public var modularHeaders: Bool?
    public var inhibitWarnings: Bool?
    public var subspecs: [String]
    public var testSpecs: [String]
    /// A specific spec source to take the pod from.
    public var source: String?
    /// Set for `.product(name:package:)`: the package the product comes from. `name` is the product name.
    var productPackage: String?

    init(name: String, requirement: [String], externalSource: [(String, _JSON)], configurations: [String],
         modularHeaders: Bool?, inhibitWarnings: Bool?, subspecs: [String], testSpecs: [String], source: String?,
         productPackage: String? = nil) {
        self.name = name
        self.requirement = requirement
        self.externalSource = externalSource
        self.configurations = configurations
        self.modularHeaders = modularHeaders
        self.inhibitWarnings = inhibitWarnings
        self.subspecs = subspecs
        self.testSpecs = testSpecs
        self.source = source
        self.productPackage = productPackage
    }

    /// A product of a SwiftPM package declared in `Podfile.packages`.
    public static func product(name: String, package: String) -> Pod {
        Pod(name: name, requirement: [], externalSource: [], configurations: [], modularHeaders: nil,
            inhibitWarnings: nil, subspecs: [], testSpecs: [], source: nil, productPackage: package)
    }

    var productJSON: _JSON {
        .object([("name", .string(name)), ("package", .string(productPackage ?? ""))])
    }

    /// A pod from a spec source with a CocoaPods requirement (`"~> 5.9"`) or any SwiftPM-style requirement.
    public static func pod(
        name: String,
        _ requirement: VersionRequirement? = nil,
        configurations: [String] = [],
        modularHeaders: Bool? = nil,
        inhibitWarnings: Bool? = nil,
        subspecs: [String] = [],
        testSpecs: [String] = [],
        source: String? = nil
    ) -> Pod {
        Pod(name: name, requirement: requirement?.constraints ?? [], externalSource: [], configurations: configurations,
            modularHeaders: modularHeaders, inhibitWarnings: inhibitWarnings, subspecs: subspecs, testSpecs: testSpecs, source: source)
    }

    /// `from: "5.9.0"` — up to the next major version, like SwiftPM.
    public static func pod(
        name: String,
        from version: String,
        configurations: [String] = [],
        modularHeaders: Bool? = nil,
        inhibitWarnings: Bool? = nil,
        subspecs: [String] = [],
        testSpecs: [String] = []
    ) -> Pod {
        .pod(name: name, .upToNextMajor(from: version), configurations: configurations, modularHeaders: modularHeaders,
             inhibitWarnings: inhibitWarnings, subspecs: subspecs, testSpecs: testSpecs)
    }

    /// `exact: "5.9.1"`
    public static func pod(
        name: String,
        exact version: String,
        configurations: [String] = [],
        modularHeaders: Bool? = nil,
        inhibitWarnings: Bool? = nil,
        subspecs: [String] = [],
        testSpecs: [String] = []
    ) -> Pod {
        .pod(name: name, .exact(version), configurations: configurations, modularHeaders: modularHeaders,
             inhibitWarnings: inhibitWarnings, subspecs: subspecs, testSpecs: testSpecs)
    }

    /// `"5.0.0"..<"6.0.0"`
    public static func pod(
        name: String,
        _ range: Range<String>,
        configurations: [String] = [],
        modularHeaders: Bool? = nil,
        inhibitWarnings: Bool? = nil,
        subspecs: [String] = [],
        testSpecs: [String] = []
    ) -> Pod {
        .pod(name: name, .range(range), configurations: configurations, modularHeaders: modularHeaders,
             inhibitWarnings: inhibitWarnings, subspecs: subspecs, testSpecs: testSpecs)
    }

    /// A pod from a local directory (`:path => '../MyKit'`).
    public static func pod(
        name: String,
        path: String,
        configurations: [String] = [],
        modularHeaders: Bool? = nil,
        inhibitWarnings: Bool? = nil,
        subspecs: [String] = [],
        testSpecs: [String] = []
    ) -> Pod {
        Pod(name: name, requirement: [], externalSource: [("path", .string(path))], configurations: configurations,
            modularHeaders: modularHeaders, inhibitWarnings: inhibitWarnings, subspecs: subspecs, testSpecs: testSpecs, source: nil)
    }

    /// A pod from a git repository. Pass at most one of `tag`, `branch` and `commit`.
    public static func pod(
        name: String,
        git url: String,
        tag: String? = nil,
        branch: String? = nil,
        commit: String? = nil,
        configurations: [String] = [],
        modularHeaders: Bool? = nil,
        inhibitWarnings: Bool? = nil,
        subspecs: [String] = [],
        testSpecs: [String] = []
    ) -> Pod {
        var source: [(String, _JSON)] = [("git", .string(url))]
        if let tag { source.append(("tag", .string(tag))) }
        if let branch { source.append(("branch", .string(branch))) }
        if let commit { source.append(("commit", .string(commit))) }
        return Pod(name: name, requirement: [], externalSource: source, configurations: configurations,
                   modularHeaders: modularHeaders, inhibitWarnings: inhibitWarnings, subspecs: subspecs, testSpecs: testSpecs, source: nil)
    }

    /// A pod defined by a podspec at a path or URL (`:podspec => '...'`).
    public static func pod(
        name: String,
        podspec: String,
        configurations: [String] = [],
        modularHeaders: Bool? = nil,
        inhibitWarnings: Bool? = nil,
        subspecs: [String] = [],
        testSpecs: [String] = []
    ) -> Pod {
        Pod(name: name, requirement: [], externalSource: [("podspec", .string(podspec))], configurations: configurations,
            modularHeaders: modularHeaders, inhibitWarnings: inhibitWarnings, subspecs: subspecs, testSpecs: testSpecs, source: nil)
    }

    /// Encoded like CocoaPods' `to_hash`: `"Name"` or `{"Name": ["~> 1.0", {options}]}`.
    var json: _JSON {
        var options = externalSource
        if !configurations.isEmpty { options.append(("configurations", .array(configurations.map(_JSON.string)))) }
        if let modularHeaders { options.append(("modular_headers", .bool(modularHeaders))) }
        if let inhibitWarnings { options.append(("inhibit_warnings", .bool(inhibitWarnings))) }
        if !subspecs.isEmpty { options.append(("subspecs", .array(subspecs.map(_JSON.string)))) }
        if !testSpecs.isEmpty { options.append(("testspecs", .array(testSpecs.map(_JSON.string)))) }
        if let source { options.append(("source", .string(source))) }
        var values = requirement.map(_JSON.string)
        if !options.isEmpty { values.append(.object(options)) }
        return values.isEmpty ? .string(name) : .object([(name, .array(values))])
    }
}
