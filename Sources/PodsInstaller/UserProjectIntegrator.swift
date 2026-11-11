import Foundation
import PathKit
import PodsCore
import PodsPodfile
import XcodeProj

/// Integrates the generated Pods into the user's Xcode project(s) and workspace.
struct UserProjectIntegrator {
    static let checkManifestPhase = "[CP] Check Pods Manifest.lock"
    static let embedFrameworksPhase = "[CP] Embed Pods Frameworks"
    static let copyResourcesPhase = "[CP] Copy Pods Resources"
    static let podsGroupName = "Pods"

    let plan: InstallationPlan
    let sandbox: Sandbox
    let projectDirectory: URL
    let ui: UI

    func integrate() throws {
        let byProject = Dictionary(grouping: plan.aggregateTargets, by: \.userProject)
        for (projectURL, aggregates) in byProject.sorted(by: { $0.key.path < $1.key.path }) {
            try integrate(projectURL: projectURL, aggregates: aggregates)
        }
        try writeWorkspace(projects: byProject.keys.sorted { $0.path < $1.path })
    }

    // MARK: - Project

    private func integrate(projectURL: URL, aggregates: [AggregateTarget]) throws {
        let xcodeproj = try XcodeProj(path: Path(projectURL.path))
        let pbxproj = xcodeproj.pbxproj
        guard let project = pbxproj.rootObject, let mainGroup = project.mainGroup else {
            throw PodsError("`\(projectURL.lastPathComponent)` has no root project.")
        }
        let projectDirectory = projectURL.deletingLastPathComponent()
        let podsGroup = findOrCreateGroup(named: Self.podsGroupName, in: mainGroup, pbxproj: pbxproj)
        let frameworksGroup = findOrCreateGroup(named: "Frameworks", in: mainGroup, pbxproj: pbxproj)
        let validLabels = Set(aggregates.map(\.label))

        for aggregate in aggregates {
            guard let target = pbxproj.nativeTargets.first(where: { $0.name == aggregate.definition.name }) else {
                throw PodsError("Unable to find the target `\(aggregate.definition.name)` in `\(projectURL.lastPathComponent)`.")
            }
            let supportDirectory = sandbox.supportFilesDirectory(aggregate.label)

            // Base configurations.
            for configuration in target.buildConfigurationList?.buildConfigurations ?? [] {
                let xcconfig = supportDirectory.appendingPathComponent("\(aggregate.label).\(configuration.name.lowercased()).xcconfig")
                let relative = Sandbox.relativePath(from: projectDirectory, to: xcconfig)
                if let existing = configuration.baseConfiguration, !(existing.path ?? "").contains("Pods-") {
                    ui.warn("""
                    `\(target.name)` (\(configuration.name)) already has a base configuration (`\(existing.path ?? "?")`). \
                    Include `\(relative)` from it, or remove it and run install again.
                    """)
                    continue
                }
                configuration.baseConfiguration = fileReference(path: relative, in: podsGroup, pbxproj: pbxproj, type: "text.xcconfig")
            }

            // Link the aggregate product.
            let frameworksPhase = try target.frameworksBuildPhase() ?? {
                let phase = PBXFrameworksBuildPhase()
                pbxproj.add(object: phase)
                target.buildPhases.append(phase)
                return phase
            }()
            removeStaleProducts(from: frameworksPhase, keeping: aggregate.productFileName, pbxproj: pbxproj)
            if !(frameworksPhase.files ?? []).contains(where: { $0.file?.path == aggregate.productFileName }) {
                let product = productReference(aggregate.productFileName, in: frameworksGroup, pbxproj: pbxproj)
                let buildFile = PBXBuildFile(file: product)
                pbxproj.add(object: buildFile)
                frameworksPhase.files = (frameworksPhase.files ?? []) + [buildFile]
            }

            // Script phases.
            let label = aggregate.label
            upsertPhase(
                named: Self.checkManifestPhase, in: target, pbxproj: pbxproj, atStart: true,
                script: SupportFiles.checkManifestScript,
                inputs: ["${PODS_PODFILE_DIR_PATH}/Podfile.lock", "${PODS_ROOT}/Manifest.lock"],
                outputs: ["$(DERIVED_FILE_DIR)/\(label)-checkManifestLockResult.txt"]
            )
            let embedsProducts = Self.embedsFrameworks(target.productType)
            let hasFrameworks = embedsProducts && hasEmbeddableFrameworks(aggregate)
            if hasFrameworks {
                upsertPhase(named: Self.embedFrameworksPhase, in: target, pbxproj: pbxproj, atStart: false,
                            script: "\"${PODS_ROOT}/Target Support Files/\(label)/\(label)-frameworks.sh\"\n", inputs: [], outputs: [], alwaysOutOfDate: true)
            } else {
                removePhase(named: Self.embedFrameworksPhase, from: target, pbxproj: pbxproj)
            }
            if embedsProducts && hasResources(aggregate) {
                upsertPhase(named: Self.copyResourcesPhase, in: target, pbxproj: pbxproj, atStart: false,
                            script: "\"${PODS_ROOT}/Target Support Files/\(label)/\(label)-resources.sh\"\n", inputs: [], outputs: [], alwaysOutOfDate: true)
            } else {
                removePhase(named: Self.copyResourcesPhase, from: target, pbxproj: pbxproj)
            }
        }
        // Remove xcconfig references of aggregates that no longer exist.
        podsGroup.children.removeAll { child in
            guard let path = child.path, path.contains("Target Support Files/Pods-") else { return false }
            return !validLabels.contains { path.contains("/\($0)/") }
        }
        try xcodeproj.write(path: Path(projectURL.path))
    }

