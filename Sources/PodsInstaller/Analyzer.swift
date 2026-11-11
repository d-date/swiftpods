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
    /// Platform of every non-abstract target.
    let targetPlatforms: [String: Platform]
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
        let targetPlatforms: [String: Platform]
        let externals: [String: FetchedExternal]
        let pods: [ResolvedPod]
        let downloader: Downloader
    }

    func analyze() async throws -> Analysis {
        let resolution = try await resolveDependencies()
        let ui = context.ui
        let externals = resolution.externals
        let resolved = resolution.pods
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
                        userProjects: resolution.userProjects, targetPlatforms: resolution.targetPlatforms)
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

        // User projects and target platforms.
        var userProjects: [URL: UserProjectInfo] = [:]
        var platforms: [String: Platform] = [:]
        for target in podfile.resolvedTargets {
            let projectURL = try Self.projectURL(for: target, projectDirectory: context.projectDirectory)
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
        return Resolution(podfile: podfile, lockfile: lockfile, userProjects: userProjects, targetPlatforms: platforms,
                          externals: externals, pods: resolved, downloader: downloader)
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
