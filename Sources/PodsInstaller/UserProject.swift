import Foundation
import PathKit
import PodsCore
import XcodeProj

/// Sendable summary of a user `.xcodeproj`, read once during analysis.
struct UserProjectInfo: Sendable {
    struct Target: Sendable {
        let name: String
        let platform: Platform?
        let productType: String?
    }

    let url: URL
    let configurations: [String]
    let targets: [Target]

    init(url: URL) throws {
        let project = try XcodeProj(path: Path(url.path))
        self.url = url
        let root = project.pbxproj.rootObject
        configurations = root?.buildConfigurationList?.buildConfigurations.map(\.name) ?? ["Debug", "Release"]
        let projectSettings = root?.buildConfigurationList?.buildConfigurations.first?.buildSettings ?? [:]
        targets = project.pbxproj.nativeTargets.map { target in
            let settings = target.buildConfigurationList?.buildConfigurations.first?.buildSettings ?? [:]
            func value(_ key: String) -> String? {
                settings[key]?.stringValue ?? projectSettings[key]?.stringValue
            }
            var platform: Platform?
            let sdk = value("SDKROOT")
            let supported = value("SUPPORTED_PLATFORMS") ?? ""
            for name in Platform.Name.allCases {
                if sdk == name.sdkRoot || (sdk == "auto" && supported.split(separator: " ").first.map(String.init) == name.sdkRoot) {
                    platform = Platform(name, value(name.deploymentTargetSetting).flatMap(Version.init))
                }
            }
            return Target(name: target.name, platform: platform, productType: target.productType?.rawValue)
        }
    }

    /// The single project in `directory`, if there is exactly one.
    static func findProject(in directory: URL) throws -> URL {
        let projects = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".xcodeproj") && $0 != "Pods.xcodeproj" }
            .sorted()
        guard projects.count == 1 else {
            if projects.isEmpty { throw PodsError("No `.xcodeproj` found in \(directory.path). Specify one with `project`.") }
            throw PodsError("Multiple projects found (\(projects.joined(separator: ", "))). Specify one with `project`.")
        }
        return directory.appendingPathComponent(projects[0])
    }
}