    static func embedsFrameworks(_ type: PBXProductType?) -> Bool {
        switch type {
        case .application?, .unitTestBundle?, .uiTestBundle?, .watch2App?, .watch2AppContainer?, .onDemandInstallCapableApplication?:
            true
        default:
            false
        }
    }

    private func linkedTargets(_ aggregate: AggregateTarget) -> [PodTarget] {
        XCConfigBuilder(plan: plan, sandbox: sandbox).transitiveTargets(aggregate.podTargetNames)
    }

    private func hasEmbeddableFrameworks(_ aggregate: AggregateTarget) -> Bool {
        linkedTargets(aggregate).contains {
            ($0.buildType == .dynamicFramework && $0.shouldBuild) || !$0.files.plainFrameworks.isEmpty || $0.files.xcframeworks.contains(where: \.isFramework)
        }
    }

    private func hasResources(_ aggregate: AggregateTarget) -> Bool {
        linkedTargets(aggregate).contains { !$0.buildType.isFramework && (!$0.files.resources.isEmpty || !$0.files.resourceBundles.isEmpty) }
    }

    private func findOrCreateGroup(named name: String, in parent: PBXGroup, pbxproj: PBXProj) -> PBXGroup {
        if let existing = parent.children.compactMap({ $0 as? PBXGroup }).first(where: { $0.name == name || $0.path == name }) {
            return existing
        }
        let group = PBXGroup(sourceTree: .group, name: name)
        pbxproj.add(object: group)
        parent.children.append(group)
        return group
    }

    private func fileReference(path: String, in group: PBXGroup, pbxproj: PBXProj, type: String) -> PBXFileReference {
        if let existing = group.children.compactMap({ $0 as? PBXFileReference }).first(where: { $0.path == path }) {
            return existing
        }
        let reference = PBXFileReference(sourceTree: .group, name: (path as NSString).lastPathComponent, lastKnownFileType: type, path: path, includeInIndex: true)
        pbxproj.add(object: reference)
        group.children.append(reference)
        return reference
    }

    private func productReference(_ fileName: String, in group: PBXGroup, pbxproj: PBXProj) -> PBXFileReference {
        if let existing = group.children.compactMap({ $0 as? PBXFileReference }).first(where: { $0.path == fileName }) {
            return existing
        }
        let reference = PBXFileReference(
            sourceTree: .buildProductsDir,
            explicitFileType: fileName.hasSuffix(".framework") ? "wrapper.framework" : "archive.ar",
            path: fileName, includeInIndex: false
        )
        pbxproj.add(object: reference)
        group.children.append(reference)
        return reference
    }

    private func removeStaleProducts(from phase: PBXFrameworksBuildPhase, keeping fileName: String, pbxproj: PBXProj) {
        phase.files = (phase.files ?? []).filter { buildFile in
            guard let path = buildFile.file?.path else { return true }
            let isPodsProduct = path.hasPrefix("libPods-") || path.hasPrefix("Pods_")
            return !isPodsProduct || path == fileName
        }
    }

