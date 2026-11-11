public import PodsCore
public import PodsSources
public import PodsSpec

/// A root dependency of the resolution, coming from the Podfile.
public struct RootRequirement: Sendable, Hashable {
    public let dependency: Dependency
    /// Platforms of the user targets that use the dependency.
    public let platforms: Set<Platform>
    /// Restrict to a spec source (`pod 'X', :source => '...'`).
    public let sourceURL: String?

    public init(dependency: Dependency, platforms: Set<Platform>, sourceURL: String? = nil) {
        self.dependency = dependency
        self.platforms = platforms
        self.sourceURL = sourceURL
    }
}

/// A pod chosen by the resolver.
public struct ResolvedPod: Sendable {
    /// The root specification.
    public let spec: Specification
    /// The source it came from (`nil` for external sources).
    public let source: (any SpecSource)?
    /// Full names of every activated spec (root and/or subspecs), sorted.
    public let activatedSpecs: [String]

    public var name: String { spec.name }
    public var version: Version { spec.version }
}

public struct ResolutionError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Resolves Podfile dependencies to concrete pod versions.
///
/// The search is a depth-first backtracking search over an immutable state value:
/// trying a candidate copies the state, so undoing a choice is just dropping the copy.
public struct Resolver: Sendable {
    public let sources: SourcesManager
    /// Specs from external sources (`:path`, `:git`, `:podspec`) keyed by root name.
    public let externalSpecs: [String: Specification]
    /// Versions from Podfile.lock that should be kept when possible.
    public let lockedVersions: [String: Version]
    /// Root names allowed to move away from their locked version (`pod update X`); `nil` = all.
    public let unlockedPods: Set<String>?

    public init(sources: SourcesManager, externalSpecs: [String: Specification] = [:], lockedVersions: [String: Version] = [:], unlockedPods: Set<String>? = []) {
        self.sources = sources
        self.externalSpecs = externalSpecs
        self.lockedVersions = lockedVersions
        self.unlockedPods = unlockedPods
    }

    // MARK: - State

    struct Requirement: Sendable {
        let dependency: Dependency
        let platforms: Set<Platform>
        let requiredBy: String
        let sourceURL: String?
    }

    struct Activation: Sendable {
        let spec: Specification
        let source: (any SpecSource)?
        var subspecs: Set<String>
        var platforms: Set<Platform>
    }

    struct State: Sendable {
        var activations: [String: Activation] = [:]
        /// Every requirement seen for each root, used to filter candidates and to explain conflicts.
        var requirements: [String: [Requirement]] = [:]
        var queue: [Requirement] = []
    }

    // MARK: - Resolution

    public func resolve(_ roots: [RootRequirement]) async throws -> [ResolvedPod] {
        let provider = SpecProvider(sources: sources, externalSpecs: externalSpecs)
        var state = State()
        state.queue = roots.map { Requirement(dependency: $0.dependency, platforms: $0.platforms, requiredBy: "Podfile", sourceURL: $0.sourceURL) }
        let failure = FailureTracker()
        guard let resolved = try await search(state, provider: provider, failure: failure) else {
            throw await failure.error()
        }
        return resolved.activations.values
            .map { ResolvedPod(spec: $0.spec, source: $0.source, activatedSpecs: $0.subspecs.sorted()) }
            .sorted { $0.name < $1.name }
    }

