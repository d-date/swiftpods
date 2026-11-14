import Foundation
import PathKit
import PodsCore
import PodsPodfile
import PodsSpec
import XcodeProj

/// Generates `Pods/Pods.xcodeproj` and the files in `Pods/Target Support Files`.
///
/// XcodeProj objects are not `Sendable`, so generation is one synchronous step whose
/// objects never leave this type.
struct PodsProjectGenerator {
    let plan: InstallationPlan
    let sandbox: Sandbox
    /// Build configuration name → `true` if it is a debug configuration.
    let configurations: [(name: String, isDebug: Bool)]

    init(plan: InstallationPlan, sandbox: Sandbox) {
        self.plan = plan
        self.sandbox = sandbox
        var mapping: [String: String] = [:]
        for target in plan.podfile.resolvedTargets { mapping.merge(target.buildConfigurations) { a, _ in a } }
        var names: [String] = []
        for aggregate in plan.aggregateTargets {
            for name in aggregate.buildConfigurations where !names.contains(name) { names.append(name) }
        }
        if names.isEmpty { names = ["Debug", "Release"] }
        self.configurations = names.map { name in
            (name, mapping[name].map { $0 == "debug" } ?? name.lowercased().contains("debug"))
        }
    }

    // MARK: - Entry point

    func generate() throws {
        let builder = ProjectBuilder(configurations: configurations, sandbox: sandbox)
        let xcconfigs = XCConfigBuilder(plan: plan, sandbox: sandbox)
        builder.addPodfileReference(plan.podfileURL)
        for package in plan.swiftPackages {
            try builder.addPackageReference(url: package.url, from: SwiftPackageResolver.semanticVersion(package.lowerBound, url: package.url),
                                            to: SwiftPackageResolver.semanticVersion(package.upperBound, url: package.url))
        }

        var nativeTargets: [String: PBXTarget] = [:]
        var bundleTargets: [String: [PBXNativeTarget]] = [:]
        for target in plan.podTargets {
            // xcconfigs first: targets look up their base configuration references.
            try writeXCConfigs(for: target, builder: builder, xcconfigs: xcconfigs)
            let bundles = try makeResourceBundleTargets(for: target, builder: builder, xcconfigs: xcconfigs)
            bundleTargets[target.name] = bundles
            if target.shouldBuild {
                let native = try makePodTarget(target, builder: builder, xcconfigs: xcconfigs, bundles: bundles)
                try addCopyXCFrameworksPhase(for: target, to: native, builder: builder, xcconfigs: xcconfigs)
                nativeTargets[target.name] = native
            } else {
                // Still reference the files so they show up in the navigator.
                _ = builder.podGroup(for: target.pod, files: target.files.allFiles)
                if !target.files.xcframeworks.isEmpty {
                    // Binary-only pods get an aggregate target that copies their xcframework slices.
                    let aggregate = builder.aggregateTarget(
                        name: target.name, settings: platformSettings(target.platform),
                        xcconfigPrefix: "Target Support Files/\(target.name)/\(target.name)"
                    )
                    try addCopyXCFrameworksPhase(for: target, to: aggregate, builder: builder, xcconfigs: xcconfigs)
                    for bundle in bundles { builder.addDependency(aggregate, on: bundle) }
                    nativeTargets[target.name] = aggregate
                }
            }
            try linkHeaders(for: target, xcconfigs: xcconfigs)
        }
        for target in plan.podTargets {
            guard let native = nativeTargets[target.name] else { continue }
            for dependency in target.dependencyNames {
                if let dependencyTarget = nativeTargets[dependency] { builder.addDependency(native, on: dependencyTarget) }
            }
        }
        for aggregate in plan.aggregateTargets {
            try makeAggregateTarget(aggregate, builder: builder, xcconfigs: xcconfigs, podTargets: nativeTargets, bundleTargets: bundleTargets)
        }
        try builder.write(to: sandbox.projectURL)
    }

    // MARK: - Pod targets

