import Foundation
import PodsCore

/// What a resolved Swift package contains, read from `swift package dump-package` of its checkout.
struct PackageContents: Sendable {
    struct Target: Sendable, Equatable {
        let name: String
        /// Relative to the checkout; `nil` for SwiftPM's default (`Sources/<name>` and the like).
        let path: String?
        /// Relative to the target's directory; `nil` for every file in it.
        let sources: [String]?
        /// Relative to the target's directory.
        let exclude: [String]
        /// Targets of the same package this one depends on.
        let dependencies: [String]
    }

    struct Product: Sendable, Equatable {
        let name: String
        let targets: [String]
    }

    let checkout: URL
    /// Library targets (`regular`); test, executable, plugin and binary targets are left out.
    let targets: [Target]
    let libraryProducts: [Product]

    init(checkout: URL, targets: [Target], libraryProducts: [Product]) {
        self.checkout = checkout
        self.targets = targets
        self.libraryProducts = libraryProducts
    }

    init(dump: JSON, checkout: URL) {
        let allTargets = dump["targets"]?.array ?? []
        let localNames = Set(allTargets.compactMap { $0["name"]?.string })
        let targets = allTargets.compactMap { target -> Target? in
            guard target["type"]?.string == "regular", let name = target["name"]?.string else { return nil }
            // `byName` names a target of the package or a product of a dependency; `target` always names a target.
            let dependencies = (target["dependencies"]?.array ?? []).compactMap { dependency -> String? in
                let name = (dependency["byName"] ?? dependency["target"])?.array?.first?.string
                return name.flatMap { localNames.contains($0) ? $0 : nil }
            }
            return Target(name: name, path: target["path"]?.string, sources: target["sources"]?.array?.compactMap(\.string),
                          exclude: target["exclude"]?.stringList ?? [], dependencies: dependencies)
        }
        let products = (dump["products"]?.array ?? []).compactMap { product -> Product? in
            guard product["type"]?["library"] != nil, let name = product["name"]?.string else { return nil }
            return Product(name: name, targets: product["targets"]?.stringList ?? [])
        }
        self.init(checkout: checkout, targets: targets, libraryProducts: products)
    }

    /// The files of `target`, relative to the checkout, as SwiftPM would collect them (resources included).
    func files(of target: Target) -> Set<String> {
        let fileManager = FileManager.default
        let directory: String
        if let path = target.path {
            directory = Self.normalize(path)
        } else {
            // SwiftPM's predefined source directories.
            let candidates = ["Sources", "Source", "src", "srcs"].map { "\($0)/\(target.name)" }
            guard let found = candidates.first(where: { fileManager.fileExists(atPath: checkout.appendingPathComponent($0).path) }) else { return [] }
            directory = found
        }
        func join(_ base: String, _ path: String) -> String { Self.normalize(base.isEmpty ? path : base + "/" + path) }
        let excluded = target.exclude.map { join(directory, $0) }
        func isExcluded(_ path: String) -> Bool {
            excluded.contains { path == $0 || $0.isEmpty || path.hasPrefix($0 + "/") }
        }

        var result = Set<String>()
        for root in (target.sources ?? [""]).map({ join(directory, $0) }) {
            var isDirectory: ObjCBool = false
            let url = root.isEmpty ? checkout : checkout.appendingPathComponent(root)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                if !isExcluded(root) { result.insert(root) }
                continue
            }
            for case let relative as String in fileManager.enumerator(atPath: url.path) ?? NSEnumerator() {
                let path = join(root, relative)
                var isSubdirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: checkout.appendingPathComponent(path).path, isDirectory: &isSubdirectory),
                      !isSubdirectory.boolValue, !isExcluded(path) else { continue }
                result.insert(path)
            }
        }
        return result
    }

    /// `path` without `.` and empty components, with `..` applied.
    private static func normalize(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") where component != "." {
            if component == "..", !components.isEmpty { components.removeLast() } else { components.append(component) }
        }
        return components.joined(separator: "/")
    }
}
