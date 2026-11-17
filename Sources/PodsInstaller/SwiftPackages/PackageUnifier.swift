import PodsCore

/// Decides which pods are the same library as a SwiftPM package, and which package versions are allowed.
///
/// Two are the same library when a git commit is shared, or when their repositories are the same.
/// Only package versions whose tag points at the same commit as an acceptable pod version are allowed,
/// so that prebuilt binaries get exactly the code they were built against.
struct PackageUnifier {
    struct PodCandidate: Sendable {
        let root: String
        /// Every requirement on the pod, with who declared it (for error messages).
        let requirements: [(origin: String, requirement: Requirement)]
        /// Pod version → commit of its `source` tag, for every version whose source is a git tag
        /// (not only versions within the requirements; all of them are used to identify the library).
        let commits: [Version: String]
        /// The pod's source repository, normalized (lowercased, no `.git`, no trailing `/`).
        let repository: String?
    }

    struct PackageCandidate: Sendable {
        let url: String
        let identity: String
        /// From `packages:`; nil for packages that are only indirect.
        let podfileRequirement: Requirement?
        /// SwiftPM version → commit (tags that `swiftPMVersion(fromTag:)` accepts).
        let commits: [Version: String]
        /// Set when Podfile.swift lets this package leave the versions the pods accept.
        let unsafeOverrideReason: String?

        init(url: String, identity: String, podfileRequirement: Requirement?, commits: [Version: String], unsafeOverrideReason: String? = nil) {
            self.url = url
            self.identity = identity
            self.podfileRequirement = podfileRequirement
            self.commits = commits
            self.unsafeOverrideReason = unsafeOverrideReason
        }
    }

    struct Unification: Sendable, Equatable {
        let podRoot: String
        let packageURL: String
        /// Ascending. Equal to `podAcceptedVersions`, except with an unsafe override: then every tagged version
        /// that satisfies the Podfile requirement, whether or not a pod version accepts its commit.
        let allowedVersions: [Version]
        /// With an unsafe override, the bounds of the Podfile requirement; otherwise those of `allowedVersions`.
        let lowerBound: Version
        /// Exclusive: the highest allowed version with its patch component + 1 (or the Podfile upper bound with an unsafe override).
        let upperBound: Version
        /// Commits of the allowed versions.
        let allowedCommits: Set<String>
        /// Ascending: every tagged release version of the package.
        let taggedVersions: [Version]
        /// Ascending: versions tagged at the commit of a pod version that satisfies the pod requirements and the Podfile requirement.
        let podAcceptedVersions: [Version]
        /// The range Podfile.swift declares for the package; nil for packages that are only indirect.
        let podfileRequirement: Requirement?
        let unsafeOverrideReason: String?
    }

    static func unify(pods: [PodCandidate], packages: [PackageCandidate]) throws(PodsError) -> [Unification] {
        // Package index → pods identified as the same library.
        var podsByPackage: [Int: [PodCandidate]] = [:]
        for pod in pods {
            let podCommits = Set(pod.commits.values)
            let matches = packages.indices.filter { index in
                let package = packages[index]
                return package.commits.values.contains(where: podCommits.contains)
                    || pod.repository.map { normalize($0) == normalize(package.url) } == true
            }
            guard let match = matches.first else { continue }
            guard matches.count == 1 else {
                throw PodsError(
                    "Pod '\(pod.root)' matches several Swift packages: "
                        + matches.map { packages[$0].url }.sorted().joined(separator: ", ")
                )
            }
            podsByPackage[match, default: []].append(pod)
        }

        var unifications: [Unification] = []
        // Sorted so that the first error reported does not depend on dictionary order.
        for (index, matchedPods) in podsByPackage.sorted(by: { packages[$0.key].url < packages[$1.key].url }) {
            let package = packages[index]
            // Several pods built from one package (a monorepo) would need every product of the package mapped to its pod.
            guard matchedPods.count == 1, let pod = matchedPods.first else {
                throw PodsError(
                    "Pods " + matchedPods.map { "'\($0.root)'" }.sorted().joined(separator: ", ")
                        + " are all the same library as Swift package \(package.url); "
                        + "unifying several pods with one package is not supported yet."
                )
            }
            // Commits the pod accepts: those of its versions that satisfy every requirement on it.
            let acceptedCommits = Set(pod.commits.filter { version, _ in
                pod.requirements.allSatisfy { $0.requirement.isSatisfied(by: version) }
            }.values)
            let tagged = package.commits.keys.filter { !$0.isPreRelease }.sorted()
            let withinPodfile = tagged.filter { package.podfileRequirement?.isSatisfied(by: $0) != false }
            let podAccepted = withinPodfile.filter { acceptedCommits.contains(package.commits[$0]!) }
            let allowed: [Version]
            let bounds: (lower: Version, upper: Version)
            if package.unsafeOverrideReason != nil, let podfileRequirement = package.podfileRequirement {
                allowed = withinPodfile
                // Resolved within the declared range, not narrowed.
                bounds = try SwiftPackageResolver.range(of: podfileRequirement, url: package.url)
            } else {
                guard let lowest = podAccepted.first, let highest = podAccepted.last else {
                    throw conflict(pod: pod, package: package)
                }
                allowed = podAccepted
                bounds = (lowest, Version(highest.major, highest.minor, highest.patch + 1))
            }
            unifications.append(Unification(
                podRoot: pod.root,
                packageURL: package.url,
                allowedVersions: allowed,
                lowerBound: bounds.lower,
                upperBound: bounds.upper,
                allowedCommits: Set(allowed.compactMap { package.commits[$0] }),
                taggedVersions: tagged,
                podAcceptedVersions: podAccepted,
                podfileRequirement: package.podfileRequirement,
                unsafeOverrideReason: package.unsafeOverrideReason
            ))
        }
        return unifications.sorted { $0.podRoot < $1.podRoot }
    }

