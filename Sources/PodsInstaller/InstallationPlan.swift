public import Foundation
public import PodsCore
public import PodsPodfile
public import PodsSpec

/// How a pod target is built.
public enum BuildType: Sendable, Hashable {
    case staticLibrary
    case staticFramework
    case dynamicFramework

    public var isFramework: Bool { self != .staticLibrary }

    init(_ settings: FrameworkSettings?) {
        switch settings?.linkage {
        case nil: self = .staticLibrary
        case .static?: self = .staticFramework
        case .dynamic?: self = .dynamicFramework
        }
    }
}

/// A resolved pod together with where its files live.
public struct InstalledPod: Sendable {
    public let spec: Specification
    /// Spec names activated by the resolver (root and/or subspecs).
    public let activatedSpecs: [String]
    /// `trunk` / spec repo URL for released pods; `nil` for external sources.
    public let sourceName: String?
    public let externalSource: ExternalSource?
    /// Directory containing the pod's files.
    public var location: URL
    /// `true` for `:path` pods, which are used in place ("Development Pods").
    public let isLocal: Bool
    public var checkoutOptions: [String: String]

    public var name: String { spec.name }
}

/// A library product of a SwiftPM package referenced by `Pods.xcodeproj`.
public struct PackageProductRef: Sendable, Hashable {
    public let packageURL: String
    public let product: String
}

/// A target in `Pods.xcodeproj` that builds one pod for one platform.
public struct PodTarget: Sendable {
    /// Xcode target name, e.g. `Alamofire` or `Alamofire-iOS` when the pod is used on several platforms.
    public let name: String
    public let pod: InstalledPod
    /// Library specs (root and/or subspecs) compiled into the target.
    public let specs: [Specification]
    public let platform: Platform
    public let buildType: BuildType
    /// Names of pod targets this one depends on.
    public var dependencyNames: [String]
    public let inhibitWarnings: Bool
    public let swiftVersion: String?
    /// Products of the SwiftPM packages that replace pods this target depends on (not linked here).
    public let packageProducts: [PackageProductRef]
    let files: FileAccessor

    public var rootSpec: Specification { pod.spec }
    public var podName: String { pod.spec.name }
    public var moduleName: String { rootSpec.moduleName }
    /// The product name: the module name for frameworks, the target name for libraries.
    public var productName: String { buildType.isFramework ? moduleName : name }
    public var productFileName: String {
        buildType.isFramework ? "\(productName).framework" : "lib\(productName).a"
    }
    public var usesSwift: Bool { files.usesSwift }
    /// Whether the target compiles anything (pods with only vendored binaries or resources don't).
    public var shouldBuild: Bool { files.hasCompiledSources }
    var consumers: [Consumer] { specs.map { $0.consumer(for: platform.name) } }
}

/// The `Pods-<Target>` aggregate target for a user target.
public struct AggregateTarget: Sendable {
    public let definition: ResolvedTarget
    public let platform: Platform
    /// Pod targets linked into the user target, dependencies first.
    public let podTargetNames: [String]
    /// Pod targets visible only through search paths (`inherit! :search_paths`).
    public let searchPathPodTargetNames: [String]
    /// The user project (`nil` when targets aren't integrated) and the names of its build configurations.
    public let userProject: URL?
    /// The directory build settings are relative to: the user project's, or the Podfile's.
    public let clientRoot: URL
    public let buildConfigurations: [String]
    public let buildType: BuildType
    /// SwiftPM products linked into the user target: those of the linked pod targets and those the Podfile names.
    public let packageProducts: [PackageProductRef]

    public var label: String { definition.label }
    public var productName: String { buildType.isFramework ? Specification.c99Identifier(label) : label }
    public var productFileName: String {
        buildType.isFramework ? "\(productName).framework" : "lib\(productName).a"
    }
}

/// Everything needed to generate the Pods project and integrate the user project.
public struct InstallationPlan: Sendable {
    public let podfile: Podfile
    public let podfileURL: URL
    public let pods: [InstalledPod]
    public let podTargets: [PodTarget]
    public let aggregateTargets: [AggregateTarget]
    /// Package references of `Pods.xcodeproj`: the declared and the unified packages, with the ranges of the final resolution.
    public let swiftPackages: [(url: String, lowerBound: Version, upperBound: Version)]

    public func podTarget(named name: String) -> PodTarget? { podTargets.first { $0.name == name } }
}