    private func upsertPhase(
        named name: String, in target: PBXNativeTarget, pbxproj: PBXProj, atStart: Bool,
        script: String, inputs: [String], outputs: [String], alwaysOutOfDate: Bool = false
    ) {
        let existing = target.buildPhases.compactMap { $0 as? PBXShellScriptBuildPhase }.first { $0.name == name }
        let phase = existing ?? {
            let phase = PBXShellScriptBuildPhase(name: name)
            pbxproj.add(object: phase)
            if atStart { target.buildPhases.insert(phase, at: 0) } else { target.buildPhases.append(phase) }
            return phase
        }()
        phase.shellScript = script
        phase.inputPaths = inputs
        phase.outputPaths = outputs
        phase.showEnvVarsInLog = false
        phase.alwaysOutOfDate = alwaysOutOfDate
    }

    private func removePhase(named name: String, from target: PBXNativeTarget, pbxproj: PBXProj) {
        target.buildPhases.removeAll { phase in
            guard let script = phase as? PBXShellScriptBuildPhase, script.name == name else { return false }
            pbxproj.delete(object: script)
            return true
        }
    }

    // MARK: - Workspace

    private func workspaceURL(projects: [URL]) -> URL {
        if let path = plan.podfile.workspacePath {
            let name = path.hasSuffix(".xcworkspace") ? path : path + ".xcworkspace"
            return projectDirectory.appendingPathComponent(name)
        }
        let first = projects.first!
        return projectDirectory.appendingPathComponent(first.deletingPathExtension().lastPathComponent + ".xcworkspace")
    }

    private func writeWorkspace(projects: [URL]) throws {
        let url = workspaceURL(projects: projects)
        let workspaceDirectory = url.deletingLastPathComponent()
        let required = projects.map { Sandbox.relativePath(from: workspaceDirectory, to: $0) }
            + [Sandbox.relativePath(from: workspaceDirectory, to: sandbox.projectURL)]
        let workspace: XCWorkspace
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("contents.xcworkspacedata").path) {
            workspace = try XCWorkspace(path: Path(url.path))
        } else {
            workspace = XCWorkspace(data: XCWorkspaceData(children: []))
        }
        let existing = Set(workspace.data.children.compactMap { element -> String? in
            if case .file(let ref) = element, case .group(let path) = ref.location { return path }
            if case .file(let ref) = element, case .container(let path) = ref.location { return path }
            return nil
        })
        for path in required where !existing.contains(path) {
            workspace.data.children.append(.file(XCWorkspaceDataFileRef(location: .group(path))))
        }
        try workspace.write(path: Path(url.path))
        ui.verbose("Wrote \(url.lastPathComponent)")
    }

    // MARK: - Deintegration

    /// Removes everything `integrate()` added from a project.
    static func deintegrate(projectURL: URL, ui: UI) throws {
        let xcodeproj = try XcodeProj(path: Path(projectURL.path))
        let pbxproj = xcodeproj.pbxproj
        for target in pbxproj.nativeTargets {
            if let list = target.buildConfigurationList {
                // XcodeProj ignores `baseConfiguration = nil`, so configurations are replaced instead.
                list.buildConfigurations = list.buildConfigurations.map { configuration in
                    guard let path = configuration.baseConfiguration?.path, path.contains("Target Support Files/Pods-") else {
                        return configuration
                    }
                    let replacement = XCBuildConfiguration(name: configuration.name, buildSettings: configuration.buildSettings)
                    pbxproj.add(object: replacement)
                    pbxproj.delete(object: configuration)
                    return replacement
                }
            }
            target.buildPhases.removeAll { phase in
                guard let script = phase as? PBXShellScriptBuildPhase, let name = script.name, name.hasPrefix("[CP] ") || name.hasPrefix("[CP-User] ") else { return false }
                pbxproj.delete(object: script)
                return true
            }
            if let frameworks = try target.frameworksBuildPhase() {
                frameworks.files = (frameworks.files ?? []).filter { buildFile in
                    guard let path = buildFile.file?.path else { return true }
                    return !(path.hasPrefix("libPods-") || path.hasPrefix("Pods_"))
                }
            }
            ui.message("Deintegrated target `\(target.name)`")
        }
        if let mainGroup = pbxproj.rootObject?.mainGroup {
            mainGroup.children.removeAll { child in
                guard let group = child as? PBXGroup, group.name == podsGroupName, group.path == nil else { return false }
                group.children.forEach(pbxproj.delete)
                pbxproj.delete(object: group)
                return true
            }
            for group in mainGroup.children.compactMap({ $0 as? PBXGroup }) where group.name == "Frameworks" {
                group.children.removeAll { child in
                    guard let path = child.path else { return false }
                    return path.hasPrefix("libPods-") || path.hasPrefix("Pods_")
                }
            }
        }
        try xcodeproj.write(path: Path(projectURL.path))
    }
}
