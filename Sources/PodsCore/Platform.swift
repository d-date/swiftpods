/// An Apple platform and its deployment target.
public struct Platform: Sendable, Hashable, CustomStringConvertible {
    public enum Name: String, Sendable, Hashable, CaseIterable, Codable, Comparable {
        case ios
        case osx
        case tvos
        case watchos
        case visionos

        /// Accepts CocoaPods aliases such as `macos`.
        public init?(podfileName: String) {
            switch podfileName.lowercased() {
            case "macos", "osx": self = .osx
            default: self.init(rawValue: podfileName.lowercased())
            }
        }

        /// The value of the `SDKROOT` build setting.
        public var sdkRoot: String {
            switch self {
            case .ios: "iphoneos"
            case .osx: "macosx"
            case .tvos: "appletvos"
            case .watchos: "watchos"
            case .visionos: "xros"
            }
        }

        /// The build setting holding the deployment target.
        public var deploymentTargetSetting: String {
            switch self {
            case .ios: "IPHONEOS_DEPLOYMENT_TARGET"
            case .osx: "MACOSX_DEPLOYMENT_TARGET"
            case .tvos: "TVOS_DEPLOYMENT_TARGET"
            case .watchos: "WATCHOS_DEPLOYMENT_TARGET"
            case .visionos: "XROS_DEPLOYMENT_TARGET"
            }
        }

        /// Human readable name, used in messages.
        public var displayName: String {
            switch self {
            case .ios: "iOS"
            case .osx: "macOS"
            case .tvos: "tvOS"
            case .watchos: "watchOS"
            case .visionos: "visionOS"
            }
        }

        /// Directory suffix used for per-platform target names (e.g. `Alamofire-iOS`).
        public var targetSuffix: String { displayName }

        /// `SUPPORTED_PLATFORMS` build setting value.
        public var supportedPlatforms: String {
            switch self {
            case .ios: "iphoneos iphonesimulator"
            case .osx: "macosx"
            case .tvos: "appletvos appletvsimulator"
            case .watchos: "watchos watchsimulator"
            case .visionos: "xros xrsimulator"
            }
        }

        /// The `TARGETED_DEVICE_FAMILY` value, when applicable.
        public var targetedDeviceFamily: String? {
            switch self {
            case .ios: "1,2"
            case .tvos: "3"
            case .watchos: "4"
            case .visionos: "7"
            case .osx: nil
            }
        }

        public static func < (lhs: Name, rhs: Name) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let name: Name
    /// `nil` means "use the default deployment target".
    public let deploymentTarget: Version?

    public init(_ name: Name, _ deploymentTarget: Version? = nil) {
        self.name = name
        self.deploymentTarget = deploymentTarget
    }

    /// Deployment target used when neither the Podfile nor the user project specify one.
    public var defaultDeploymentTarget: Version {
        switch name {
        case .ios: Version(12, 0)
        case .osx: Version(10, 13)
        case .tvos: Version(12, 0)
        case .watchos: Version(4, 0)
        case .visionos: Version(1, 0)
        }
    }

    public var effectiveDeploymentTarget: Version { deploymentTarget ?? defaultDeploymentTarget }

    /// Whether a pod requiring `other` can be used on this platform.
    public func supports(_ other: Platform) -> Bool {
        guard name == other.name else { return false }
        guard let required = other.deploymentTarget else { return true }
        return effectiveDeploymentTarget >= required
    }

    public var description: String {
        if let deploymentTarget { "\(name.displayName) \(deploymentTarget)" } else { name.displayName }
    }
}
