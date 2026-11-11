public import Foundation
import PodsCore
import PodsPodfile

/// Creates a starter Podfile (`swiftpods init`) listing the targets of the project.
public enum PodfileTemplate {
    public static func create(in directory: URL, swift: Bool) throws -> URL {
        let fileName = swift ? "Podfile.swift" : "Podfile"
        let url = directory.appendingPathComponent(fileName)
        if let existing = PodfileLoader.podfileURL(in: directory) {
            throw PodsError("Existing `\(existing.lastPathComponent)` found in the directory.")
        }
        let project = try UserProjectInfo(url: UserProjectInfo.findProject(in: directory))
        let contents = swift ? swiftPodfile(project) : rubyPodfile(project)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func isTest(_ target: UserProjectInfo.Target) -> Bool {
        target.productType?.contains("unit-test") == true || target.productType?.contains("ui-testing") == true
    }

    /// The first non-test target of each platform hosts the test targets.
    private static func layout(_ project: UserProjectInfo) -> [(target: UserProjectInfo.Target, tests: [UserProjectInfo.Target])] {
        let hosts = project.targets.filter { !isTest($0) }
        let tests = project.targets.filter(isTest)
        return hosts.enumerated().map { index, host in
            (host, index == 0 ? tests : [])
        }
    }

    static func rubyPodfile(_ project: UserProjectInfo) -> String {
        var lines = ["# Uncomment the next line to define a global platform for your project", "# platform :ios, '15.0'", ""]
        for (host, tests) in layout(project) {
            lines.append("target '\(host.name)' do")
            lines.append("  # Comment the next line if you don't want to use dynamic frameworks")
            lines.append("  use_frameworks!")
            lines.append("")
            lines.append("  # Pods for \(host.name)")
            lines.append("")
            for test in tests {
                lines.append("  target '\(test.name)' do")
                lines.append("    inherit! :search_paths")
                lines.append("    # Pods for testing")
                lines.append("  end")
                lines.append("")
            }
            lines.append("end")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func swiftPodfile(_ project: UserProjectInfo) -> String {
        var targets: [String] = []
        for (host, tests) in layout(project) {
            var target = """
                    .target(
                        name: "\(host.name)",
                        dependencies: [
                            // .pod(name: "Alamofire", from: "5.9.0"),
                        ]
            """
            if !tests.isEmpty {
                target += ",\n            targets: [\n"
                target += tests.map { "                .target(name: \"\($0.name)\", inherit: .searchPaths)," }.joined(separator: "\n")
                target += "\n            ]"
            }
            target += "\n        ),"
            targets.append(target)
        }
        return """
        import SwiftPodsDescription

        let podfile = Podfile(
            // platform: .iOS(.v15),
            useFrameworks: .dynamic,
            targets: [
        \(targets.joined(separator: "\n"))
            ]
        )

        """
    }
}