    private func search(_ initial: State, provider: SpecProvider, failure: FailureTracker) async throws -> State? {
        var state = initial
        while !state.queue.isEmpty {
            let requirement = state.queue.removeFirst()
            let root = requirement.dependency.rootName
            state.requirements[root, default: []].append(requirement)

            if var activation = state.activations[root] {
                // Already chosen: the version must satisfy the new requirement.
                guard requirement.dependency.externalSource != nil || requirement.dependency.requirement.isSatisfied(by: activation.spec.version) else {
                    await failure.record(root: root, requirements: state.requirements[root] ?? [], reason: nil)
                    return nil
                }
                // Subspec dependencies (`Firebase/Core` → `Firebase/CoreOnly`) flow through the queue,
                // so a spec counts as activated only once its own dependencies have been enqueued.
                let newPlatforms = requirement.platforms.subtracting(activation.platforms)
                guard !activation.subspecs.contains(requirement.dependency.name) || !newPlatforms.isEmpty else { continue }
                guard let subspec = activation.spec.subspec(named: requirement.dependency.name),
                      requirement.platforms.allSatisfy(subspec.supports)
                else {
                    await failure.record(root: root, requirements: state.requirements[root] ?? [],
                                         reason: "`\(requirement.dependency.name)` is missing or does not support \(Self.describe(requirement.platforms))")
                    return nil
                }
                enqueue(requirement.dependency.name, of: activation.spec, platforms: requirement.platforms, into: &state)
                activation.subspecs.insert(requirement.dependency.name)
                activation.platforms.formUnion(requirement.platforms)
                state.activations[root] = activation
                continue
            }

            let candidates = try await self.candidates(for: root, state: state, provider: provider)
            prefetch(state.queue, provider: provider)
            if candidates.isEmpty {
                await failure.record(root: root, requirements: state.requirements[root] ?? [], reason: nil)
                return nil
            }
            for candidate in candidates {
                let spec = try await provider.specification(of: root, version: candidate.version, source: candidate.source)
                guard requirement.platforms.allSatisfy({ platform in
                    guard let target = spec.subspec(named: requirement.dependency.name) else { return false }
                    return target.supports(platform)
                }) else {
                    await failure.record(root: root, requirements: state.requirements[root] ?? [],
                                         reason: "`\(requirement.dependency.name) (\(candidate.version))` is missing or does not support \(Self.describe(requirement.platforms))")
                    continue
                }
                var next = state
                next.activations[root] = Activation(
                    spec: spec, source: candidate.source,
                    subspecs: [requirement.dependency.name],
                    platforms: requirement.platforms
                )
                enqueue(requirement.dependency.name, of: spec, platforms: requirement.platforms, into: &next)
                if let resolved = try await search(next, provider: provider, failure: failure) {
                    return resolved
                }
            }
            return nil
        }
        return state
    }

    /// Adds the dependencies of `name` (a spec or subspec) to the queue.
    private func enqueue(_ name: String, of root: Specification, platforms: Set<Platform>, into state: inout State) {
        guard let spec = root.subspec(named: name) else { return }
        for platform in platforms.sorted(by: { $0.name < $1.name }) {
            for dependency in spec.dependencies(for: platform.name) {
                state.queue.append(Requirement(dependency: dependency, platforms: [platform], requiredBy: "\(spec.name) (\(spec.version))", sourceURL: nil))
            }
        }
    }

    static func describe(_ platforms: Set<Platform>) -> String {
        platforms.map(\.description).sorted().joined(separator: ", ")
    }

    /// Candidate versions for a root pod, best first.
    private func candidates(for root: String, state: State, provider: SpecProvider) async throws -> [SourcesManager.Candidate] {
        let requirements = state.requirements[root] ?? []
        if let external = externalSpecs[root] {
            let satisfied = requirements.allSatisfy { $0.dependency.externalSource != nil || $0.dependency.requirement.isSatisfied(by: external.version) }
            return satisfied ? [SourcesManager.Candidate(version: external.version, source: ExternalSpecSource(spec: external))] : []
        }
        if let external = requirements.first(where: { $0.dependency.externalSource != nil }) {
            throw ResolutionError(message: "The external source of `\(external.dependency.name)` was not fetched before resolution")
        }
        let sourceURL = requirements.compactMap(\.sourceURL).first
        let allowsPreRelease = requirements.contains { $0.dependency.requirement.allowsPreRelease }
        var candidates = try await provider.candidates(for: root, sourceURL: sourceURL).filter { candidate in
            (allowsPreRelease || !candidate.version.isPreRelease)
                && requirements.allSatisfy { $0.dependency.requirement.isSatisfied(by: candidate.version) }
        }
        // Keep the locked version unless the pod is being updated.
        let isUnlocked = unlockedPods.map { $0.contains(root) } ?? true
        if !isUnlocked, let locked = lockedVersions[root], let index = candidates.firstIndex(where: { $0.version == locked }) {
            let lockedCandidate = candidates.remove(at: index)
            candidates.insert(lockedCandidate, at: 0)
        }
        return candidates
    }

