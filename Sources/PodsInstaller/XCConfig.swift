import Foundation
import PodsCore
import PodsPodfile
import PodsSpec

/// Build settings serialised as an `.xcconfig` file.
///
/// List settings are stored as *atoms* — whole flags such as `-D COCOAPODS` or
/// `-framework "UIKit"` — so de-duplication never splits a flag from its argument.
struct XCConfig: Sendable, Equatable {
    private var scalars: [String: String] = [:]
    private var lists: [String: [String]] = [:]

    subscript(key: String) -> String? {
        if let list = lists[key] { return (["$(inherited)"] + list).joined(separator: " ") }
        return scalars[key]
    }

    mutating func set(_ key: String, _ value: String) {
        lists[key] = nil
        scalars[key] = value
    }

    /// Appends atoms to a list setting (rendered after `$(inherited)`), skipping duplicates.
    mutating func append(_ key: String, _ atoms: [String]) {
        guard !atoms.isEmpty else { return }
        var list = lists[key] ?? scalars[key].map { [$0] } ?? []
        scalars[key] = nil
        for atom in atoms where atom != "$(inherited)" && !list.contains(atom) { list.append(atom) }
        lists[key] = list
    }

    /// Merges settings from a podspec (`pod_target_xcconfig` / `user_target_xcconfig`).
    mutating func merge(_ pairs: [(key: String, value: String)]) {
        for pair in pairs {
            let value = pair.value.replacingOccurrences(of: "$(inherited)", with: "").trimmingWhitespace()
            if lists[pair.key] != nil || pair.value.contains("$(inherited)") || Self.listSettings.contains(pair.key) {
                if !value.isEmpty { append(pair.key, [value]) }
            } else {
                set(pair.key, pair.value)
            }
        }
    }

    /// Settings whose values are lists.
    static let listSettings: Set<String> = [
        "FRAMEWORK_SEARCH_PATHS", "GCC_PREPROCESSOR_DEFINITIONS", "HEADER_SEARCH_PATHS", "LD_RUNPATH_SEARCH_PATHS",
        "LIBRARY_SEARCH_PATHS", "OTHER_CFLAGS", "OTHER_CPLUSPLUSFLAGS", "OTHER_LDFLAGS", "OTHER_SWIFT_FLAGS",
        "SWIFT_INCLUDE_PATHS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "WARNING_CFLAGS", "SYSTEM_HEADER_SEARCH_PATHS",
        "USER_HEADER_SEARCH_PATHS",
    ]

    static func quoted(_ path: String) -> String { "\"\(path)\"" }

    var contents: String {
        let keys = Set(scalars.keys).union(lists.keys).sorted()
        return keys.map { "\($0) = \(self[$0]!)" }.joined(separator: "\n") + "\n"
    }
}

/// Builds the xcconfig files for pod targets and aggregate targets.
struct XCConfigBuilder {
    let plan: InstallationPlan
    let sandbox: Sandbox

    static let configurationBuildDir = "${PODS_CONFIGURATION_BUILD_DIR}"

    /// `${PODS_ROOT}/Alamofire` or, for local pods, a path relative to `${PODS_ROOT}`.
    func podRootSetting(_ pod: InstalledPod) -> String {
        let relative = Sandbox.relativePath(from: sandbox.root, to: pod.location)
        return relative == "." ? "${PODS_ROOT}" : "${PODS_ROOT}/" + relative
    }

    /// The sandbox directory of a pod's headers: `Headers/Public/<pod name>`.
    func headerDirectory(_ target: PodTarget) -> String {
        target.podName
    }

