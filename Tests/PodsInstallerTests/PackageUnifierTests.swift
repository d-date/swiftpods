import PodsCore
@testable import PodsInstaller
import Testing

struct PackageUnifierTests {
    let gtmURL = "https://github.com/google/gtm-session-fetcher.git"

    func gtmPod() throws -> PackageUnifier.PodCandidate {
        PackageUnifier.PodCandidate(
            root: "GTMSessionFetcher",
            requirements: [(origin: "MLKitCommon", requirement: try Requirement(parsing: ">= 3.3.2, < 4.0"))],
            commits: [Version(3, 3, 2): "c1", Version(3, 5, 0): "c2", Version(4, 0, 0): "c3"],
            repository: "https://github.com/google/gtm-session-fetcher"
        )
    }

    func gtmPackage(podfileRequirement: Requirement? = nil) -> PackageUnifier.PackageCandidate {
        PackageUnifier.PackageCandidate(
            url: gtmURL,
            identity: "gtm-session-fetcher",
            podfileRequirement: podfileRequirement,
            commits: [Version(3, 3, 2): "c1", Version(3, 5, 0): "c2", Version(4, 0, 0): "c3"]
        )
    }

    @Test func narrowsGTMSessionFetcherToBinaryRequirement() throws {
        let result = try PackageUnifier.unify(pods: [try gtmPod()], packages: [gtmPackage()])
        #expect(result == [
            PackageUnifier.Unification(
                podRoot: "GTMSessionFetcher",
                packageURL: gtmURL,
                allowedVersions: [Version(3, 3, 2), Version(3, 5, 0)],
                lowerBound: Version(3, 3, 2),
                upperBound: Version(3, 5, 1),
                allowedCommits: ["c1", "c2"],
                taggedVersions: [Version(3, 3, 2), Version(3, 5, 0), Version(4, 0, 0)],
                podAcceptedVersions: [Version(3, 3, 2), Version(3, 5, 0)],
                podfileRequirement: nil,
                unsafeOverrideReason: nil
            ),
        ])
    }

    @Test func mapsNanopbAcrossVersionSchemes() throws {
        let pod = PackageUnifier.PodCandidate(
            root: "nanopb",
            requirements: [(origin: "GoogleDataTransport", requirement: try Requirement(parsing: ">= 3.30910.0, < 3.30911.0"))],
            commits: [Version(3, 30910, 0): "b7e1"],
            repository: "https://github.com/nanopb/nanopb"
        )
        let package = PackageUnifier.PackageCandidate(
            url: "https://github.com/firebase/nanopb.git",
            identity: "nanopb",
            podfileRequirement: nil,
            commits: [Version(2, 30910, 0): "b7e1"]
        )
        let result = try PackageUnifier.unify(pods: [pod], packages: [package])
        #expect(result.map(\.allowedVersions) == [[Version(2, 30910, 0)]])
        #expect(result.first?.lowerBound == Version(2, 30910, 0))
        #expect(result.first?.upperBound == Version(2, 30910, 1))
    }

    @Test func reportsConflictWithPodfileRequirement() throws {
        let package = gtmPackage(podfileRequirement: try Requirement(parsing: ">= 4.0.0, < 6.0.0"))
        let pod = try gtmPod()
        let error = #expect(throws: PodsError.self) {
            try PackageUnifier.unify(pods: [pod], packages: [package])
        }
        let message = error?.message ?? ""
        #expect(message.contains("MLKitCommon"))
        #expect(message.contains("< 4.0, >= 3.3.2"))
        #expect(message.contains("gtm-session-fetcher"))
        #expect(message.contains("< 6.0.0, >= 4.0.0"))
    }

    @Test func skipsPodCommitsWithoutMatchingTag() throws {
        let pod = PackageUnifier.PodCandidate(
            root: "GoogleUtilities",
            requirements: [(origin: "MLKitCommon", requirement: try Requirement(parsing: "~> 8.0"))],
            commits: [Version(8, 1, 0): "cX", Version(8, 0, 0): "c0"],
            repository: nil
        )
        let package = PackageUnifier.PackageCandidate(
            url: "https://github.com/google/GoogleUtilities.git",
            identity: "googleutilities",
            podfileRequirement: nil,
            commits: [Version(8, 1, 0): "cY", Version(8, 0, 0): "c0"]
        )
        let result = try PackageUnifier.unify(pods: [pod], packages: [package])
        #expect(result.map(\.allowedVersions) == [[Version(8, 0, 0)]])
    }

    @Test func leavesUnrelatedPodsAlone() throws {
        let pod = PackageUnifier.PodCandidate(
            root: "SSZipArchive",
            requirements: [(origin: "MLKitCommon", requirement: try Requirement(parsing: "~> 2.2"))],
            commits: [Version(2, 4, 3): "z1"],
            repository: "https://github.com/ZipArchive/ZipArchive"
        )
        #expect(try PackageUnifier.unify(pods: [pod], packages: [gtmPackage()]).isEmpty)
    }

    @Test func matchesByRepositoryWhenCommitsDiffer() throws {
        let pod = PackageUnifier.PodCandidate(
            root: "GTMSessionFetcher",
            requirements: [(origin: "MLKitCommon", requirement: try Requirement(parsing: ">= 3.3.2, < 4.0"))],
            commits: [Version(3, 3, 2): "p1"],
            repository: "https://GitHub.com/google/gtm-session-fetcher/"
        )
        // Same library, but no SwiftPM tag shares a commit with an acceptable pod version.
        #expect(throws: PodsError.self) {
            try PackageUnifier.unify(pods: [pod], packages: [gtmPackage()])
        }
    }

    @Test func rejectsPodMatchingSeveralPackages() throws {
        let mirror = PackageUnifier.PackageCandidate(
            url: "https://example.com/mirror/gtm-session-fetcher.git",
            identity: "gtm-session-fetcher-mirror",
            podfileRequirement: nil,
            commits: [Version(3, 5, 0): "c2"]
        )
        #expect(throws: PodsError.self) {
            try PackageUnifier.unify(pods: [try gtmPod()], packages: [gtmPackage(), mirror])
        }
    }

    @Test func sortsUnificationsByPodRoot() throws {
        let other = PackageUnifier.PodCandidate(
            root: "PromisesObjC",
            requirements: [(origin: "GoogleUtilities", requirement: .any)],
            commits: [Version(2, 4, 0): "p24"],
            repository: nil
        )
        let promises = PackageUnifier.PackageCandidate(
            url: "https://github.com/google/promises.git",
            identity: "promises",
            podfileRequirement: nil,
            commits: [Version(2, 4, 0): "p24"]
        )
        let result = try PackageUnifier.unify(pods: [other, try gtmPod()], packages: [promises, gtmPackage()])
        #expect(result.map(\.podRoot) == ["GTMSessionFetcher", "PromisesObjC"])
    }

    @Test func identifiesPodByOutOfRangeCommitAndRejectsIt() throws {
        // Only 9.0.0 shares a commit with the package, and it is outside the requirement.
        let pod = PackageUnifier.PodCandidate(
            root: "GoogleUtilities",
            requirements: [(origin: "MLKitCommon", requirement: try Requirement(parsing: "~> 8.0"))],
            commits: [Version(8, 1, 0): "cX", Version(9, 0, 0): "c9"],
            repository: nil
        )
        let package = PackageUnifier.PackageCandidate(
            url: "https://github.com/google/GoogleUtilities.git",
            identity: "googleutilities",
            podfileRequirement: nil,
            commits: [Version(8, 1, 0): "cY", Version(9, 0, 0): "c9"]
        )
        let error = #expect(throws: PodsError.self) {
            try PackageUnifier.unify(pods: [pod], packages: [package])
        }
        #expect(error?.message.contains("MLKitCommon requires GoogleUtilities (~> 8.0)") == true)
    }

    @Test func rejectsSeveralPodsMatchingOnePackage() throws {
        // A monorepo publishing several pods that are all one package: not supported yet.
        let package = PackageUnifier.PackageCandidate(
            url: "https://github.com/google/GoogleUtilities.git",
            identity: "googleutilities",
            podfileRequirement: nil,
            commits: [Version(8, 0, 0): "c0", Version(8, 1, 0): "c1"]
        )
        let commits = [Version(8, 0, 0): "c0", Version(8, 1, 0): "c1"]
        let logger = PackageUnifier.PodCandidate(
            root: "GoogleUtilitiesLogger",
            requirements: [(origin: "MLKitCommon", requirement: .any)],
            commits: commits,
            repository: nil
        )
        let environment = PackageUnifier.PodCandidate(
            root: "GoogleUtilitiesEnvironment",
            requirements: [(origin: "MLKitVision", requirement: .any)],
            commits: commits,
            repository: nil
        )
        let error = #expect(throws: PodsError.self) {
            try PackageUnifier.unify(pods: [logger, environment], packages: [package])
        }
        let message = error?.message ?? ""
        #expect(message.contains("'GoogleUtilitiesEnvironment', 'GoogleUtilitiesLogger'"))
        #expect(message.contains("GoogleUtilities.git"))
        #expect(message.contains("not supported yet"))
    }

    @Test func rejectsPackagesAddedBySecondResolution() throws {
        func pin(_ identity: String) -> SwiftPackageResolver.Pin {
            SwiftPackageResolver.Pin(identity: identity, url: "https://example.com/\(identity).git", version: Version(1, 0, 0), revision: "r")
        }
        try PackageUnifier.verifyNoNewPackages(first: [pin("a"), pin("b")], second: [pin("a")])
        let error = #expect(throws: PodsError.self) {
            try PackageUnifier.verifyNoNewPackages(first: [pin("a")], second: [pin("a"), pin("c")])
        }
        #expect(error?.message.contains("https://example.com/c.git") == true)
    }

    @Test func excludesPreReleasePackageVersions() throws {
        let pod = PackageUnifier.PodCandidate(
            root: "GoogleUtilities",
            requirements: [(origin: "MLKitCommon", requirement: .any)],
            commits: [Version(8, 0, 0): "c0", Version(8, 1, 0): "c1"],
            repository: nil
        )
        let package = PackageUnifier.PackageCandidate(
            url: "https://github.com/google/GoogleUtilities.git",
            identity: "googleutilities",
            podfileRequirement: nil,
            commits: [Version(8, 0, 0): "c0", Version("8.1.0-beta.1")!: "c1"]
        )
        let result = try PackageUnifier.unify(pods: [pod], packages: [package])
        #expect(result.map(\.allowedVersions) == [[Version(8, 0, 0)]])
    }

    @Test func rejectsResolvedVersionOutsideAllowedSet() throws {
        let unification = PackageUnifier.Unification(
            podRoot: "GoogleUtilities",
            packageURL: "https://github.com/google/GoogleUtilities.git",
            allowedVersions: [Version(8, 0, 0), Version(8, 2, 0)],
            lowerBound: Version(8, 0, 0),
            upperBound: Version(8, 2, 1),
            allowedCommits: ["c0", "c2"],
            taggedVersions: [Version(8, 0, 0), Version(8, 1, 0), Version(8, 2, 0)],
            podAcceptedVersions: [Version(8, 0, 0), Version(8, 2, 0)],
            podfileRequirement: nil,
            unsafeOverrideReason: nil
        )
        #expect(throws: PodsError.self) {
            try PackageUnifier.verify(unification, resolved: Version(8, 1, 0), revision: "c1")
        }
        try PackageUnifier.verify(unification, resolved: Version(8, 2, 0), revision: "c2")
    }

    @Test func rejectsResolvedRevisionOutsideAllowedCommits() throws {
        let unification = PackageUnifier.Unification(
            podRoot: "GoogleUtilities",
            packageURL: "https://github.com/google/GoogleUtilities.git",
            allowedVersions: [Version(8, 0, 0)],
            lowerBound: Version(8, 0, 0),
            upperBound: Version(8, 0, 1),
            allowedCommits: ["c0"],
            taggedVersions: [Version(8, 0, 0)],
            podAcceptedVersions: [Version(8, 0, 0)],
            podfileRequirement: nil,
            unsafeOverrideReason: nil
        )
        // The tag was moved to another commit after the tags were listed.
        let error = #expect(throws: PodsError.self) {
            try PackageUnifier.verify(unification, resolved: Version(8, 0, 0), revision: "moved")
        }
        #expect(error?.message.contains("moved") == true)
    }

    func overriddenLib(podCommits: [Version: String]) throws -> (PackageUnifier.PodCandidate, PackageUnifier.PackageCandidate) {
        let pod = PackageUnifier.PodCandidate(
            root: "Lib",
            requirements: [(origin: "Binary", requirement: try Requirement(parsing: "< 2.0"))],
            commits: podCommits,
            repository: "https://example.com/Lib"
        )
        let package = PackageUnifier.PackageCandidate(
            url: "https://example.com/Lib.git",
            identity: "lib",
            podfileRequirement: try Requirement(parsing: ">= 1.0.0, < 3.0.0"),
            commits: [Version(1, 0, 0): "c1", Version(2, 0, 0): "c2"],
            unsafeOverrideReason: "r"
        )
        return (pod, package)
    }

    @Test func overrideAllowsVersionsOutsidePodRange() throws {
        let (pod, package) = try overriddenLib(podCommits: [Version(1, 0, 0): "c1"])
        let u = try #require(try PackageUnifier.unify(pods: [pod], packages: [package]).first)
        #expect(u.allowedVersions == [Version(1, 0, 0), Version(2, 0, 0)])
        #expect(u.allowedCommits == ["c1", "c2"])
        #expect(u.podAcceptedVersions == [Version(1, 0, 0)])
        #expect(u.taggedVersions == [Version(1, 0, 0), Version(2, 0, 0)])
        #expect(u.unsafeOverrideReason == "r")
        // Resolved within the declared range, not narrowed to the allowed versions.
        #expect(u.lowerBound == Version(1, 0, 0))
        #expect(u.upperBound == Version(3, 0, 0))
        try PackageUnifier.verify(u, resolved: Version(2, 0, 0), revision: "c2")
    }

    @Test func overrideWithNoCommitMatchIsNotAConflict() throws {
        // The pod's only version accepted by `< 2.0` has no matching tag.
        let (pod, package) = try overriddenLib(podCommits: [Version(1, 5, 0): "cX"])
        let u = try #require(try PackageUnifier.unify(pods: [pod], packages: [package]).first)
        #expect(u.podAcceptedVersions == [])
        #expect(u.allowedVersions == [Version(1, 0, 0), Version(2, 0, 0)])
    }

    @Test func overrideWarningOnlyOutsidePodAcceptedVersions() throws {
        let (pod, package) = try overriddenLib(podCommits: [Version(1, 0, 0): "c1"])
        let u = try #require(try PackageUnifier.unify(pods: [pod], packages: [package]).first)
        #expect(PackageUnifier.unsafeOverrideWarning(u, pod: pod, resolved: Version(1, 0, 0)) == nil)
        #expect(PackageUnifier.unsafeOverrideWarning(u, pod: pod, resolved: Version(2, 0, 0)) ==
            "Swift package https://example.com/Lib.git 2.0.0 is outside the versions pod 'Lib' accepts (< 2.0); "
            + "the declared range >= 1.0.0, < 3.0.0 is allowed by an unsafe override in Podfile.swift: r. "
            + "ABI compatibility is not verified.")
        // Without an override there is never a warning.
        let strict = try #require(try PackageUnifier.unify(pods: [try gtmPod()], packages: [gtmPackage()]).first)
        #expect(PackageUnifier.unsafeOverrideWarning(strict, pod: try gtmPod(), resolved: Version(4, 0, 0)) == nil)
    }
}