    /// Warms caches for upcoming requirements in the background.
    private func prefetch(_ queue: [Requirement], provider: SpecProvider) {
        let roots = Set(queue.map(\.dependency.rootName)).filter { externalSpecs[$0] == nil }
        guard !roots.isEmpty else { return }
        Task { await provider.prefetch(Array(roots)) }
    }
}

/// A source wrapper for specs that come from an external source.
struct ExternalSpecSource: SpecSource {
    let spec: Specification
    var url: String { "external:\(spec.name)" }
    var lockfileName: String { url }
    func versions(of name: String) async throws -> [Version] { [spec.version] }
    func specification(of name: String, version: Version) async throws -> Specification { spec }
    func update() async throws {}
}

/// Caches candidate lists and specifications across the search.
actor SpecProvider {
    let sources: SourcesManager
    let externalSpecs: [String: Specification]
    private var candidateCache: [String: Task<[SourcesManager.Candidate], any Error>] = [:]
    private var specCache: [String: Task<Specification, any Error>] = [:]

    init(sources: SourcesManager, externalSpecs: [String: Specification]) {
        self.sources = sources
        self.externalSpecs = externalSpecs
    }

    func candidates(for root: String, sourceURL: String?) async throws -> [SourcesManager.Candidate] {
        let key = root + "|" + (sourceURL ?? "")
        if let task = candidateCache[key] { return try await task.value }
        let sources = self.sources
        let task = Task { try await sources.candidates(for: root, restrictedTo: sourceURL) }
        candidateCache[key] = task
        return try await task.value
    }

    func specification(of root: String, version: Version, source: any SpecSource) async throws -> Specification {
        let key = "\(source.lockfileName)|\(root)|\(version)"
        if let task = specCache[key] { return try await task.value }
        let task = Task { try await source.specification(of: root, version: version) }
        specCache[key] = task
        return try await task.value
    }

    /// Fetches candidate lists and the newest spec of each root concurrently; errors are ignored here
    /// and surface when the resolver actually needs the data.
    func prefetch(_ roots: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for root in roots {
                group.addTask {
                    guard let best = try? await self.candidates(for: root, sourceURL: nil).first(where: { !$0.version.isPreRelease }) else { return }
                    _ = try? await self.specification(of: root, version: best.version, source: best.source)
                }
            }
        }
    }
}

/// Remembers the deepest conflict to explain a failed resolution.
actor FailureTracker {
    private var root: String?
    private var requirements: [Resolver.Requirement] = []
    private var reasons: [String] = []

    func record(root: String, requirements: [Resolver.Requirement], reason: String?) {
        if requirements.count >= self.requirements.count || self.root == nil {
            self.root = root
            self.requirements = requirements
        }
        if let reason, !reasons.contains(reason) { reasons.append(reason) }
    }

    func error() -> ResolutionError {
        guard let root else { return ResolutionError(message: "Unable to resolve dependencies") }
        var lines = ["Unable to satisfy the following requirements for `\(root)`:", ""]
        for requirement in requirements {
            lines.append("- `\(requirement.dependency.description)` required by `\(requirement.requiredBy)`")
        }
        if !reasons.isEmpty {
            lines.append("")
            lines += reasons.prefix(5)
        }
        return ResolutionError(message: lines.joined(separator: "\n"))
    }
}