    /// `header_dir` normalised (`./` and empty mean none); headers live in `<pod>/<header_dir>/`.
    static func headerSubdirectory(_ target: PodTarget) -> String {
        let trimmed = (target.files.headerDir ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "./"))
        return trimmed
    }

    private func linkerFlags(frameworks: [String], weakFrameworks: [String], libraries: [String]) -> [String] {
        frameworks.map { "-framework \(XCConfig.quoted($0))" }
            + weakFrameworks.map { "-weak_framework \(XCConfig.quoted($0))" }
            + libraries.map { "-l\(XCConfig.quoted($0))" }
    }

    /// The quoted directory containing `path` inside the pod.
    private func containingDirectory(_ path: String, of target: PodTarget) -> String {
        let root = podRootSetting(target.pod)
        let directory = path.deletingLastPathComponent
        return XCConfig.quoted(directory.isEmpty ? root : root + "/" + directory)
    }

    private func vendoredFrameworkDirectories(_ target: PodTarget) -> [String] {
        var directories = target.files.plainFrameworks.map { containingDirectory($0, of: target) }
        // xcframework slices are copied here by the `[CP] Copy XCFrameworks` phase.
        if target.files.xcframeworks.contains(where: \.isFramework) {
            directories.append(XCConfig.quoted(xcframeworksDirectory(target)))
        }
        return directories
    }

    /// Where the matching slices of a pod's xcframeworks are copied.
    func xcframeworksDirectory(_ target: PodTarget) -> String {
        "${PODS_XCFRAMEWORKS_BUILD_DIR}/\(target.name)"
    }

    private func vendoredLibraryDirectories(_ target: PodTarget) -> [String] {
        var directories = target.files.vendoredLibraries.map { containingDirectory($0, of: target) }
        if target.files.xcframeworks.contains(where: { !$0.isFramework }) {
            directories.append(XCConfig.quoted(xcframeworksDirectory(target)))
        }
        return directories
    }

    /// Header directories of library xcframeworks (frameworks carry their own headers).
    private func xcframeworkHeaderDirectories(_ target: PodTarget) -> [String] {
        target.files.xcframeworks.contains { !$0.isFramework && $0.hasHeaders }
            ? [XCConfig.quoted(xcframeworksDirectory(target) + "/Headers")] : []
    }

    private func vendoredLibraryNames(_ target: PodTarget) -> [String] {
        target.files.vendoredLibraries.map {
            var name = $0.lastPathComponent.deletingPathExtension
            if name.hasPrefix("lib") { name.removeFirst(3) }
            return name
        } + target.files.xcframeworks.filter { !$0.isFramework }.map(\.linkName)
    }

    private func vendoredFrameworkNames(_ target: PodTarget) -> [String] {
        target.files.plainFrameworks.map { $0.lastPathComponent.deletingPathExtension }
            + target.files.xcframeworks.filter(\.isFramework).map(\.linkName)
    }

    /// The module map exposing a static library pod's ObjC headers to Swift, if it has headers.
    func moduleMapPath(_ target: PodTarget) -> String? {
        guard !target.buildType.isFramework, !target.files.isModuleMapDisabled else { return nil }
        // Swift static libraries get a module map (with the `-Swift.h` header) written next to
        // their product by the `[CP] Copy generated compatibility header` phase.
        if target.usesSwift, target.shouldBuild {
            return "${PODS_CONFIGURATION_BUILD_DIR}/\(target.name)/\(target.moduleName).modulemap"
        }
        guard target.files.hasObjCHeaders else { return nil }
        if let custom = target.files.staticLibraryModuleMap { return podRootSetting(target.pod) + "/" + custom }
        return "${PODS_ROOT}/Headers/Public/\(headerDirectory(target))/\(target.moduleName).modulemap"
    }

    /// The module map of the Objective-C headers of a static library (generated or provided).
    func objcModuleMapPath(_ target: PodTarget) -> String? {
        guard target.files.hasObjCHeaders, !target.files.isModuleMapDisabled else { return nil }
        if let custom = target.files.staticLibraryModuleMap { return podRootSetting(target.pod) + "/" + custom }
        return "${PODS_ROOT}/Headers/Public/\(headerDirectory(target))/\(target.moduleName).modulemap"
    }

    /// All pod targets reachable from `names`, including transitive dependencies.
    func transitiveTargets(_ names: [String]) -> [PodTarget] {
        var result: [PodTarget] = []
        var seen = Set<String>()
        func visit(_ name: String) {
            guard seen.insert(name).inserted, let target = plan.podTarget(named: name) else { return }
            target.dependencyNames.forEach(visit)
            result.append(target)
        }
        names.forEach(visit)
        return result
    }

    // MARK: - Pod targets

    func podTargetConfig(_ target: PodTarget, configuration: String) -> XCConfig {
        var config = XCConfig()
        config.set("CONFIGURATION_BUILD_DIR", "${PODS_CONFIGURATION_BUILD_DIR}/\(target.name)")
        config.append("GCC_PREPROCESSOR_DEFINITIONS", ["COCOAPODS=1"])
        config.append("OTHER_SWIFT_FLAGS", ["-D COCOAPODS"])
        config.set("PODS_BUILD_DIR", "${BUILD_DIR}")
        config.set("PODS_CONFIGURATION_BUILD_DIR", "${PODS_BUILD_DIR}/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)")
        config.set("PODS_ROOT", "${SRCROOT}")
        config.set("PODS_TARGET_SRCROOT", podRootSetting(target.pod))
        config.set("PODS_XCFRAMEWORKS_BUILD_DIR", "$(PODS_CONFIGURATION_BUILD_DIR)/XCFrameworkIntermediates")
        config.set("PODS_DEVELOPMENT_LANGUAGE", "${DEVELOPMENT_LANGUAGE}")
        config.set("PRODUCT_BUNDLE_IDENTIFIER", "org.cocoapods.${PRODUCT_NAME:rfc1034identifier}")
        config.set("SKIP_INSTALL", "YES")
        config.set("USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES", "YES")

        let dependencies = transitiveTargets(target.dependencyNames)
        if !target.buildType.isFramework {
            var headerPaths = [
                XCConfig.quoted("${PODS_ROOT}/Headers/Private"),
                XCConfig.quoted("${PODS_ROOT}/Headers/Private/\(headerDirectory(target))"),
                XCConfig.quoted("${PODS_ROOT}/Headers/Public"),
            ]
            headerPaths += ([target] + dependencies).map { XCConfig.quoted("${PODS_ROOT}/Headers/Public/\(headerDirectory($0))") }
            config.append("HEADER_SEARCH_PATHS", headerPaths)
        }
        for dependency in dependencies {
            if dependency.buildType.isFramework, dependency.shouldBuild {
                config.append("FRAMEWORK_SEARCH_PATHS", [XCConfig.quoted("${PODS_CONFIGURATION_BUILD_DIR}/\(dependency.name)")])
            } else if dependency.shouldBuild, dependency.usesSwift {
                config.append("SWIFT_INCLUDE_PATHS", [XCConfig.quoted("${PODS_CONFIGURATION_BUILD_DIR}/\(dependency.name)")])
            }
            if let moduleMap = moduleMapPath(dependency) {
                config.append("OTHER_CFLAGS", ["-fmodule-map-file=\(XCConfig.quoted(moduleMap))"])
                config.append("OTHER_SWIFT_FLAGS", ["-Xcc -fmodule-map-file=\(XCConfig.quoted(moduleMap))"])
            }
            config.append("FRAMEWORK_SEARCH_PATHS", vendoredFrameworkDirectories(dependency))
            config.append("HEADER_SEARCH_PATHS", xcframeworkHeaderDirectories(dependency))
        }
        config.append("FRAMEWORK_SEARCH_PATHS", vendoredFrameworkDirectories(target))
        config.append("LIBRARY_SEARCH_PATHS", vendoredLibraryDirectories(target))
        config.append("HEADER_SEARCH_PATHS", xcframeworkHeaderDirectories(target))
        // Mixed Swift/Objective-C static libraries import their own Objective-C half.
        if !target.buildType.isFramework, target.usesSwift, target.files.hasObjCHeaders, let objcModuleMap = objcModuleMapPath(target) {
            config.append("OTHER_SWIFT_FLAGS", ["-import-underlying-module", "-Xcc -fmodule-map-file=\(XCConfig.quoted(objcModuleMap))"])
        }

        // Dynamic frameworks are linked when built, so they need their link flags.
        if target.buildType == .dynamicFramework {
            var flags: [String] = []
            for consumer in target.consumers {
                flags += linkerFlags(frameworks: consumer.frameworks, weakFrameworks: consumer.weakFrameworks, libraries: consumer.libraries)
            }
            flags += vendoredFrameworkNames(target).map { "-framework \(XCConfig.quoted($0))" }
            flags += vendoredLibraryNames(target).map { "-l\(XCConfig.quoted($0))" }
            for dependency in dependencies {
                if dependency.shouldBuild { flags.append("-framework \(XCConfig.quoted(dependency.productName))") }
                flags += vendoredFrameworkNames(dependency).map { "-framework \(XCConfig.quoted($0))" }
            }
            config.append("OTHER_LDFLAGS", flags)
        }
        if target.inhibitWarnings {
            config.set("GCC_WARN_INHIBIT_ALL_WARNINGS", "YES")
            config.append("OTHER_SWIFT_FLAGS", ["-suppress-warnings"])
        }
        for consumer in target.consumers {
            config.merge(consumer.podTargetXCConfig)
        }
        if configuration.lowercased().contains("debug") {
            config.append("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ["DEBUG"])
        }
        return config
    }

    // MARK: - Aggregate targets

    func aggregateConfig(_ aggregate: AggregateTarget, configuration: String, userProjectDirectory: URL) -> XCConfig {
        var config = XCConfig()
        let podsRoot = Sandbox.relativePath(from: userProjectDirectory, to: sandbox.root)
        let podfileDirectory = Sandbox.relativePath(from: userProjectDirectory, to: plan.podfileURL.deletingLastPathComponent())
        config.set("PODS_BUILD_DIR", "${BUILD_DIR}")
        config.set("PODS_CONFIGURATION_BUILD_DIR", "${PODS_BUILD_DIR}/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)")
        config.set("PODS_PODFILE_DIR_PATH", "${SRCROOT}/\(podfileDirectory)")
        config.set("PODS_ROOT", "${SRCROOT}/\(podsRoot)")
        config.set("PODS_XCFRAMEWORKS_BUILD_DIR", "$(PODS_CONFIGURATION_BUILD_DIR)/XCFrameworkIntermediates")
        config.set("USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES", "YES")
        // The [CP] scripts read and write files that aren't declared as inputs/outputs.
        config.set("ENABLE_USER_SCRIPT_SANDBOXING", "NO")
        config.append("GCC_PREPROCESSOR_DEFINITIONS", ["COCOAPODS=1"])
        config.append("OTHER_SWIFT_FLAGS", ["-D COCOAPODS"])

        let linked = transitiveTargets(aggregate.podTargetNames).filter { target in
            let configurations = aggregate.definition.dependencies.first { $0.dependency.rootName == target.podName }?.configurations ?? []
            return configurations.isEmpty || configurations.contains { $0.caseInsensitiveCompare(configuration) == .orderedSame }
        }
        let searchOnly = transitiveTargets(aggregate.searchPathPodTargetNames)
        var linkerFlags: [String] = []
        var usesSwift = false

        for (target, link) in linked.map({ ($0, true) }) + searchOnly.map({ ($0, false) }) {
            usesSwift = usesSwift || target.usesSwift
            if target.buildType.isFramework {
                if target.shouldBuild {
                    config.append("FRAMEWORK_SEARCH_PATHS", [XCConfig.quoted("${PODS_CONFIGURATION_BUILD_DIR}/\(target.name)")])
                    if link { linkerFlags.append("-framework \(XCConfig.quoted(target.productName))") }
                }
            } else {
                config.append("HEADER_SEARCH_PATHS", [
                    XCConfig.quoted("${PODS_ROOT}/Headers/Public"),
                    XCConfig.quoted("${PODS_ROOT}/Headers/Public/\(headerDirectory(target))"),
                ])
                if target.shouldBuild {
                    config.append("LIBRARY_SEARCH_PATHS", [XCConfig.quoted("${PODS_CONFIGURATION_BUILD_DIR}/\(target.name)")])
                    if target.usesSwift {
                        config.append("SWIFT_INCLUDE_PATHS", [XCConfig.quoted("${PODS_CONFIGURATION_BUILD_DIR}/\(target.name)")])
                    }
                    if link { linkerFlags.append("-l\(XCConfig.quoted(target.productName))") }
                }
                if let moduleMap = moduleMapPath(target) {
                    config.append("OTHER_CFLAGS", ["-fmodule-map-file=\(XCConfig.quoted(moduleMap))"])
                    config.append("OTHER_SWIFT_FLAGS", ["-Xcc -fmodule-map-file=\(XCConfig.quoted(moduleMap))"])
                }
            }
            config.append("FRAMEWORK_SEARCH_PATHS", vendoredFrameworkDirectories(target))
            config.append("LIBRARY_SEARCH_PATHS", vendoredLibraryDirectories(target))
            config.append("HEADER_SEARCH_PATHS", xcframeworkHeaderDirectories(target))
            guard link else { continue }
            // Static products don't carry their link dependencies, so the app links them.
            if target.buildType != .dynamicFramework {
                for consumer in target.consumers {
                    linkerFlags += self.linkerFlags(frameworks: consumer.frameworks, weakFrameworks: consumer.weakFrameworks, libraries: consumer.libraries)
                }
                linkerFlags += vendoredLibraryNames(target).map { "-l\(XCConfig.quoted($0))" }
            }
            linkerFlags += vendoredFrameworkNames(target).map { "-framework \(XCConfig.quoted($0))" }
            for consumer in target.consumers { config.merge(consumer.userTargetXCConfig) }
        }

        if aggregate.buildType == .staticLibrary, !linked.isEmpty {
            linkerFlags.insert("-ObjC", at: 0)
        }
        config.append("OTHER_LDFLAGS", linkerFlags)
        var runpaths = ["'@executable_path/Frameworks'", "'@loader_path/Frameworks'"]
        if usesSwift && aggregate.buildType == .staticLibrary {
            runpaths.insert("/usr/lib/swift", at: 0)
            config.append("LIBRARY_SEARCH_PATHS", [XCConfig.quoted("$(TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)"), "/usr/lib/swift"])
        }
        if aggregate.platform.name == .osx {
            runpaths = ["'@executable_path/../Frameworks'", "'@loader_path/Frameworks'"]
        }
        config.append("LD_RUNPATH_SEARCH_PATHS", runpaths)
        return config
    }
}
