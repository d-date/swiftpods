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

    @Test func overriddenUnificationIsUnsafe() throws {
        let declared = try Requirement(parsing: ">= 3.5.0, < 6.0.0")
        let unification = PackageUnifier.Unification(
            podRoot: "GTMSessionFetcher",
            packageURL: "https://github.com/google/Gtm-Session-Fetcher.git",
            allowedVersions: versions("3.5.0", "5.0.0"),
            lowerBound: Version("3.5.0")!,
            upperBound: Version("6.0.0")!,
            allowedCommits: [],
            taggedVersions: versions("3.3.2", "3.5.0", "5.0.0"),
            podAcceptedVersions: versions("3.3.2", "3.5.0"),
            podfileRequirement: declared,
            unsafeOverrideReason: "r"
        )
        let result = try DistributionRequirement.forUnification(unification, pinned: Version("5.0.0")!, declared: declared)
        guard case let .unsafe(lower, upper, warning) = result else {
            Issue.record("expected .unsafe, got \(result)")
            return
        }
        #expect(lower == Version("3.5.0")!)
        #expect(upper == Version("6.0.0")!)
        #expect(warning.contains("unsafe"))
        #expect(warning.contains("Reason: r"))
        #expect(warning.contains("gtm-session-fetcher 3.5.0..<6.0.0"))
        #expect(warning.contains("GTMSessionFetcher accepts 3.3.2...3.5.0"))
    }
}
