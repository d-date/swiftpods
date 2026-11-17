import Foundation
import PodsCore

/// The Info.plist of a prebuilt framework that ships without one. A SwiftPM consumer crashes at
/// launch ("The bundle doesn't contain…") when an embedded framework has no Info.plist.
enum FrameworkInfoPlist {
    /// - Parameter platformName: the bundle platform, e.g. `iPhoneOS` or `iPhoneSimulator`.
    static func make(module: String, podVersion: Version, platformName: String, minimumOS: String) -> Data {
        let info: [String: Any] = [
            "CFBundleExecutable": module,
            "CFBundleName": module,
            "CFBundleIdentifier": "org.cocoapods.\(module)",
            "CFBundlePackageType": "FMWK",
            // CFBundleShortVersionString only allows numbers, so pre-release identifiers are dropped.
            "CFBundleShortVersionString": podVersion.release.map(String.init).joined(separator: "."),
            "CFBundleVersion": "1",
            "CFBundleSupportedPlatforms": [platformName],
            "MinimumOSVersion": minimumOS,
        ]
        // Serializing a dictionary of strings and string arrays cannot fail.
        return try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    }
}
