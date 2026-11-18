import CryptoKit
public import Foundation
public import PodsCore
import PodsLockfile
import PodsPodfile
import PodsResolver
import PodsSources
import PodsSpec

/// Runs `install` / `update`: analysis, download, project generation, integration and lockfile.
public struct Installer: Sendable {
    public let context: InstallerContext
    public let options: InstallOptions

    public init(context: InstallerContext, options: InstallOptions = InstallOptions()) {
        self.context = context
        self.options = options
    }

    @discardableResult
    public func install() async throws -> InstallationPlan {
        try await installReturningAnalysis().plan
    }

    /// `install()`, also returning the analysis (with the pods at their installed locations).
    func installReturningAnalysis() async throws -> (plan: InstallationPlan, analysis: Analysis) {
        let ui = context.ui
        let analysis = try await Analyzer(context: context, options: options).analyze()
        let sandbox = context.sandbox
        try sandbox.prepare()

        // Copy downloaded pods from the cache into Pods/; `:path` pods stay where they are.
        var pods: [InstalledPod] = []
        for var pod in analysis.pods {
            if !pod.isLocal {
                pod.location = try sandbox.installPod(named: pod.name, version: pod.spec.version.rawValue + (pod.checkoutOptions[":commit"] ?? ""), from: pod.location)
            }
            pods.append(pod)
        }
        sandbox.removeUnused(keeping: Set(pods.filter { !$0.isLocal }.map(\.name)))
        let installedAnalysis = Analysis(podfile: analysis.podfile, lockfile: analysis.lockfile, pods: pods,
                                         userProjects: analysis.userProjects, targetProjects: analysis.targetProjects,
                                         targetPlatforms: analysis.targetPlatforms, unifications: analysis.unifications,
                                         unifiedProducts: analysis.unifiedProducts, swiftPackages: analysis.swiftPackages)

        let plan = try TargetBuilder(analysis: installedAnalysis, podfileURL: context.podfileURL, projectDirectory: context.projectDirectory).build()
        let lockfile = makeLockfile(plan: plan, previous: analysis.lockfile, swiftPackages: analysis.swiftPackages, unifications: analysis.unifications)
        if options.deployment, let previous = analysis.lockfile, previous != lockfile {
            throw PodsError("There were changes to the lockfile in deployment mode. Run `swiftpods install` and commit Podfile.lock.")
        }

        try await ui.section("Generating Pods project") {
            try PodsProjectGenerator(plan: plan, sandbox: sandbox).generate()
            try writePackageResolved(analysis.swiftPackages?.resolvedFile)
        }
        if options.integrate, plan.podfile.installationOption("integrate_targets") != false {
            try await ui.section("Integrating client project") {
                try UserProjectIntegrator(plan: plan, sandbox: sandbox, projectDirectory: context.projectDirectory, ui: ui).integrate()
            }
        }
        try lockfile.write(to: context.lockfileURL)
        try lockfile.write(to: sandbox.manifestURL)

        let direct = plan.podfile.allDependencies.count
        ui.message("Pod installation complete! There \(direct == 1 ? "is" : "are") \(direct) dependenc\(direct == 1 ? "y" : "ies") from the Podfile and \(pods.count) total pod\(pods.count == 1 ? "" : "s") installed.", style: .success)
        return (plan, installedAnalysis)
    }

    /// Pins the package references of `Pods.xcodeproj` to the versions of the final resolution, where Xcode looks for them.
    /// Never written to the user's workspace.
    private func writePackageResolved(_ contents: Data?) throws {
        let url = context.sandbox.projectURL.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        guard let contents, !contents.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
    }

    // MARK: - Lockfile

