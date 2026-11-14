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
    }

    struct Unification: Sendable, Equatable {
        let podRoot: String
        let packageURL: String
        /// Ascending.
        let allowedVersions: [Version]
        let lowerBound: Version
        /// Exclusive: the highest allowed version with its patch component + 1.
        let upperBound: Version
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
        for (index, matchedPods) in podsByPackage {
            let package = packages[index]
            // Commits each pod accepts: those of its versions that satisfy every requirement on it.
            let acceptedCommits = matchedPods.map { pod in
                Set(pod.commits.filter { version, _ in
                    pod.requirements.allSatisfy { $0.requirement.isSatisfied(by: version) }
                }.values)
            }
            let allowed = package.commits
                .filter { version, commit in
                    !version.isPreRelease
                        && package.podfileRequirement?.isSatisfied(by: version) != false
                        && acceptedCommits.allSatisfy { $0.contains(commit) }
                }
                .keys
                .sorted()
            guard let lowest = allowed.first, let highest = allowed.last else {
                throw conflict(pods: matchedPods, package: package)
            }
            for pod in matchedPods {
                unifications.append(Unification(
                    podRoot: pod.root,
                    packageURL: package.url,
                    allowedVersions: allowed,
                    lowerBound: lowest,
                    upperBound: Version(highest.major, highest.minor, highest.patch + 1)
                ))
            }
        }
        return unifications.sorted { $0.podRoot < $1.podRoot }
    }

    /// Checks the version chosen by SwiftPM's second resolution.
    static func verify(_ unification: Unification, resolved: Version) throws(PodsError) {
        guard unification.allowedVersions.contains(resolved) else {
            throw PodsError(
                "Swift package \(unification.packageURL) resolved to \(resolved), which does not match the commit of any "
                    + "acceptable version of pod '\(unification.podRoot)'. Allowed versions: "
                    + unification.allowedVersions.map(\.description).joined(separator: ", ")
            )
        }
    }

    private static func conflict(pods: [PodCandidate], package: PackageCandidate) -> PodsError {
        let roots = pods.map { "'\($0.root)'" }.sorted().joined(separator: ", ")
        var lines = [
            "No version of Swift package \(package.url) satisfies every requirement on pod \(roots) "
                + "(only versions tagged at the same commit as an acceptable pod version are allowed):",
        ]
        for pod in pods.sorted(by: { $0.root < $1.root }) {
            for (origin, requirement) in pod.requirements {
                lines.append("  - \(origin) requires \(pod.root) \(describe(requirement))")
            }
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
    private static func normalize(_ url: String) -> String {
        var result = url.lowercased()
        while result.hasSuffix("/") { result.removeLast() }
        if result.hasSuffix(".git") { result.removeLast(4) }
        return result
    }
}
