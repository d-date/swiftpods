import Foundation
import PodsCore
import PodsSpec

/// Finds the resource bundles a distribution ships next to its xcframeworks as `<Name>.bundle.zip`.
enum ResourceBundles {
    /// `Resources/<name>` of the pods with binaries, for each of their podspec `resource_bundles` keys, plus `*.bundle`
    /// directories nested up to two levels inside their vendored frameworks; deduplicated by bundle name
    /// (first wins, pods sorted by name, podspec bundles before nested ones).
    static func collect(pods: [InstalledPod], podsWithBinary: Set<String>) -> [(name: String, directory: URL)] {
        var seen = Set<String>()
        var result: [(name: String, directory: URL)] = []
        func add(_ name: String, _ directory: URL) {
            if seen.insert(name).inserted { result.append((name, directory)) }
        }
        let fileManager = FileManager.default

        for pod in pods.filter({ podsWithBinary.contains($0.name) }).sorted(by: { $0.name < $1.name }) {
            let specs = pod.activatedSpecs.compactMap { pod.spec.subspec(named: $0) }
            let consumers = (specs.isEmpty ? [pod.spec] : specs).map { $0.consumer(for: .ios) }

            for name in consumers.flatMap(\.resourceBundles).map(\.name) {
                let directory = pod.location.appendingPathComponent("Resources").appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    add(name, directory)
                }
            }

            let glob = Glob(root: pod.location)
            let frameworks = glob.match(consumers.flatMap(\.vendoredFrameworks), directoryExtensions: nil, in: glob.allPaths())
            for framework in frameworks {
                for bundle in nestedBundles(in: pod.location.appendingPathComponent(framework), depth: 2) {
                    add(bundle.deletingPathExtension().lastPathComponent, bundle)
                }
            }
        }
        return result
    }

    /// `*.bundle` directories at most `depth` levels below `directory`, sorted by path.
    private static func nestedBundles(in directory: URL, depth: Int) -> [URL] {
        guard depth > 0, let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [URL] = []
        for child in children.sorted(by: { $0.path < $1.path }) {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if child.pathExtension == "bundle" {
                found.append(child)
            } else {
                found += nestedBundles(in: child, depth: depth - 1)
            }
        }
        return found
    }
}
