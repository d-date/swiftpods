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
                upperBound: Version(3, 5, 1)
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

    @Test func rejectsResolvedVersionOutsideAllowedSet() throws {
        let unification = PackageUnifier.Unification(
            podRoot: "GoogleUtilities",
            packageURL: "https://github.com/google/GoogleUtilities.git",
            allowedVersions: [Version(8, 0, 0), Version(8, 2, 0)],
            lowerBound: Version(8, 0, 0),
            upperBound: Version(8, 2, 1)
        )
        #expect(throws: PodsError.self) {
            try PackageUnifier.verify(unification, resolved: Version(8, 1, 0))
        }
        try PackageUnifier.verify(unification, resolved: Version(8, 2, 0))
    }
}