    /// Checks the version and revision chosen by SwiftPM's second resolution.
    /// The revision is checked too because a tag may have been moved since the tags were listed.
    static func verify(_ unification: Unification, resolved: Version, revision: String) throws(PodsError) {
        guard unification.allowedVersions.contains(resolved) else {
            throw PodsError(
                "Swift package \(unification.packageURL) resolved to \(resolved), which does not match the commit of any "
                    + "acceptable version of pod '\(unification.podRoot)'. Allowed versions: "
                    + unification.allowedVersions.map(\.description).joined(separator: ", ")
            )
        }
        guard unification.allowedCommits.contains(revision) else {
            throw PodsError(
                "Swift package \(unification.packageURL) resolved to \(resolved) at commit \(revision), which is not the commit "
                    + "of any acceptable version of pod '\(unification.podRoot)'."
            )
        }
    }

    /// The warning for a version that only an unsafe override allows; nil when the pod accepts `resolved` or there is no override.
    static func unsafeOverrideWarning(_ unification: Unification, pod: PodCandidate, resolved: Version) -> String? {
        guard let reason = unification.unsafeOverrideReason, let declared = unification.podfileRequirement,
              !unification.podAcceptedVersions.contains(resolved) else { return nil }
        let requirements = pod.requirements.map(\.requirement.description).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return "Swift package \(unification.packageURL) \(resolved) is outside the versions pod '\(pod.root)' accepts "
            + "(\(requirements.joined(separator: "; "))); the declared range \(declared) is allowed by an unsafe override in "
            + "Podfile.swift: \(reason). "
            + "ABI compatibility is not verified."
    }

    /// The second resolution only narrows ranges, but a narrowed version may depend on packages the first one did not have.
    /// Those were never matched against the pods, so a pod might be the same library and end up linked twice.
    static func verifyNoNewPackages(first: [SwiftPackageResolver.Pin], second: [SwiftPackageResolver.Pin]) throws(PodsError) {
        let known = Set(first.map(\.identity))
        let added = second.filter { !known.contains($0.identity) }.map(\.url).sorted()
        guard added.isEmpty else {
            throw PodsError(
                "Narrowing the Swift packages to the versions the pods accept brought in packages that were not matched "
                    + "against the pods: \(added.joined(separator: ", ")). Matching them again is not supported yet."
            )
        }
    }

    private static func conflict(pod: PodCandidate, package: PackageCandidate) -> PodsError {
        var lines = [
            "No version of Swift package \(package.url) satisfies every requirement on pod '\(pod.root)' "
                + "(only versions tagged at the same commit as an acceptable pod version are allowed):",
        ]
        for (origin, requirement) in pod.requirements {
            lines.append("  - \(origin) requires \(pod.root) \(describe(requirement))")
        }
        if let podfileRequirement = package.podfileRequirement {
            lines.append("  - Podfile.swift requires \(package.identity) \(describe(podfileRequirement))")
        }
        return PodsError(lines.joined(separator: "\n"))
    }

    private static func describe(_ requirement: Requirement) -> String {
        requirement.isAny ? "(any version)" : requirement.lockfileDescription
    }

    /// Lowercased, without a trailing `/` or `.git`, so that equivalent repository URLs compare equal.
    static func normalize(_ url: String) -> String {
        var result = url.lowercased()
        while result.hasSuffix("/") { result.removeLast() }
        if result.hasSuffix(".git") { result.removeLast(4) }
        return result
    }
}
