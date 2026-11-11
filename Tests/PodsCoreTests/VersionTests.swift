import PodsCore
import Testing

struct VersionTests {
    @Test(arguments: [
        ("1.0", "1.0.0"),
        ("1", "1.0.0.0"),
        ("2.0.0-beta.1", "2.0.0.beta.1"),
    ])
    func equivalentVersions(_ a: String, _ b: String) throws {
        let lhs = try #require(Version(a))
        let rhs = try #require(Version(b))
        #expect(lhs == rhs)
        #expect(lhs.hashValue == rhs.hashValue)
    }

    @Test(arguments: [
        ("1.0.0", "1.0.1"),
        ("1.9", "1.10"),
        ("2.0.0-beta", "2.0.0"),
        ("2.0.0-alpha", "2.0.0-beta"),
        ("2.0.0-beta.2", "2.0.0-beta.10"),
        ("2.0.0-1", "2.0.0-alpha"),
        ("1.0RC1", "1.0"),
    ])
    func ordering(_ smaller: String, _ larger: String) throws {
        #expect(try #require(Version(smaller)) < #require(Version(larger)))
    }

    @Test func parsesPreRelease() throws {
        let version = try #require(Version("1.2.3-beta.4+exp"))
        #expect(version.release == [1, 2, 3])
        #expect(version.preRelease == [.text("beta"), .number(4)])
        #expect(version.buildMetadata == "exp")
        #expect(version.isPreRelease)
    }

    @Test(arguments: ["", "abc", "1..2", "1.0-", "1.0-be ta"])
    func rejectsInvalid(_ string: String) {
        #expect(Version(string) == nil)
    }
}

struct RequirementTests {
    @Test(arguments: [
        ("~> 1.2", "1.2", true),
        ("~> 1.2", "1.9.9", true),
        ("~> 1.2", "2.0", false),
        ("~> 1.2.3", "1.2.9", true),
        ("~> 1.2.3", "1.3.0", false),
        ("~> 1.2.3", "1.2.2", false),
        ("~> 1", "1.9", true),
        ("~> 1", "2.0", false),
        ("~> 1.2", "2.0.0-beta", false),
        (">= 1.0, < 2.0", "1.5", true),
        (">= 1.0, < 2.0", "2.0", false),
        ("1.0", "1.0.0", true),
        ("!= 1.0", "1.0", false),
        ("<= 1.0", "0.9", true),
    ])
    func satisfaction(_ requirement: String, _ version: String, _ expected: Bool) throws {
        let parsed = try Requirement(parsing: requirement)
        #expect(parsed.isSatisfied(by: try #require(Version(version))) == expected)
    }

    @Test func invalidRequirementThrowsTypedError() {
        #expect(throws: Requirement.ParseError.invalid("~> x")) {
            try Requirement(parsing: "~> x")
        }
    }

    @Test func lockfileDescription() throws {
        #expect(try Requirement(parsing: "~> 5.0").lockfileDescription == "(~> 5.0)")
        #expect(Requirement.any.lockfileDescription == "")
    }
}

struct DependencyTests {
    @Test func rootName() {
        #expect(Dependency(name: "Firebase/Analytics").rootName == "Firebase")
        #expect(Dependency(name: "Alamofire").rootName == "Alamofire")
    }

    @Test func lockfileDescriptions() throws {
        let git = Dependency(name: "Foo", externalSource: .git(url: "https://x/foo.git", reference: .tag("1.0")))
        #expect(git.lockfileDescription == "Foo (from `https://x/foo.git`, tag `1.0`)")
        let path = Dependency(name: "Bar", externalSource: .path("../Bar"))
        #expect(path.lockfileDescription == "Bar (from `../Bar`)")
        let versioned = Dependency(name: "Baz", requirement: try Requirement(parsing: "~> 2.1"))
        #expect(versioned.lockfileDescription == "Baz (~> 2.1)")
    }

    @Test func externalSourceRoundTrip() {
        let source = ExternalSource.git(url: "u", reference: .branch("main"))
        let entries = Dictionary(uniqueKeysWithValues: source.lockfileEntries.map { ($0.key, $0.value) })
        #expect(ExternalSource(entries: entries) == source)
    }
}

struct ShellTests {
    @Test func capturesOutput() async throws {
        let output = try await Shell().run("echo", ["hello"])
        #expect(output.stdout == "hello\n")
    }

    @Test func throwsOnFailure() async {
        await #expect(throws: Shell.Failure.self) {
            try await Shell().run("false", [])
        }
    }
}
