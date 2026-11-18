import CryptoKit
public import Foundation
public import PodsCore
import PodsDownloader
import PodsLockfile
import PodsManifest
public import PodsPodfile
import PodsResolver
public import PodsSources
import PodsSpec

/// Options for an install or update.
public struct InstallOptions: Sendable {
    public enum UpdateMode: Sendable, Equatable {
        /// `install`: keep locked versions.
        case none
        /// `update`: re-resolve everything.
        case all
        /// `update A B`: only the given pods may change.
        case pods(Set<String>)
    }

    public var update: UpdateMode
    /// `--repo-update`: refresh spec sources first.
    public var repoUpdate: Bool
    /// Integrate the user project (`false` = only generate `Pods/`).
    public var integrate: Bool
    /// `--deployment`: fail if Podfile.lock would change.
    public var deployment: Bool

    public init(update: UpdateMode = .none, repoUpdate: Bool = false, integrate: Bool = true, deployment: Bool = false) {
        self.update = update
        self.repoUpdate = repoUpdate
        self.integrate = integrate
        self.deployment = deployment
    }
}

/// Paths and services shared by the installation steps.
public struct InstallerContext: Sendable {
    public let projectDirectory: URL
    public let podfileURL: URL
    public let sandbox: Sandbox
    public let cacheRoot: URL
    public let ui: UI
    public let sources: SourcesManager?
    public let shell: Shell

    public init(projectDirectory: URL, podfileURL: URL? = nil, cacheRoot: URL = CacheLocations.root, ui: UI = UI(), sources: SourcesManager? = nil, shell: Shell = Shell()) throws {
        self.projectDirectory = projectDirectory.standardizedFileURL
        guard let podfile = podfileURL ?? PodfileLoader.podfileURL(in: projectDirectory) else {
            throw PodsError("No `Podfile` found in the project directory. Run `swiftpods init` to create one.")
        }
        self.podfileURL = podfile
        self.sandbox = Sandbox(root: projectDirectory.appendingPathComponent("Pods", isDirectory: true))
        self.cacheRoot = cacheRoot
        self.ui = ui
        self.sources = sources
        self.shell = shell
    }

    public var lockfileURL: URL { projectDirectory.appendingPathComponent("Podfile.lock") }
}

/// Result of analysis: the resolved and downloaded pods and the user projects.
struct Analysis: Sendable {
    let podfile: Podfile
    let lockfile: Lockfile?
    let pods: [InstalledPod]
    let userProjects: [URL: UserProjectInfo]
    /// The user project of every non-abstract target; empty when targets aren't integrated.
    let targetProjects: [String: URL]
    /// Platform of every non-abstract target.
    let targetPlatforms: [String: Platform]
    /// Pods replaced by SwiftPM packages; they are not in `pods`.
    let unifications: [PackageUnifier.Unification]
    /// Unified pod root → the library products of its package that hold the code of its activated specs.
    let unifiedProducts: [String: [String]]
    /// `nil` when the Podfile declares no SwiftPM packages.
    let swiftPackages: SwiftPackageResolver.Result?
}

/// Loads the Podfile, fetches external sources, resolves and downloads pods.
struct Analyzer {
    let context: InstallerContext
    let options: InstallOptions

    /// The resolved dependency graph, before anything is downloaded.
    struct Resolution: Sendable {
        let podfile: Podfile
        let lockfile: Lockfile?
        let userProjects: [URL: UserProjectInfo]
        let targetProjects: [String: URL]
        let targetPlatforms: [String: Platform]
        let externals: [String: FetchedExternal]
        /// Every resolved pod, including those replaced by SwiftPM packages.
        let pods: [ResolvedPod]
        let downloader: Downloader
        let unifications: [PackageUnifier.Unification]
        let unifiedProducts: [String: [String]]
        let swiftPackages: SwiftPackageResolver.Result?
    }