    /// `previous` is the lockfile being replaced; its `COCOAPODS:` version is kept so that teams
    /// mixing CocoaPods and swiftpods don't see that line change on every install.
    func makeLockfile(plan: InstallationPlan, previous: Lockfile?, swiftPackages: SwiftPackageResolver.Result?,
                      unifications: [PackageUnifier.Unification]) -> Lockfile {
        var lockPods: [Lockfile.Pod] = []
        var specRepos: [String: [String]] = [:]
        var externalSources: [String: [String: String]] = [:]
        var checkoutOptions: [String: [String: String]] = [:]
        var checksums: [String: String] = [:]

        for pod in plan.pods {
            // Every activated library spec is listed with the dependencies it declares.
            let platforms = Set(plan.aggregateTargets.map(\.platform.name))
            for name in pod.activatedSpecs {
                guard let spec = pod.spec.subspec(named: name) else { continue }
                var dependencies: [String] = []
                for platform in platforms.sorted() where spec.availablePlatforms.contains(where: { $0.name == platform }) {
                    for dependency in spec.dependencies(for: platform) where !dependencies.contains(dependency.lockfileDescription) {
                        dependencies.append(dependency.lockfileDescription)
                    }
                }
                lockPods.append(Lockfile.Pod(name: name, version: pod.spec.version, dependencies: dependencies))
            }
            if let sourceName = pod.sourceName {
                specRepos[sourceName, default: []].append(pod.name)
            }
            if let external = pod.externalSource {
                externalSources[pod.name] = Dictionary(uniqueKeysWithValues: external.lockfileEntries.map { ($0.key, $0.value) })
                if case .git = external, !pod.checkoutOptions.isEmpty { checkoutOptions[pod.name] = pod.checkoutOptions }
            }
            if let checksum = pod.spec.checksum { checksums[pod.name] = checksum }
        }
        // Every pin of the final resolution, with the range it was resolved in (none for indirect packages).
        let lockPackages = (swiftPackages?.pins ?? []).map { pin -> Lockfile.SwiftPackage in
            let url = plan.podfile.swiftPackages.first { $0.identity == pin.identity }?.url ?? pin.url
            let requirement = plan.swiftPackages.first { $0.url == url }.map { reference in
                Requirement(constraints: [.init(.greaterThanOrEqual, reference.lowerBound), .init(.lessThan, reference.upperBound)]).lockfileDescription
            }
            return Lockfile.SwiftPackage(url: url, requirement: requirement ?? "", version: pin.version, revision: pin.revision,
                                         pods: unifications.filter { $0.packageURL == url }.map(\.podRoot).sorted())
        }
        .sorted { $0.url < $1.url }
        let podfileData = (try? Data(contentsOf: plan.podfileURL)) ?? Data()
        return Lockfile(
            pods: lockPods,
            dependencies: plan.podfile.allDependencies.map(\.dependency.lockfileDescription).reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
            specRepos: specRepos,
            externalSources: externalSources,
            checkoutOptions: checkoutOptions,
            specChecksums: checksums,
            swiftPackages: lockPackages,
            podfileChecksum: Insecure.SHA1.hash(data: podfileData).map { String(format: "%02x", $0) }.joined(),
            cocoapodsVersion: previous?.cocoapodsVersion ?? Lockfile.compatibleCocoaPodsVersion
        )
    }
}

/// `deintegrate`: removes SwiftPods/CocoaPods from the user projects.
public struct Deintegrator: Sendable {
    public let projectDirectory: URL
    public let ui: UI

    public init(projectDirectory: URL, ui: UI = UI()) {
        self.projectDirectory = projectDirectory
        self.ui = ui
    }

    public func deintegrate() throws {
        let projects = ((try? FileManager.default.contentsOfDirectory(atPath: projectDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".xcodeproj") }
        guard !projects.isEmpty else { throw PodsError("No `.xcodeproj` found in \(projectDirectory.path).") }
        for project in projects.sorted() {
            ui.message("Deintegrating `\(project)`", style: .title)
            try UserProjectIntegrator.deintegrate(projectURL: projectDirectory.appendingPathComponent(project), ui: ui)
        }
        let pods = projectDirectory.appendingPathComponent("Pods")
        if FileManager.default.fileExists(atPath: pods.path) {
            try FileManager.default.removeItem(at: pods)
            ui.message("Removed the `Pods` directory.")
        }
        ui.message("Project has been deintegrated. The Podfile, Podfile.lock and workspace were kept.", style: .success)
    }
}

/// `outdated`: compares locked versions with the newest available ones.
public struct OutdatedChecker: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let current: Version
        /// The version `update` would install, or `nil` when the pod is no longer used.
        public let allowed: Version?
        /// Newest published version.
        public let latest: Version?
    }

    public let context: InstallerContext

    public init(context: InstallerContext) { self.context = context }

    public func check() async throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: context.lockfileURL.path) else {
            throw PodsError("No `Podfile.lock` found. Run `swiftpods install` first.")
        }
        // Like `pod outdated`, the allowed version is what `update` would pick: a resolution with
        // every pod unlocked, so requirements of other pods (not only the Podfile's) are respected.
        let analyzer = Analyzer(context: context, options: InstallOptions(update: .all, integrate: false))
        let resolution = try await analyzer.resolveDependencies()
        guard let lockfile = resolution.lockfile else { return [] }
        let sources = context.sources ?? SourcesManager(urls: resolution.podfile.effectiveSources, cacheRoot: context.cacheRoot)
        let allowedVersions = Dictionary(resolution.pods.map { ($0.name, $0.version) }, uniquingKeysWith: { a, _ in a })
        let current = Dictionary(lockfile.pods.map { (Dependency.rootName(of: $0.name), $0.version) }, uniquingKeysWith: { a, _ in a })

        return try await withThrowingTaskGroup(of: Entry?.self) { group in
            for (name, current) in current where lockfile.externalSources[name] == nil {
                let allowed = allowedVersions[name]
                group.addTask {
                    let versions = try await sources.candidates(for: name).map(\.version).filter { !$0.isPreRelease || current.isPreRelease }
                    guard let latest = versions.max(), latest > current else { return nil }
                    return Entry(name: name, current: current, allowed: allowed, latest: latest)
                }
            }
            var entries: [Entry] = []
            for try await entry in group { if let entry { entries.append(entry) } }
            return entries.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }
}
