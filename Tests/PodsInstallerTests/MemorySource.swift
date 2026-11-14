import PodsCore
import PodsSources
import PodsSpec

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