    private func addCopyXCFrameworksPhase(for target: PodTarget, to native: PBXTarget, builder: ProjectBuilder, xcconfigs: XCConfigBuilder) throws {
        guard !target.files.xcframeworks.isEmpty else { return }
        let scriptName = "\(target.name)-xcframeworks.sh"
        let entries = target.files.xcframeworks.map {
            (path: "\(xcconfigs.podRootSetting(target.pod))/\($0.path)", destination: xcconfigs.xcframeworksDirectory(target))
        }
        let script = supportFile(target.name, scriptName)
        try write(SupportFiles.copyXCFrameworksScript(entries), to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        builder.supportFileReference(script)
        let phase = PBXShellScriptBuildPhase(
            name: "[CP] Copy XCFrameworks",
            inputPaths: ["${PODS_ROOT}/Target Support Files/\(target.name)/\(scriptName)"] + entries.map(\.path),
            outputPaths: target.files.xcframeworks.map { "\(xcconfigs.xcframeworksDirectory(target))/\($0.libraryPath)" },
            shellScript: "\"${PODS_ROOT}/Target Support Files/\(target.name)/\(scriptName)\"\n",
            showEnvVarsInLog: false
        )
        builder.addPhase(phase, to: native, atStart: true)
    }

    private func supportFile(_ target: String, _ name: String) -> URL {
        sandbox.supportFilesDirectory(target).appendingPathComponent(name)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Settings shared by every target for a platform.
    private func platformSettings(_ platform: Platform) -> BuildSettings {
        var settings: BuildSettings = [
            "SDKROOT": .string(platform.name.sdkRoot),
            platform.name.deploymentTargetSetting: .string(platform.effectiveDeploymentTarget.rawValue),
        ]
        if let family = platform.name.targetedDeviceFamily { settings["TARGETED_DEVICE_FAMILY"] = .string(family) }
        return settings
    }

    private func writeXCConfigs(for target: PodTarget, builder: ProjectBuilder, xcconfigs: XCConfigBuilder) throws {
        for configuration in configurations {
            let config = xcconfigs.podTargetConfig(target, configuration: configuration.name)
            let file = supportFile(target.name, "\(target.name).\(configuration.name.lowercased()).xcconfig")
            try write(config.contents, to: file)
            builder.supportFileReference(file)
        }
    }

    private func makePodTarget(_ target: PodTarget, builder: ProjectBuilder, xcconfigs: XCConfigBuilder, bundles: [PBXNativeTarget]) throws -> PBXNativeTarget {
        let files = target.files
        let group = builder.podGroup(for: target.pod, files: files.allFiles)

        // Support files.
        let dummy = supportFile(target.name, "\(target.name)-dummy.m")
        try write(SupportFiles.dummySource(name: target.name), to: dummy)
        let prefix = supportFile(target.name, "\(target.name)-prefix.pch")
        let consumers = target.consumers
        try write(SupportFiles.prefixHeader(
            platform: target.platform.name,
            contents: consumers.compactMap(\.prefixHeaderContents).first,
            prefixFile: files.prefixHeader.map { "\(target.pod.location.path)/\($0)" }
        ), to: prefix)
        builder.supportFileReference(dummy)
        builder.supportFileReference(prefix)

        var settings = platformSettings(target.platform)
        settings["PRODUCT_MODULE_NAME"] = .string(target.moduleName)
        if !consumers.contains(where: \.isPrefixHeaderDisabled) {
            settings["GCC_PREFIX_HEADER"] = .string("Target Support Files/\(target.name)/\(target.name)-prefix.pch")
        }
        settings["SKIP_INSTALL"] = "YES"
        if let swiftVersion = target.swiftVersion { settings["SWIFT_VERSION"] = .string(swiftVersion) }

        let umbrellaName = "\(target.name)-umbrella.h"
        let needsModuleMap = target.buildType.isFramework || files.hasObjCHeaders
        if needsModuleMap {
            let umbrellaHeaders = files.publicHeaders.map { $0.lastPathComponent }
            let umbrella = supportFile(target.name, umbrellaName)
            try write(SupportFiles.umbrellaHeader(moduleName: target.moduleName, headers: umbrellaHeaders, platform: target.platform.name), to: umbrella)
            builder.supportFileReference(umbrella)
            if files.moduleMap == nil {
                let moduleMap = supportFile(target.name, "\(target.name).modulemap")
                try write(SupportFiles.moduleMap(moduleName: target.moduleName, umbrellaHeader: umbrellaName, framework: target.buildType.isFramework), to: moduleMap)
                builder.supportFileReference(moduleMap)
            }
        }

        if target.buildType.isFramework {
            let info = supportFile(target.name, "\(target.name)-Info.plist")
            try write(SupportFiles.infoPlist(version: target.rootSpec.version), to: info)
            builder.supportFileReference(info)
            settings["PRODUCT_NAME"] = .string(target.productName)
            settings["DEFINES_MODULE"] = "YES"
            settings["INFOPLIST_FILE"] = .string("Target Support Files/\(target.name)/\(target.name)-Info.plist")
            if let custom = files.moduleMap {
                settings["MODULEMAP_FILE"] = .string(xcconfigs.podRootSetting(target.pod) + "/" + custom)
            } else {
                settings["MODULEMAP_FILE"] = .string("Target Support Files/\(target.name)/\(target.name).modulemap")
            }
            settings["CURRENT_PROJECT_VERSION"] = "1"
            settings["VERSIONING_SYSTEM"] = "apple-generic"
            settings["VERSION_INFO_PREFIX"] = ""
            settings["DYLIB_COMPATIBILITY_VERSION"] = "1"
            settings["DYLIB_CURRENT_VERSION"] = "1"
            settings["DYLIB_INSTALL_NAME_BASE"] = "@rpath"
            settings["INSTALL_PATH"] = "$(LOCAL_LIBRARY_DIR)/Frameworks"
            settings["LD_RUNPATH_SEARCH_PATHS"] = .array(["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"])
            settings["CODE_SIGN_IDENTITY"] = ""
            settings["CODE_SIGNING_REQUIRED"] = "NO"
            settings["CODE_SIGNING_ALLOWED"] = "NO"
            if target.buildType == .staticFramework { settings["MACH_O_TYPE"] = "staticlib" }
        } else {
            settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
            settings["OTHER_LDFLAGS"] = ""
            settings["OTHER_LIBTOOLFLAGS"] = ""
            settings["PUBLIC_HEADERS_FOLDER_PATH"] = ""
            settings["PRIVATE_HEADERS_FOLDER_PATH"] = ""
        }

        let native = builder.nativeTarget(
            name: target.name, productName: target.productName, productFileName: target.productFileName,
            productType: target.buildType.isFramework ? .framework : .staticLibrary,
            settings: settings, xcconfigPrefix: "Target Support Files/\(target.name)/\(target.name)"
        )

        // Headers.
        if target.buildType.isFramework {
            var headerFiles: [PBXBuildFile] = []
            for header in files.publicHeaders { headerFiles.append(builder.buildFile(group.reference(header), attributes: ["Public"])) }
            for header in files.privateHeaders { headerFiles.append(builder.buildFile(group.reference(header), attributes: ["Private"])) }
            for header in files.projectHeaders { headerFiles.append(builder.buildFile(group.reference(header), attributes: ["Project"])) }
            if needsModuleMap, let umbrella = builder.supportFileReferences[supportFile(target.name, umbrellaName).path] {
                headerFiles.append(builder.buildFile(umbrella, attributes: ["Public"]))
            }
            builder.addPhase(PBXHeadersBuildPhase(files: headerFiles), to: native)
        } else if !files.headers.isEmpty {
            builder.addPhase(PBXHeadersBuildPhase(files: files.headers.map { builder.buildFile(group.reference($0), attributes: ["Project"]) }), to: native)
        }

        // Sources, with per-file compiler flags.
        let compilerFlags = consumers.flatMap(\.compilerFlags)
        let requiresARC = consumers.allSatisfy(\.requiresARC)
        var sourceFiles = files.compiledSources.map { path -> PBXBuildFile in
            var flags = compilerFlags
            let ext = path.pathExtension
            if !requiresARC, ext == "m" || ext == "mm" { flags.append("-fno-objc-arc") }
            let inhibit = target.inhibitWarnings && ext != "swift" ? ["-w", "-Xanalyzer", "-analyzer-disable-all-checks"] : []
            flags += inhibit
            return builder.buildFile(group.reference(path), compilerFlags: flags.isEmpty || ext == "swift" ? nil : flags.joined(separator: " "))
        }
        if let dummyReference = builder.supportFileReferences[dummy.path] {
            sourceFiles.append(builder.buildFile(dummyReference))
        }
        builder.addPhase(PBXSourcesBuildPhase(files: sourceFiles), to: native)
        builder.addPhase(PBXFrameworksBuildPhase(), to: native)
        // For headers and modules only: the aggregate target links the products.
        if !target.packageProducts.isEmpty {
            native.packageProductDependencies = try target.packageProducts.map(builder.productDependency)
        }

        // Swift static libraries expose a module map (with `-Swift.h`) so Objective-C dependents can `@import` them.
        if !target.buildType.isFramework, target.usesSwift, !files.isModuleMapDisabled {
            let umbrella = files.hasObjCHeaders && files.staticLibraryModuleMap == nil
                ? "${PODS_ROOT}/Headers/Public/\(xcconfigs.headerDirectory(target))/\(target.name)-umbrella.h" : nil
            let phase = PBXShellScriptBuildPhase(
                name: "[CP] Copy generated compatibility header",
                inputPaths: ["${DERIVED_SOURCES_DIR}/${PRODUCT_MODULE_NAME}-Swift.h"],
                outputPaths: [
                    "${BUILT_PRODUCTS_DIR}/${PRODUCT_MODULE_NAME}.modulemap",
                    "${BUILT_PRODUCTS_DIR}/Swift Compatibility Header/${PRODUCT_MODULE_NAME}-Swift.h",
                ],
                shellScript: SupportFiles.copyCompatibilityHeaderScript(umbrellaHeader: umbrella),
                showEnvVarsInLog: false
            )
            builder.addPhase(phase, to: native)
        }

        // Resources go into frameworks; static libraries rely on the aggregate's copy script.
        if target.buildType.isFramework {
            var resources = files.resources.map { builder.buildFile(group.reference($0)) }
            for bundle in bundles {
                if let product = bundle.product { resources.append(builder.buildFile(product)) }
            }
            builder.addPhase(PBXResourcesBuildPhase(files: resources), to: native)
        }
        for bundle in bundles { builder.addDependency(native, on: bundle) }

        // Script phases declared by the spec.
        for phase in consumers.flatMap(\.scriptPhases) {
            let scriptPhase = PBXShellScriptBuildPhase(
                name: "[CP-User] \(phase.name)", inputPaths: phase.inputFiles, outputPaths: phase.outputFiles,
                shellPath: phase.shellPath, shellScript: phase.script, alwaysOutOfDate: phase.alwaysOutOfDate
            )
            builder.addPhase(scriptPhase, to: native, atStart: phase.position == .beforeCompile || phase.position == .beforeHeaders)
        }
        return native
    }

    private func makeResourceBundleTargets(for target: PodTarget, builder: ProjectBuilder, xcconfigs: XCConfigBuilder) throws -> [PBXNativeTarget] {
        guard !target.files.resourceBundles.isEmpty else { return [] }
        let group = builder.podGroup(for: target.pod, files: target.files.allFiles)
        var result: [PBXNativeTarget] = []
        for bundle in target.files.resourceBundles {
            let name = "\(target.name)-\(bundle.name)"
            let infoName = "ResourceBundle-\(bundle.name)-\(target.name)-Info.plist"
            let info = supportFile(target.name, infoName)
            try write(SupportFiles.infoPlist(version: target.rootSpec.version, packageType: "BNDL"), to: info)
            builder.supportFileReference(info)
            var settings = platformSettings(target.platform)
            settings["PRODUCT_NAME"] = .string(bundle.name)
            settings["WRAPPER_EXTENSION"] = "bundle"
            settings["INFOPLIST_FILE"] = .string("Target Support Files/\(target.name)/\(infoName)")
            settings["SKIP_INSTALL"] = "YES"
            settings["CODE_SIGNING_ALLOWED"] = "NO"
            settings["CODE_SIGN_IDENTITY"] = ""
            settings["CONFIGURATION_BUILD_DIR"] = .string("$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/\(target.name)")
            if target.platform.name == .osx { settings["INFOPLIST_KEY_CFBundleExecutable"] = "" }
            let native = builder.nativeTarget(
                name: name, productName: bundle.name, productFileName: "\(bundle.name).bundle",
                productType: .bundle, settings: settings, xcconfigPrefix: "Target Support Files/\(target.name)/\(target.name)"
            )
            builder.addPhase(PBXSourcesBuildPhase(), to: native)
            builder.addPhase(PBXFrameworksBuildPhase(), to: native)
            builder.addPhase(PBXResourcesBuildPhase(files: bundle.files.map { builder.buildFile(group.reference($0)) }), to: native)
            result.append(native)
        }
        return result
    }

    private func linkHeaders(for target: PodTarget, xcconfigs: XCConfigBuilder) throws {
        guard !target.buildType.isFramework else { return }
        let files = target.files
        let podDirectory = xcconfigs.headerDirectory(target)
        let subdirectory = XCConfigBuilder.headerSubdirectory(target)
        let directory = subdirectory.isEmpty ? podDirectory : podDirectory + "/" + subdirectory
        try sandbox.linkHeaders(files.publicHeaders, podRoot: target.pod.location, directory: directory, mappingsDir: files.headerMappingsDir, isPublic: true)
        try sandbox.linkHeaders(files.headers, podRoot: target.pod.location, directory: directory, mappingsDir: files.headerMappingsDir, isPublic: false)
        // Module map + umbrella header so Swift code can `import` ObjC static libraries,
        // unless the pod brings its own module map.
        if files.hasObjCHeaders, files.staticLibraryModuleMap == nil, !files.isModuleMapDisabled {
            let base = sandbox.publicHeadersURL.appendingPathComponent(podDirectory)
            let umbrellaName = "\(target.name)-umbrella.h"
            let headers = files.publicHeaders.map { header -> String in
                var relative = header.lastPathComponent
                if let mappings = files.headerMappingsDir, header.hasPrefix(mappings) {
                    relative = String(header.dropFirst(mappings.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }
                return subdirectory.isEmpty ? relative : subdirectory + "/" + relative
            }
            try write(SupportFiles.umbrellaHeader(moduleName: target.moduleName, headers: headers, platform: target.platform.name), to: base.appendingPathComponent(umbrellaName))
            let moduleMap = SupportFiles.moduleMap(moduleName: target.moduleName, umbrellaHeader: umbrellaName, framework: false)
            try write(moduleMap, to: base.appendingPathComponent("\(target.moduleName).modulemap"))
        }
    }

    // MARK: - Aggregate targets

    private func makeAggregateTarget(
        _ aggregate: AggregateTarget, builder: ProjectBuilder, xcconfigs: XCConfigBuilder,
        podTargets: [String: PBXTarget], bundleTargets: [String: [PBXNativeTarget]]
    ) throws {
        let label = aggregate.label
        let userDirectory = aggregate.clientRoot
        for configuration in configurations {
            let config = xcconfigs.aggregateConfig(aggregate, configuration: configuration.name, userProjectDirectory: userDirectory)
            let file = supportFile(label, "\(label).\(configuration.name.lowercased()).xcconfig")
            try write(config.contents, to: file)
            builder.supportFileReference(file)
        }
        let dummy = supportFile(label, "\(label)-dummy.m")
        try write(SupportFiles.dummySource(name: label), to: dummy)
        builder.supportFileReference(dummy)

        // Acknowledgements.
        let linkedTargets = xcconfigs.transitiveTargets(aggregate.podTargetNames)
        var seenPods = Set<String>()
        let licenses = linkedTargets.filter { seenPods.insert($0.podName).inserted }
            .compactMap { SupportFiles.license(for: $0.rootSpec, podRoot: $0.pod.location) }
        try write(SupportFiles.acknowledgementsMarkdown(licenses), to: supportFile(label, "\(label)-acknowledgements.markdown"))
        try write(SupportFiles.acknowledgementsPlist(licenses), to: supportFile(label, "\(label)-acknowledgements.plist"))

        // Scripts used by the user target.
        try write(embedFrameworksScript(aggregate, linkedTargets: linkedTargets, xcconfigs: xcconfigs), to: supportFile(label, "\(label)-frameworks.sh"))
        try write(copyResourcesScript(aggregate, linkedTargets: linkedTargets, xcconfigs: xcconfigs), to: supportFile(label, "\(label)-resources.sh"))
        for script in ["frameworks.sh", "resources.sh"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: supportFile(label, "\(label)-\(script)").path)
        }

        var settings = platformSettings(aggregate.platform)
        // The aggregate xcconfig is written for the user project; inside Pods.xcodeproj
        // `${SRCROOT}` is the Pods directory itself.
        settings["PODS_ROOT"] = "${SRCROOT}"
        settings["PODS_PODFILE_DIR_PATH"] = .string("${SRCROOT}/" + Sandbox.relativePath(from: sandbox.root, to: plan.podfileURL.deletingLastPathComponent()))
        settings["SKIP_INSTALL"] = "YES"
        settings["OTHER_LDFLAGS"] = ""
        settings["OTHER_LIBTOOLFLAGS"] = ""
        if aggregate.buildType.isFramework {
            let info = supportFile(label, "\(label)-Info.plist")
            try write(SupportFiles.infoPlist(version: Version(1, 0, 0)), to: info)
            let umbrella = "\(label)-umbrella.h"
            try write(SupportFiles.umbrellaHeader(moduleName: aggregate.productName, headers: [], platform: aggregate.platform.name), to: supportFile(label, umbrella))
            try write(SupportFiles.moduleMap(moduleName: aggregate.productName, umbrellaHeader: umbrella, framework: true), to: supportFile(label, "\(label).modulemap"))
            settings["PRODUCT_NAME"] = .string(aggregate.productName)
            settings["DEFINES_MODULE"] = "YES"
            settings["INFOPLIST_FILE"] = .string("Target Support Files/\(label)/\(label)-Info.plist")
            settings["MODULEMAP_FILE"] = .string("Target Support Files/\(label)/\(label).modulemap")
            settings["MACH_O_TYPE"] = "staticlib"
            settings["CODE_SIGN_IDENTITY"] = ""
            settings["CODE_SIGNING_ALLOWED"] = "NO"
            settings["CURRENT_PROJECT_VERSION"] = "1"
            settings["VERSIONING_SYSTEM"] = "apple-generic"
        } else {
            settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
        }
        let native = builder.nativeTarget(
            name: label, productName: aggregate.productName, productFileName: aggregate.productFileName,
            productType: aggregate.buildType.isFramework ? .framework : .staticLibrary,
            settings: settings, xcconfigPrefix: "Target Support Files/\(label)/\(label)"
        )
        if let dummyReference = builder.supportFileReferences[dummy.path] {
            builder.addPhase(PBXSourcesBuildPhase(files: [builder.buildFile(dummyReference)]), to: native)
        }
        let products = try aggregate.packageProducts.map(builder.productDependency)
        if !products.isEmpty { native.packageProductDependencies = products }
        builder.addPhase(PBXFrameworksBuildPhase(files: products.map { builder.buildFile($0) }), to: native)
        if aggregate.buildType.isFramework {
            builder.addPhase(PBXHeadersBuildPhase(), to: native)
        }
        for target in linkedTargets {
            if let podTarget = podTargets[target.name] {
                builder.addDependency(native, on: podTarget)
            } else {
                for bundle in bundleTargets[target.name] ?? [] { builder.addDependency(native, on: bundle) }
            }
        }
    }

    private func embedFrameworksScript(_ aggregate: AggregateTarget, linkedTargets: [PodTarget], xcconfigs: XCConfigBuilder) -> String {
        var entries: [(configuration: String, frameworks: [String])] = []
        for configuration in configurations {
            var frameworks: [String] = []
            for target in linkedTargets where isLinked(target, in: aggregate, configuration: configuration.name) {
                if target.buildType == .dynamicFramework, target.shouldBuild {
                    frameworks.append("${BUILT_PRODUCTS_DIR}/\(target.name)/\(target.productName).framework")
                }
                for framework in target.files.plainFrameworks {
                    frameworks.append("\(xcconfigs.podRootSetting(target.pod))/\(framework)")
                }
                for xcframework in target.files.xcframeworks where xcframework.isFramework {
                    frameworks.append("\(xcconfigs.xcframeworksDirectory(target))/\(xcframework.libraryPath)")
                }
            }
            entries.append((configuration.name, frameworks))
        }
        return SupportFiles.embedFrameworksScript(frameworksByConfiguration: entries)
    }

    private func copyResourcesScript(_ aggregate: AggregateTarget, linkedTargets: [PodTarget], xcconfigs: XCConfigBuilder) -> String {
        var entries: [(configuration: String, resources: [String])] = []
        for configuration in configurations {
            var resources: [String] = []
            for target in linkedTargets where !target.buildType.isFramework && isLinked(target, in: aggregate, configuration: configuration.name) {
                resources += target.files.resources.map { "\(xcconfigs.podRootSetting(target.pod))/\($0)" }
                resources += target.files.resourceBundles.map { "${PODS_CONFIGURATION_BUILD_DIR}/\(target.name)/\($0.name).bundle" }
            }
            entries.append((configuration.name, resources))
        }
        return SupportFiles.copyResourcesScript(resourcesByConfiguration: entries)
    }

    private func isLinked(_ target: PodTarget, in aggregate: AggregateTarget, configuration: String) -> Bool {
        let configurations = aggregate.definition.dependencies.first { $0.dependency.rootName == target.podName }?.configurations ?? []
        return configurations.isEmpty || configurations.contains { $0.caseInsensitiveCompare(configuration) == .orderedSame }
    }
}

// MARK: - Project builder

/// Thin helper around `PBXProj` that creates and registers objects.
final class ProjectBuilder {
    let pbxproj = PBXProj(objectVersion: 56)
    let project: PBXProject
    let mainGroup: PBXGroup
    let productsGroup: PBXGroup
    private let podsGroup: PBXGroup
    private let developmentPodsGroup: PBXGroup
    private let supportFilesGroup: PBXGroup
    private let configurations: [(name: String, isDebug: Bool)]
    private let sandbox: Sandbox
    private var podGroups: [String: PodGroup] = [:]
    private var supportGroups: [String: PBXGroup] = [:]
    private(set) var supportFileReferences: [String: PBXFileReference] = [:]

    init(configurations: [(name: String, isDebug: Bool)], sandbox: Sandbox) {
        self.configurations = configurations
        self.sandbox = sandbox
        mainGroup = PBXGroup(sourceTree: .group)
        productsGroup = PBXGroup(sourceTree: .group, name: "Products")
        podsGroup = PBXGroup(sourceTree: .group, name: "Pods")
        developmentPodsGroup = PBXGroup(sourceTree: .group, name: "Development Pods")
        supportFilesGroup = PBXGroup(sourceTree: .group, name: "Targets Support Files")
        let projectConfigurations = configurations.map { configuration in
            XCBuildConfiguration(name: configuration.name, buildSettings: Self.projectSettings(debug: configuration.isDebug))
        }
        let configurationList = XCConfigurationList(buildConfigurations: projectConfigurations, defaultConfigurationName: configurations.last?.name)
        project = PBXProject(
            name: "Pods", buildConfigurationList: configurationList, compatibilityVersion: "Xcode 14.0",
            preferredProjectObjectVersion: 56, minimizedProjectReferenceProxies: nil, mainGroup: mainGroup,
            developmentRegion: "en", knownRegions: ["Base", "en"], productsGroup: productsGroup,
            attributes: ["LastSwiftUpdateCheck": .string("1600"), "LastUpgradeCheck": .string("1600")]
        )
        for object in [mainGroup, productsGroup, podsGroup, developmentPodsGroup, supportFilesGroup] as [PBXObject] {
            pbxproj.add(object: object)
        }
        projectConfigurations.forEach(pbxproj.add)
        pbxproj.add(object: configurationList)
        pbxproj.add(object: project)
        pbxproj.rootObject = project
        mainGroup.children = [developmentPodsGroup, podsGroup, productsGroup, supportFilesGroup]
    }

    static func projectSettings(debug: Bool) -> BuildSettings {
        var settings: BuildSettings = [
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "CLANG_ANALYZER_NONNULL": "YES",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++14",
            "CLANG_CXX_LIBRARY": "libc++",
            "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "CLANG_ENABLE_OBJC_WEAK": "YES",
            "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
            "COPY_PHASE_STRIP": "NO",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            "GCC_C_LANGUAGE_STANDARD": "gnu11",
            "GCC_NO_COMMON_BLOCKS": "YES",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "STRIP_INSTALLED_PRODUCT": "NO",
            "SWIFT_VERSION": "5.0",
        ]
        if debug {
            settings["DEBUG_INFORMATION_FORMAT"] = "dwarf"
            settings["ENABLE_TESTABILITY"] = "YES"
            settings["GCC_DYNAMIC_NO_PIC"] = "NO"
            settings["GCC_OPTIMIZATION_LEVEL"] = "0"
            settings["GCC_PREPROCESSOR_DEFINITIONS"] = .array(["POD_CONFIGURATION_DEBUG=1", "DEBUG=1", "$(inherited)"])
            settings["MTL_ENABLE_DEBUG_INFO"] = "INCLUDE_SOURCE"
            settings["ONLY_ACTIVE_ARCH"] = "YES"
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            settings["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"
        } else {
            settings["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"
            settings["ENABLE_NS_ASSERTIONS"] = "NO"
            settings["GCC_PREPROCESSOR_DEFINITIONS"] = .array(["POD_CONFIGURATION_RELEASE=1", "$(inherited)"])
            settings["MTL_ENABLE_DEBUG_INFO"] = "NO"
            settings["SWIFT_COMPILATION_MODE"] = "wholemodule"
            settings["SWIFT_OPTIMIZATION_LEVEL"] = "-O"
            settings["VALIDATE_PRODUCT"] = "YES"
        }
        return settings
    }

    private func add<T: PBXObject>(_ object: T) -> T {
        pbxproj.add(object: object)
        return object
    }

    func addPodfileReference(_ url: URL) {
        let path = Sandbox.relativePath(from: sandbox.root, to: url)
        let reference = add(PBXFileReference(sourceTree: .sourceRoot, name: url.lastPathComponent, lastKnownFileType: url.pathExtension == "swift" ? "sourcecode.swift" : "text", path: path))
        mainGroup.children.insert(reference, at: 0)
    }

    /// File references of a pod, organised in nested groups mirroring the directory layout.
    final class PodGroup {
        let group: PBXGroup
        var references: [String: PBXFileReference] = [:]
        init(group: PBXGroup) { self.group = group }
        func reference(_ path: String) -> PBXFileReference { references[path]! }
    }

    func podGroup(for pod: InstalledPod, files: [String]) -> PodGroup {
        let podGroup: PodGroup
        if let existing = podGroups[pod.name] {
            podGroup = existing
        } else {
            let path = Sandbox.relativePath(from: sandbox.root, to: pod.location)
            let group = add(PBXGroup(sourceTree: .group, name: pod.name, path: path))
            (pod.isLocal ? developmentPodsGroup : podsGroup).children.append(group)
            podGroup = PodGroup(group: group)
            podGroups[pod.name] = podGroup
        }
        for file in files where podGroup.references[file] == nil {
            var parent = podGroup.group
            let components = file.split(separator: "/").map(String.init)
            for component in components.dropLast() {
                if let child = parent.children.compactMap({ $0 as? PBXGroup }).first(where: { $0.path == component }) {
                    parent = child
                } else {
                    let child = add(PBXGroup(sourceTree: .group, path: component))
                    parent.children.append(child)
                    parent = child
                }
            }
            let reference = add(PBXFileReference(sourceTree: .group, lastKnownFileType: Self.fileType(file), path: components.last))
            parent.children.append(reference)
            podGroup.references[file] = reference
        }
        return podGroup
    }

    @discardableResult
    func supportFileReference(_ url: URL) -> PBXFileReference {
        if let existing = supportFileReferences[url.path] { return existing }
        let targetName = url.deletingLastPathComponent().lastPathComponent
        let group: PBXGroup
        if let existing = supportGroups[targetName] {
            group = existing
        } else {
            group = add(PBXGroup(sourceTree: .group, name: targetName, path: "Target Support Files/\(targetName)"))
            supportFilesGroup.children.append(group)
            supportGroups[targetName] = group
        }
        let reference = add(PBXFileReference(sourceTree: .group, lastKnownFileType: Self.fileType(url.lastPathComponent), path: url.lastPathComponent))
        group.children.append(reference)
        supportFileReferences[url.path] = reference
        return reference
    }

    func addPackageReference(url: String, from lower: String, to upper: String) {
        let reference = add(XCRemoteSwiftPackageReference(repositoryURL: url, versionRequirement: .range(from: lower, to: upper)))
        project.remotePackages.append(reference)
    }

    /// A new dependency on a product of a package added with `addPackageReference`.
    func productDependency(_ product: PackageProductRef) throws -> XCSwiftPackageProductDependency {
        guard let package = project.remotePackages.first(where: { $0.repositoryURL == product.packageURL }) else {
            throw PodsError("Swift package \(product.packageURL) has no package reference.")
        }
        return add(XCSwiftPackageProductDependency(productName: product.product, package: package))
    }

    func buildFile(_ product: XCSwiftPackageProductDependency) -> PBXBuildFile {
        add(PBXBuildFile(product: product))
    }

    func buildFile(_ file: PBXFileElement, attributes: [String]? = nil, compilerFlags: String? = nil) -> PBXBuildFile {
        var settings: [String: BuildFileSetting] = [:]
        if let attributes { settings["ATTRIBUTES"] = .array(attributes) }
        if let compilerFlags { settings["COMPILER_FLAGS"] = .string(compilerFlags) }
        return add(PBXBuildFile(file: file, settings: settings.isEmpty ? nil : settings))
    }

    func nativeTarget(name: String, productName: String, productFileName: String, productType: PBXProductType, settings: BuildSettings, xcconfigPrefix: String) -> PBXNativeTarget {
        let buildConfigurations = configurations.map { configuration -> XCBuildConfiguration in
            let xcconfigPath = "\(xcconfigPrefix).\(configuration.name.lowercased()).xcconfig"
            let base = supportFileReferences.first { $0.key.hasSuffix(xcconfigPath) }?.value
            var targetSettings = settings
            if !configuration.isDebug { targetSettings["VALIDATE_PRODUCT"] = "YES" }
            return add(XCBuildConfiguration(name: configuration.name, baseConfiguration: base, buildSettings: targetSettings))
        }
        let list = add(XCConfigurationList(buildConfigurations: buildConfigurations, defaultConfigurationName: configurations.last?.name))
        let product = add(PBXFileReference(
            sourceTree: .buildProductsDir, name: productName, explicitFileType: Self.productFileType(productType),
            path: productFileName, includeInIndex: false
        ))
        productsGroup.children.append(product)
        let target = add(PBXNativeTarget(name: name, buildConfigurationList: list, productName: productName, product: product, productType: productType))
        project.targets.append(target)
        return target
    }

    /// A target without a product, used to run scripts (e.g. copying xcframework slices).
    func aggregateTarget(name: String, settings: BuildSettings, xcconfigPrefix: String) -> PBXAggregateTarget {
        let buildConfigurations = configurations.map { configuration -> XCBuildConfiguration in
            let xcconfigPath = "\(xcconfigPrefix).\(configuration.name.lowercased()).xcconfig"
            let base = supportFileReferences.first { $0.key.hasSuffix(xcconfigPath) }?.value
            return add(XCBuildConfiguration(name: configuration.name, baseConfiguration: base, buildSettings: settings))
        }
        let list = add(XCConfigurationList(buildConfigurations: buildConfigurations, defaultConfigurationName: configurations.last?.name))
        let target = add(PBXAggregateTarget(name: name, buildConfigurationList: list, productName: name))
        project.targets.append(target)
        return target
    }

    func addPhase(_ phase: PBXBuildPhase, to target: PBXTarget, atStart: Bool = false) {
        pbxproj.add(object: phase)
        if atStart { target.buildPhases.insert(phase, at: 0) } else { target.buildPhases.append(phase) }
    }

    func addDependency(_ target: PBXTarget, on dependency: PBXTarget) {
        guard !target.dependencies.contains(where: { $0.target === dependency }) else { return }
        let proxy = add(PBXContainerItemProxy(containerPortal: .project(project), remoteGlobalID: .object(dependency), proxyType: .nativeTarget, remoteInfo: dependency.name))
        let targetDependency = add(PBXTargetDependency(name: dependency.name, target: dependency, targetProxy: proxy))
        target.dependencies.append(targetDependency)
    }

    func write(to url: URL) throws {
        // Sort groups for a stable, readable navigator.
        for group in [podsGroup, developmentPodsGroup, supportFilesGroup] {
            group.children.sort { ($0.name ?? $0.path ?? "") < ($1.name ?? $1.path ?? "") }
        }
        let xcodeproj = XcodeProj(workspace: XCWorkspace(), pbxproj: pbxproj)
        try xcodeproj.write(path: Path(url.path))
    }

    static func fileType(_ path: String) -> String? {
        switch path.pathExtension.lowercased() {
        case "swift": "sourcecode.swift"
        case "h": "sourcecode.c.h"
        case "hh", "hpp", "hxx": "sourcecode.cpp.h"
        case "m": "sourcecode.c.objc"
        case "mm": "sourcecode.cpp.objcpp"
        case "c": "sourcecode.c.c"
        case "cc", "cpp", "cxx", "c++": "sourcecode.cpp.cpp"
        case "s": "sourcecode.asm"
        case "metal": "sourcecode.metal"
        case "xcconfig": "text.xcconfig"
        case "plist": "text.plist.xml"
        case "modulemap": "sourcecode.module"
        case "pch": "sourcecode.c.h"
        case "sh": "text.script.sh"
        case "xcassets": "folder.assetcatalog"
        case "storyboard": "file.storyboard"
        case "xib": "file.xib"
        case "framework": "wrapper.framework"
        case "xcframework": "wrapper.xcframework"
        case "a": "archive.ar"
        case "bundle": "wrapper.plug-in"
        case "strings": "text.plist.strings"
        case "json": "text.json"
        case "xcprivacy": "text.xml"
        case "png": "image.png"
        case "jpg", "jpeg": "image.jpeg"
        case "md", "markdown": "net.daringfireball.markdown"
        default: nil
        }
    }

    static func productFileType(_ type: PBXProductType) -> String {
        switch type {
        case .framework, .staticFramework: "wrapper.framework"
        case .bundle: "wrapper.cfbundle"
        case .staticLibrary: "archive.ar"
        default: "wrapper"
        }
    }
}
