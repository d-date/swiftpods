import PodsCore
@testable import PodsInstaller
import Testing

struct DistributionRequirementTests {
    func versions(_ strings: String...) -> [Version] {
        strings.map { Version($0)! }
    }

    @Test func singleAllowedVersionIsExact() throws {
        let result = try DistributionRequirement.narrowed(
            allowed: versions("2.30910.0"),
            tagged: versions("2.30909.0", "2.30910.0", "2.30910.1"),
            pinned: Version("2.30910.0")!
        )
        #expect(result == .exact(Version("2.30910.0")!))
    }

    @Test func narrowsToRunContainingPin() throws {
        let result = try DistributionRequirement.narrowed(
            allowed: versions("1.0.0", "1.0.1", "1.0.3", "1.0.4"),
            tagged: versions("1.0.0", "1.0.1", "1.0.2", "1.0.3", "1.0.4", "1.0.5"),
            pinned: Version("1.0.4")!
        )
        #expect(result == .closedRange(Version("1.0.3")!, Version("1.0.4")!))
    }

    @Test func runSpansAllowedTail() throws {
        let tagged = versions("8.0.0", "8.1.0", "8.1.4", "8.1.5")
        let result = try DistributionRequirement.narrowed(allowed: tagged, tagged: tagged, pinned: Version("8.1.5")!)
        #expect(result == .closedRange(Version("8.0.0")!, Version("8.1.5")!))
    }

    @Test func pinOutsideAllowedThrows() {
        #expect(throws: PodsError.self) {
            try DistributionRequirement.narrowed(
                allowed: versions("1.0.0"),
                tagged: versions("1.0.0", "1.0.1"),
                pinned: Version("1.0.1")!
            )
        }
    }

    func gtmUnification(declared: Requirement, podAccepted: [Version]) -> PackageUnifier.Unification {
        PackageUnifier.Unification(
            podRoot: "GTMSessionFetcher",
            packageURL: "https://github.com/google/Gtm-Session-Fetcher.git",
            allowedVersions: versions("3.5.0", "5.0.0"),
            lowerBound: Version("3.5.0")!,
            upperBound: Version("6.0.0")!,
            allowedCommits: [],
            taggedVersions: versions("3.3.2", "3.5.0", "5.0.0"),
            podAcceptedVersions: podAccepted,
            podfileRequirement: declared,
            unsafeOverrideReason: "r",
            podRequirements: ["< 4.0, >= 3.3", "~> 3.4"]
        )
    }

    @Test func overriddenUnificationIsUnsafe() throws {
        let declared = try Requirement(parsing: ">= 3.5.0, < 6.0.0")
        let unification = gtmUnification(declared: declared, podAccepted: versions("3.3.2", "3.5.0"))
        let result = try DistributionRequirement.forUnification(unification, pinned: Version("5.0.0")!, declared: declared)
        guard case let .unsafe(lower, upper, warning) = result else {
            Issue.record("expected .unsafe, got \(result)")
            return
        }
        #expect(lower == Version("3.5.0")!)
        #expect(upper == Version("6.0.0")!)
        #expect(warning.contains("unsafe"))
        #expect(warning.contains("Reason: r"))
        #expect(warning.contains("gtm-session-fetcher 3.5.0..<6.0.0 may be outside the versions the pods accept"))
        // The pods' own requirements, not the package versions they were matched to.
        #expect(warning.contains("the pods require GTMSessionFetcher < 4.0, >= 3.3; ~> 3.4"))
        #expect(!warning.contains("3.3.2"))
    }

    /// An override whose range only holds versions the pods accept is still flagged, without claiming it leaves them.
    @Test func overrideWithinAcceptedVersions() throws {
        let declared = try Requirement(parsing: ">= 3.5.0, < 6.0.0")
        let unification = gtmUnification(declared: declared, podAccepted: versions("3.3.2", "3.5.0", "5.0.0"))
        let result = try DistributionRequirement.forUnification(unification, pinned: Version("5.0.0")!, declared: declared)
        guard case let .unsafe(_, _, warning) = result else {
            Issue.record("expected .unsafe, got \(result)")
            return
        }
        #expect(!warning.contains("outside"))
        #expect(warning.contains("gtm-session-fetcher 3.5.0..<6.0.0"))
        #expect(warning.contains("the pods require GTMSessionFetcher < 4.0, >= 3.3; ~> 3.4"))
        #expect(warning.contains("Reason: r"))
    }

    /// Without an override, the requirement is the run of accepted versions around the pinned one.
    @Test func unificationWithoutOverrideIsNarrowed() throws {
        let unification = PackageUnifier.Unification(
            podRoot: "GoogleUtilities",
            packageURL: "https://github.com/google/GoogleUtilities.git",
            allowedVersions: versions("8.0.0", "8.1.0", "8.2.0"),
            lowerBound: Version("8.0.0")!,
            upperBound: Version("8.2.1")!,
            allowedCommits: [],
            taggedVersions: versions("7.0.0", "8.0.0", "8.1.0", "8.1.5", "8.2.0"),
            podAcceptedVersions: versions("8.0.0", "8.1.0", "8.2.0"),
            podfileRequirement: try Requirement(parsing: ">= 8.0.0, < 9.0.0"),
            unsafeOverrideReason: nil
        )
        let result = try DistributionRequirement.forUnification(unification, pinned: Version("8.1.0")!,
                                                                declared: unification.podfileRequirement)
        #expect(result == .closedRange(Version("8.0.0")!, Version("8.1.0")!))
    }
}