    func analyze() async throws -> Analysis {
        let resolution = try await resolveDependencies()
        let ui = context.ui
        let externals = resolution.externals
        let resolved = Self.podsOutsideSwiftPM(resolution)
        let downloader = resolution.downloader

        // Download released pods in parallel.
        var requests: [DownloadRequest] = []
        for pod in resolved where externals[pod.name] == nil || externals[pod.name]?.needsDownload == true {
            guard let source = pod.spec.source else { throw PodsError("`\(pod.name)` has no `source`.") }
            requests.append(DownloadRequest(name: pod.name, version: pod.version, source: source, prepareCommand: pod.spec.prepareCommand))
        }
        let downloads = try await ui.section("Downloading dependencies") {
            try await downloader.download(requests)
        }

        var pods: [InstalledPod] = []
        for pod in resolved {
            let external = externals[pod.name]
            if let external, !external.needsDownload {
                pods.append(InstalledPod(spec: pod.spec, activatedSpecs: pod.activatedSpecs, sourceName: nil, externalSource: external.source,
                                         location: external.location, isLocal: external.isLocal, checkoutOptions: external.checkoutOptions))
            } else {
                guard let download = downloads[pod.name] else { throw PodsError("`\(pod.name)` was not downloaded.") }
                pods.append(InstalledPod(spec: pod.spec, activatedSpecs: pod.activatedSpecs, sourceName: external == nil ? pod.source?.lockfileName : nil,
                                         externalSource: external?.source, location: download.location, isLocal: false,
                                         checkoutOptions: external?.checkoutOptions ?? [:]))
            }
            ui.message("Installing \(pod.name) (\(pod.version))", style: .success)
        }
        return Analysis(podfile: resolution.podfile, lockfile: resolution.lockfile, pods: pods,
                        userProjects: resolution.userProjects, targetProjects: resolution.targetProjects,
                        targetPlatforms: resolution.targetPlatforms, unifications: resolution.unifications,
                        unifiedProducts: resolution.unifiedProducts, swiftPackages: resolution.swiftPackages)
    }

