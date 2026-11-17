import ArgumentParser
@testable import SwiftPodsCLI
import Testing

struct PackageCommandTests {
    /// The root command declares `version:`, whose built-in `--version` flag must not swallow the subcommand's option.
    @Test func parsesVersionOption() throws {
        let command = try SwiftPods.parseAsRoot(["package", "--version", "9.0.3"])

        let package = try #require(command as? Package)
        #expect(package.version == "9.0.3")
        #expect(package.output == nil)
        #expect(!package.skipVerification)
    }

    @Test func parsesOutputAndSkipVerification() throws {
        let command = try SwiftPods.parseAsRoot(["package", "--version", "1.0.0", "--output", "out", "--skip-verification"])

        let package = try #require(command as? Package)
        #expect(package.output == "out")
        #expect(package.skipVerification)
    }
}
