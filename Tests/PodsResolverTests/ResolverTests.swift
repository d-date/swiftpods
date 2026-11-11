import PodsCore
import PodsSources
import PodsSpec
@testable import PodsResolver
import Testing

/// An in-memory spec source built from compact JSON specs.
struct MemorySource: SpecSource {
    let url = "memory"
    let lockfileName = "trunk"
    let specs: [String: [Version: Specification]]

    init(_ jsonSpecs: [String]) throws {
        var specs: [String: [Version: Specification]] = [:]
        for json in jsonSpecs {
            let spec = try Specification(json: try JSON(parsing: json))
            specs[spec.name, default: [:]][spec.version] = spec
        }
        self.specs = specs
    }

    func versions(of name: String) async throws -> [Version] { Array(specs[name]?.keys ?? [:].keys) }
    func specification(of name: String, version: Version) async throws -> Specification {
        guard let spec = specs[name]?[version] else { throw PodsError("missing \(name) \(version)") }
        return spec
    }
    func update() async throws {}
}

func spec(_ name: String, _ version: String, dependencies: [String: [String]] = [:], extra: String = "") -> String {
    let deps = dependencies.map { "\"\($0.key)\": [\($0.value.map { "\"\($0)\"" }.joined(separator: ","))]" }.joined(separator: ",")
    return #"{"name":"\#(name)","version":"\#(version)","platforms":{"ios":"12.0"},"dependencies":{\#(deps)}\#(extra)}"#
}

let iOS15: Set<Platform> = [Platform(.ios, Version(15, 0))]

func root(_ name: String, _ requirement: String? = nil) throws -> RootRequirement {
    RootRequirement(dependency: Dependency(name: name, requirement: try requirement.map { try Requirement(parsing: $0) } ?? .any), platforms: iOS15)
}

struct ResolverTests {
    @Test func picksNewestSatisfyingVersions() async throws {
        let source = try MemorySource([
            spec("Moya", "15.0.0", dependencies: ["Alamofire": ["~> 5.0"]]),
            spec("Alamofire", "4.9.0"), spec("Alamofire", "5.8.0"), spec("Alamofire", "5.9.1"),
            spec("Alamofire", "6.0.0-beta.1"),
        ])
        let resolved = try await Resolver(sources: SourcesManager(sources: [source])).resolve([try root("Moya")])
        #expect(resolved.map { "\($0.name) \($0.version)" } == ["Alamofire 5.9.1", "Moya 15.0.0"])
    }

    @Test func backtracksOnConflicts() async throws {
        // B 2.0 needs C ~> 2, but A needs C ~> 1, so B must fall back to 1.0.
        let source = try MemorySource([
            spec("A", "1.0", dependencies: ["C": ["~> 1.0"]]),
            spec("B", "1.0", dependencies: ["C": ["~> 1.0"]]),
            spec("B", "2.0", dependencies: ["C": ["~> 2.0"]]),
            spec("C", "1.5"), spec("C", "2.1"),
        ])
        let resolved = try await Resolver(sources: SourcesManager(sources: [source])).resolve([try root("B"), try root("A")])
        #expect(resolved.map { "\($0.name) \($0.version)" } == ["A 1.0", "B 1.0", "C 1.5"])
    }

    @Test func keepsLockedVersionsUnlessUpdating() async throws {
        let source = try MemorySource([spec("Alamofire", "5.8.0"), spec("Alamofire", "5.9.1")])
        let manager = SourcesManager(sources: [source])
        let locked = ["Alamofire": Version(5, 8, 0)]
        let install = try await Resolver(sources: manager, lockedVersions: locked).resolve([try root("Alamofire", "~> 5.0")])
        #expect(install.first?.version == Version(5, 8, 0))
        let update = try await Resolver(sources: manager, lockedVersions: locked, unlockedPods: nil).resolve([try root("Alamofire", "~> 5.0")])
        #expect(update.first?.version == Version(5, 9, 1))
        let updateOther = try await Resolver(sources: manager, lockedVersions: locked, unlockedPods: ["Other"]).resolve([try root("Alamofire")])
        #expect(updateOther.first?.version == Version(5, 8, 0))
    }

    @Test func activatesSubspecsAndDefaultSubspecs() async throws {
        let firebase = #"""
        {"name":"Firebase","version":"11.0.0","platforms":{"ios":"12.0"},"default_subspecs":"Core",
         "subspecs":[
           {"name":"CoreOnly","dependencies":{"FirebaseCore":["= 11.0.0"]}},
           {"name":"Core","dependencies":{"Firebase/CoreOnly":[]}},
           {"name":"Analytics","dependencies":{"Firebase/Core":[]}}
         ]}
        """#
        let source = try MemorySource([firebase, spec("FirebaseCore", "11.0.0")])
        let resolved = try await Resolver(sources: SourcesManager(sources: [source])).resolve([try root("Firebase")])
        let pod = try #require(resolved.first { $0.name == "Firebase" })
        #expect(pod.activatedSpecs == ["Firebase", "Firebase/Core", "Firebase/CoreOnly"])
        #expect(resolved.map(\.name) == ["Firebase", "FirebaseCore"])
    }

    @Test func rejectsUnsupportedPlatforms() async throws {
        let source = try MemorySource([spec("New", "2.0", extra: #","platforms":{"ios":"17.0"}"#), spec("New", "1.0")])
        // Duplicate "platforms" key: the last one wins, so 2.0 needs iOS 17.
        let resolved = try await Resolver(sources: SourcesManager(sources: [source])).resolve([try root("New")])
        #expect(resolved.first?.version == Version(1, 0))
    }

    @Test func explainsConflicts() async throws {
        let source = try MemorySource([spec("A", "1.0", dependencies: ["C": ["~> 2.0"]]), spec("C", "1.0")])
        do {
            _ = try await Resolver(sources: SourcesManager(sources: [source])).resolve([try root("A"), try root("C", "~> 1.0")])
            Issue.record("Expected a resolution error")
        } catch let error as ResolutionError {
            #expect(error.message.contains("`C`"))
            #expect(error.message.contains("required by `A (1.0)`"))
        }
    }

    @Test func externalSpecsWin() async throws {
        let local = try Specification(json: try JSON(parsing: spec("MyKit", "0.1.0", dependencies: ["Alamofire": ["~> 5.0"]])))
        let source = try MemorySource([spec("MyKit", "9.0.0"), spec("Alamofire", "5.9.1")])
        let dependency = Dependency(name: "MyKit", externalSource: .path("../MyKit"))
        let resolved = try await Resolver(sources: SourcesManager(sources: [source]), externalSpecs: ["MyKit": local])
            .resolve([RootRequirement(dependency: dependency, platforms: iOS15)])
        #expect(resolved.map { "\($0.name) \($0.version)" } == ["Alamofire 5.9.1", "MyKit 0.1.0"])
    }
}