    /// Pods reachable from the Podfile without going through a pod replaced by a SwiftPM package;
    /// the others come with the package.
    private static func podsOutsideSwiftPM(_ resolution: Resolution) -> [ResolvedPod] {
        guard !resolution.unifications.isEmpty else { return resolution.pods }
        let unified = Set(resolution.unifications.map(\.podRoot))
        let byName = Dictionary(resolution.pods.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let platformNames = Set(resolution.targetPlatforms.values.map(\.name))
        var reached = Set<String>()
        var queue = resolution.podfile.allDependencies.map(\.dependency.rootName)
        while let root = queue.popLast() {
            guard !unified.contains(root), reached.insert(root).inserted, let pod = byName[root] else { continue }
            for name in pod.activatedSpecs {
                guard let spec = pod.spec.subspec(named: name) else { continue }
                for platform in platformNames where spec.availablePlatforms.contains(where: { $0.name == platform }) {
                    queue += spec.dependencies(for: platform).map(\.rootName)
                }
            }
        }
        return resolution.pods.filter { reached.contains($0.name) }
    }

    /// Loads the Podfile, fetches external sources and resolves versions.
    func resolveDependencies() async throws -> Resolution {
        let ui = context.ui
        let podfile = try await PodfileLoader(swiftEvaluator: .init(cacheDirectory: context.cacheRoot.appendingPathComponent("Manifests"))).load(context.podfileURL)
        for hook in podfile.unsupportedHooks {
            ui.warn("`\(hook)` hooks are not supported by swiftpods and were ignored.")
        }
        for plugin in podfile.plugins {
            ui.warn("The CocoaPods plugin `\(plugin)` is not supported and was ignored.")
        }
        let lockfile = FileManager.default.fileExists(atPath: context.lockfileURL.path) ? try Lockfile(contentsOf: context.lockfileURL) : nil

        // User projects and target platforms. Like CocoaPods, user projects are only inspected
        // when they will be integrated; otherwise the Podfile must name the platform.
        let integrating = options.integrate && podfile.installationOption("integrate_targets") != false
        var userProjects: [URL: UserProjectInfo] = [:]
        var targetProjects: [String: URL] = [:]
        var platforms: [String: Platform] = [:]
        for target in podfile.resolvedTargets {
            guard integrating else {
                guard let platform = target.platform else {
                    throw PodsError("It is necessary to specify the platform in the Podfile if not integrating.")
                }
                platforms[target.name] = Platform(platform.name, platform.deploymentTarget)
                continue
            }
            let projectURL = try Self.projectURL(for: target, projectDirectory: context.projectDirectory)
            targetProjects[target.name] = projectURL
            if userProjects[projectURL] == nil { userProjects[projectURL] = try UserProjectInfo(url: projectURL) }
            let info = userProjects[projectURL]!
            if let platform = target.platform {
                platforms[target.name] = Platform(platform.name, platform.deploymentTarget ?? info.targets.first { $0.name == target.name }?.platform?.deploymentTarget)
            } else if let inferred = info.targets.first(where: { $0.name == target.name })?.platform {
                platforms[target.name] = inferred
            } else {
                ui.warn("Automatically assigning platform `iOS` to target `\(target.name)` because no platform was specified.")
                platforms[target.name] = Platform(.ios)
            }
            guard info.targets.contains(where: { $0.name == target.name }) else {
                throw PodsError("Unable to find a target named `\(target.name)` in project `\(projectURL.lastPathComponent)`, did find \(info.targets.map { "`\($0.name)`" }.joined(separator: ", ")).")
            }
        }

        if options.repoUpdate, let sources = context.sources {
            try await ui.section("Updating spec repositories") { try await sources.update() }
        }
        let sources = context.sources ?? SourcesManager(urls: podfile.effectiveSources, cacheRoot: context.cacheRoot)
        let downloader = Downloader(cacheDirectory: context.cacheRoot.appendingPathComponent("Pods"), shell: context.shell, ui: ui)

        // External sources must be fetched before resolution because they provide specs.
        let externals = try await fetchExternalSources(podfile: podfile, lockfile: lockfile, downloader: downloader)

        let roots = podfile.resolvedTargets.flatMap { target in
            target.dependencies.map {
                RootRequirement(dependency: $0.dependency, platforms: [platforms[target.name]!], sourceURL: $0.source)
            }
        }
        let locked: [String: Version] = lockfile.map { lock in
            Dictionary(lock.pods.map { (Dependency.rootName(of: $0.name), $0.version) }, uniquingKeysWith: { a, _ in a })
        } ?? [:]
        let unlocked: Set<String>? = switch options.update {
        case .none: unlockedByPodfileChanges(podfile: podfile, lockfile: lockfile)
        case .all: nil
        case .pods(let names): names.union(unlockedByPodfileChanges(podfile: podfile, lockfile: lockfile))
        }
        let resolved = try await ui.section("Analyzing dependencies") {
            try await Resolver(sources: sources, externalSpecs: externals.mapValues(\.spec), lockedVersions: locked, unlockedPods: unlocked)
                .resolve(roots)
        }
        var unifications: [PackageUnifier.Unification] = []
        var unifiedProducts: [String: [String]] = [:]
        var swiftPackages: SwiftPackageResolver.Result?
        if !podfile.swiftPackages.isEmpty {
            (unifications, unifiedProducts, swiftPackages) = try await ui.section("Resolving Swift packages") {
                try await resolveSwiftPackages(podfile: podfile, lockfile: lockfile, pods: resolved, externals: externals, platforms: platforms,
                                               sources: sources)
            }
        }
        return Resolution(podfile: podfile, lockfile: lockfile, userProjects: userProjects, targetProjects: targetProjects, targetPlatforms: platforms,
                          externals: externals, pods: resolved, downloader: downloader, unifications: unifications,
                          unifiedProducts: unifiedProducts, swiftPackages: swiftPackages)
    }

    // MARK: - Swift packages

    private typealias PackageRequirement = (url: String, lowerBound: Version?, upperBound: Version?, requirement: Requirement?)

    /// Resolves the declared packages, finds the pods that are the same library as a resolved package,
    /// and resolves again with those packages narrowed to the versions the pods accept. Also returns, for each
    /// unified pod, the package products that hold its code.
    private func resolveSwiftPackages(
        podfile: Podfile, lockfile: Lockfile?, pods: [ResolvedPod], externals: [String: FetchedExternal], platforms: [String: Platform],
        sources: SourcesManager
    ) async throws -> ([PackageUnifier.Unification], [String: [String]], SwiftPackageResolver.Result) {
        let pathHash = Insecure.SHA1.hash(data: Data(context.podfileURL.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let resolver = SwiftPackageResolver(
            workDirectory: context.cacheRoot.appendingPathComponent("SwiftPackages").appendingPathComponent(pathHash), shell: context.shell
        )
        let previous = previousPins(lockfile: lockfile)
        let previousResolved = SwiftPackageResolver.resolvedFile(pins: previous?.pins)
        let pinned = Set(previous?.pins.map(\.identity) ?? [])
        let tagIndex = GitTagIndex(shell: context.shell)

        // Declared packages by identity.
        var requirements: [String: PackageRequirement] = [:]
        for package in podfile.swiftPackages {
            requirements[package.identity] = (package.url, nil, nil, package.requirement)
        }
        let first = try await resolver.resolve(requirements.sorted { $0.key < $1.key }.map(\.value),
                                               previousResolved: previousResolved, updating: (previous?.updating ?? []).sorted(),
                                               readingProducts: false)
        try Self.rejectExternalPods(externals, from: podfile.swiftPackages.map(\.url) + first.pins.map(\.url))

        // Every package in the graph, including indirect ones, so that no library ends up linked twice.
        let packages = try await withThrowingTaskGroup(of: PackageUnifier.PackageCandidate.self) { group in
            for pin in first.pins {
                let declared = podfile.swiftPackages.first { $0.identity == pin.identity }
                // SwiftPM records `file://` URLs as plain paths; keep the URL as written in the Podfile.
                let url = declared?.url ?? pin.url
                group.addTask {
                    let tags = try await tagIndex.tags(of: pin.url)
                    var commits: [Version: String] = [:]
                    for (tag, commit) in tags.sorted(by: { $0.key < $1.key }) {
                        guard let version = GitTagIndex.swiftPMVersion(fromTag: tag), commits[version] == nil else { continue }
                        commits[version] = commit
                    }
                    return PackageUnifier.PackageCandidate(url: url, identity: pin.identity, podfileRequirement: declared?.requirement, commits: commits,
                                                           unsafeOverrideReason: declared?.unsafeOverrideReason)
                }
            }
            var result: [PackageUnifier.PackageCandidate] = []
            for try await package in group { result.append(package) }
            return result.sorted { $0.url < $1.url }
        }
        let candidates = try await podCandidates(podfile: podfile, pods: pods, externals: externals, platforms: platforms,
                                                 packages: packages, sources: sources, tagIndex: tagIndex)
        let unifications = try PackageUnifier.unify(pods: candidates, packages: packages)
        guard !unifications.isEmpty else {
            // The first resolution is final.
            return ([], [:], SwiftPackageResolver.Result(pins: first.pins, packages: try await resolver.packageContents(),
                                                         resolvedFile: first.resolvedFile))
        }

        let identities = Dictionary(packages.map { ($0.url, $0.identity) }, uniquingKeysWith: { a, _ in a })
        for unification in unifications {
            let identity = identities[unification.packageURL]!
            requirements[identity] = (unification.packageURL, unification.lowerBound, unification.upperBound, nil)
        }
        // `update <names>` also moves the packages the named pods are unified with now.
        var updating = previous?.updating ?? []
        if case .pods(let names) = options.update {
            updating.formUnion(unifications.filter { names.contains($0.podRoot) }.map { identities[$0.packageURL]! }.filter(pinned.contains))
        }
        let second = try await resolver.resolve(requirements.sorted { $0.key < $1.key }.map(\.value), previousResolved: previousResolved,
                                                updating: updating.sorted())
        try PackageUnifier.verifyNoNewPackages(first: first.pins, second: second.pins)
        for unification in unifications {
            let identity = identities[unification.packageURL]!
            guard let pin = second.pins.first(where: { $0.identity == identity }) else {
                throw PodsError("Swift package \(unification.packageURL) is missing from the resolved packages.")
            }
            try PackageUnifier.verify(unification, resolved: pin.version, revision: pin.revision)
            if unification.unsafeOverrideReason != nil, let pod = candidates.first(where: { $0.root == unification.podRoot }),
               let warning = PackageUnifier.unsafeOverrideWarning(unification, pod: pod, resolved: pin.version) {
                context.ui.warn(warning)
            }
        }
        return (unifications, try Self.unifiedProducts(unifications, pods: pods, identities: identities, resolved: second, platforms: platforms), second)
    }

    /// Unified pod root → the products of its package that hold the code of the pod's activated specs. The pod's source
    /// patterns are evaluated in the package checkout, which is at the commit of the pod version except with an unsafe
    /// override that resolved outside the versions the pod accepts.
    private static func unifiedProducts(
        _ unifications: [PackageUnifier.Unification], pods: [ResolvedPod], identities: [String: String],
        resolved: SwiftPackageResolver.Result, platforms: [String: Platform]
    ) throws -> [String: [String]] {
        let platformNames = Set(platforms.values.map(\.name)).sorted()
        var result: [String: [String]] = [:]
        for unification in unifications {
            guard let pod = pods.first(where: { $0.name == unification.podRoot }),
                  let identity = identities[unification.packageURL], let package = resolved.packages[identity] else {
                throw PodsError("Swift package \(unification.packageURL), which replaces pod `\(unification.podRoot)`, was not checked out.")
            }
            let specs = pod.activatedSpecs.compactMap { pod.spec.subspec(named: $0) }
            let products = try PackageProductSelector.select(
                podRoot: pod.name, specs: specs.isEmpty ? [pod.spec] : specs,
                platforms: platformNames.filter { name in pod.spec.availablePlatforms.contains { $0.name == name } },
                package: package, packageURL: unification.packageURL)
            result[pod.name] = products
        }
        return result
    }

    /// The pins the resolutions start from: the `SWIFT PACKAGES` of Podfile.lock, which is shared, or, without a lockfile, those
    /// under `Pods/`. A stale `Pods/` (after pulling a Podfile.lock that moved a package) must not move the pins back. `update` keeps none (`nil`); `update <names>` moves (`updating`) the pinned
    /// packages the named pods were unified with and those whose identity is named.
    private func previousPins(lockfile: Lockfile?) -> (pins: [SwiftPackageResolver.Pin], updating: Set<String>)? {
        let names: Set<String>
        switch options.update {
        case .all: return nil
        case .none: names = []
        case .pods(let pods): names = pods
        }
        let resolvedFileURL = context.sandbox.projectURL.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let pins: [SwiftPackageResolver.Pin]
        if let lockfile {
            pins = lockfile.swiftPackages.map { package in
                SwiftPackageResolver.Pin(identity: SwiftPackageDependency(url: package.url, requirement: .any).identity, url: package.url,
                                         version: package.version, revision: package.revision)
            }
        } else if let data = try? Data(contentsOf: resolvedFileURL), let resolved = try? SwiftPackageResolver.pins(fromResolved: data) {
            pins = resolved
        } else {
            return nil
        }
        var updating = Set(names.map { $0.lowercased() })
        for package in lockfile?.swiftPackages ?? [] where !names.isDisjoint(with: package.pods) {
            updating.insert(SwiftPackageDependency(url: package.url, requirement: .any).identity)
        }
        // Pod names that are not package identities are left out.
        return (pins, updating.intersection(pins.map(\.identity)))
    }

    /// An external pod (`:git`, `:path`, `:podspec`) built from the repository of a Swift package would be linked twice,
    /// and external pods are not unified.
    private static func rejectExternalPods(_ externals: [String: FetchedExternal], from packageURLs: [String]) throws {
        // SwiftPM records `file://` URLs as plain paths.
        func key(_ url: String) -> String { PackageUnifier.normalize(url.hasPrefix("file://") ? String(url.dropFirst(7)) : url) }
        var packages: [String: String] = [:]
        for url in packageURLs where packages[key(url)] == nil { packages[key(url)] = url }
        for (name, external) in externals.sorted(by: { $0.key < $1.key }) {
            let repository: String? = switch external.source {
            case .git(let url, _): url
            case .path, .podspec: if case .git(let url, _, _)? = external.spec.source { url } else { nil }
            }
            guard let repository, let package = packages[key(repository)] else { continue }
            throw PodsError(
                "`\(name)` comes from \(repository), the repository of Swift package \(package), so the library would be linked twice. "
                    + "Pods from external sources are not unified with Swift packages yet; use the pod from a spec source or drop it."
            )
        }
    }

    /// Pods from spec sources that may be the same library as one of `packages`, with every requirement on them
    /// and the commits of all their versions.
    ///
    /// A pod qualifies when its resolved version's source is a git tag and that repository shares a commit with a package
    /// or has the same URL as one; only those pods get every version's spec fetched.
    private func podCandidates(
        podfile: Podfile, pods: [ResolvedPod], externals: [String: FetchedExternal], platforms: [String: Platform],
        packages: [PackageUnifier.PackageCandidate], sources: SourcesManager, tagIndex: GitTagIndex
    ) async throws -> [PackageUnifier.PodCandidate] {
        var requirements: [String: [(origin: String, requirement: Requirement)]] = [:]
        func add(_ root: String, origin: String, _ requirement: Requirement) {
            guard !requirements[root, default: []].contains(where: { $0.origin == origin && $0.requirement == requirement }) else { return }
            requirements[root, default: []].append((origin, requirement))
        }
        let platformNames = Set(platforms.values.map(\.name)).sorted()
        for pod in pods {
            for name in pod.activatedSpecs {
                guard let spec = pod.spec.subspec(named: name) else { continue }
                for platform in platformNames where spec.availablePlatforms.contains(where: { $0.name == platform }) {
                    for dependency in spec.dependencies(for: platform) where dependency.rootName != pod.name {
                        add(dependency.rootName, origin: name, dependency.requirement)
                    }
                }
            }
        }
        for dependency in podfile.allDependencies {
            add(dependency.dependency.rootName, origin: "Podfile", dependency.dependency.requirement)
        }

        let packageCommits = Set(packages.flatMap(\.commits.values))
        let packageURLs = Set(packages.map { PackageUnifier.normalize($0.url) })
        let gitPods = try await withThrowingTaskGroup(of: (pod: ResolvedPod, repository: String)?.self) { group in
            for pod in pods {
                guard externals[pod.name] == nil, case .git(let url, .tag, _)? = pod.spec.source else { continue }
                group.addTask {
                    if packageURLs.contains(PackageUnifier.normalize(url)) { return (pod, url) }
                    let tags = try await tagIndex.tags(of: url)
                    return tags.values.contains(where: packageCommits.contains) ? (pod, url) : nil
                }
            }
            var result: [(pod: ResolvedPod, repository: String)] = []
            for try await candidate in group { if let candidate { result.append(candidate) } }
            return result
        }
        // Commits of every version whose source is a git tag; specs are fetched concurrently.
        // Versions come from the source's own listing, so a failure to load one of them is an error.
        let ui = context.ui
        let commits = try await withThrowingTaskGroup(of: (String, Version, String?).self) { group in
            for (pod, repository) in gitPods {
                for candidate in try await sources.candidates(for: pod.name) {
                    group.addTask {
                        let spec = try await candidate.source.specification(of: pod.name, version: candidate.version)
                        guard case .git(let url, .tag(let tag), _)? = spec.source else { return (pod.name, candidate.version, nil) }
                        guard url != repository else { return (pod.name, candidate.version, try await tagIndex.tags(of: url)[tag]) }
                        // Old versions may point at a repository that no longer exists.
                        do {
                            return (pod.name, candidate.version, try await tagIndex.tags(of: url)[tag])
                        } catch {
                            ui.warn("Skipping \(pod.name) \(candidate.version) while matching Swift packages: cannot list the tags of \(url).")
                            return (pod.name, candidate.version, nil)
                        }
                    }
                }
            }
            var result: [String: [Version: String]] = [:]
            for try await (name, version, commit) in group {
                if let commit { result[name, default: [:]][version] = commit }
            }
            return result
        }
        return gitPods.map { pod, repository in
            PackageUnifier.PodCandidate(root: pod.name, requirements: requirements[pod.name] ?? [], commits: commits[pod.name] ?? [:],
                                        repository: repository)
        }
        .sorted { $0.root < $1.root }
    }

    static func projectURL(for target: ResolvedTarget, projectDirectory: URL) throws -> URL {
        if let path = target.userProjectPath {
            let withExtension = path.hasSuffix(".xcodeproj") ? path : path + ".xcodeproj"
            return projectDirectory.appendingPathComponent(withExtension).standardizedFileURL
        }
        return try UserProjectInfo.findProject(in: projectDirectory).standardizedFileURL
    }

    /// Pods whose Podfile requirement changed since the lockfile was written are re-resolved.
    private func unlockedByPodfileChanges(podfile: Podfile, lockfile: Lockfile?) -> Set<String> {
        guard let lockfile else { return [] }
        let previous = Set(lockfile.dependencies)
        var changed = Set<String>()
        for dependency in podfile.allDependencies where !previous.contains(dependency.dependency.lockfileDescription) {
            changed.insert(dependency.dependency.rootName)
        }
        return changed
    }

    struct FetchedExternal: Sendable {
        let spec: Specification
        let source: ExternalSource
        let location: URL
        let isLocal: Bool
        let checkoutOptions: [String: String]
        /// `:podspec` pods are downloaded from the spec's own `source`.
        let needsDownload: Bool
    }

    /// Fetches `:path`, `:git` and `:podspec` sources concurrently and reads their specs.
    private func fetchExternalSources(podfile: Podfile, lockfile: Lockfile?, downloader: Downloader) async throws -> [String: FetchedExternal] {
        var sources: [String: ExternalSource] = [:]
        for dependency in podfile.allDependencies {
            guard let external = dependency.dependency.externalSource else { continue }
            let root = dependency.dependency.rootName
            if let existing = sources[root], existing != external {
                throw PodsError("`\(root)` is declared with different external sources.")
            }
            sources[root] = external
        }
        guard !sources.isEmpty else { return [:] }
        let context = self.context
        let loader = SpecLoader(swiftEvaluator: SwiftManifestEvaluator(cacheDirectory: context.cacheRoot.appendingPathComponent("Manifests")))
        return try await context.ui.section("Fetching external sources") {
            try await withThrowingTaskGroup(of: (String, FetchedExternal).self) { group in
                for (name, source) in sources {
                    // Reuse the locked commit for branch checkouts unless updating.
                    let lockedCommit = lockfile?.checkoutOptions[name]?[":commit"]
                    group.addTask {
                        (name, try await Self.fetch(name: name, source: source, lockedCommit: lockedCommit, updating: options.update != .none,
                                                    context: context, loader: loader, downloader: downloader))
                    }
                }
                var result: [String: FetchedExternal] = [:]
                for try await (name, fetched) in group {
                    guard fetched.spec.name == name else {
                        throw PodsError("The podspec for `\(name)` is named `\(fetched.spec.name)`.")
                    }
                    try context.sandbox.storeLocalPodspec(fetched.spec)
                    result[name] = fetched
                }
                return result
            }
        }
    }

    private static func fetch(
        name: String, source: ExternalSource, lockedCommit: String?, updating: Bool,
        context: InstallerContext, loader: SpecLoader, downloader: Downloader
    ) async throws -> FetchedExternal {
        context.ui.message("Fetching podspec for `\(name)` from \(source)")
        switch source {
        case .path(let path):
            let directory = context.projectDirectory.appendingPathComponent(path).standardizedFileURL
            guard let file = SpecLoader.podspecURL(named: name, in: directory) else {
                throw PodsError("No podspec found for `\(name)` in `\(path)`.")
            }
            let spec = try await loader.load(file)
            return FetchedExternal(spec: spec, source: source, location: directory, isLocal: true, checkoutOptions: [:], needsDownload: false)
        case .git(let url, var reference):
            if case .branch = reference, !updating, let lockedCommit { reference = .commit(lockedCommit) }
            if case .defaultBranch = reference, !updating, let lockedCommit { reference = .commit(lockedCommit) }
            let result = try await downloader.download(DownloadRequest(name: name, version: nil, source: .git(url: url, reference: reference, submodules: false)))
            guard let file = SpecLoader.podspecURL(named: name, in: result.location) else {
                throw PodsError("No podspec found for `\(name)` in \(url).")
            }
            let spec = try await loader.load(file)
            return FetchedExternal(spec: spec, source: source, location: result.location, isLocal: false, checkoutOptions: result.checkoutOptions, needsDownload: false)
        case .podspec(let location):
            let file: URL
            if let remote = URL(string: location), remote.scheme == "http" || remote.scheme == "https" {
                let (data, _) = try await URLSession.shared.data(from: remote)
                file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(remote.lastPathComponent)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
            } else {
                file = context.projectDirectory.appendingPathComponent(location).standardizedFileURL
            }
            let spec = try await loader.load(file)
            return FetchedExternal(spec: spec, source: source, location: file.deletingLastPathComponent(), isLocal: false, checkoutOptions: [:], needsDownload: true)
        }
    }
}
