import PodsCore
import PodsSpec

/// Chooses the library products of a Swift package that hold the code a pod's activated specs compile, so that a pod
/// unified with a package links what the pod would have built and nothing more (no test helpers, no optional parts
/// pulling in other system frameworks).
enum PackageProductSelector {
    /// The source files of each spec in `specs` (with their parents' inherited patterns) are matched against the files
    /// of the package's targets in its checkout. For each target holding some of them, the library product that lists it
    /// with the fewest targets (counting target dependencies, then listed targets) is chosen; a target no product lists
    /// must come with a chosen product's dependencies. Sorted by name.
    ///
    /// - Throws: when a spec with source files matches no target, or a matched target is in no chosen product.
    static func select(podRoot: String, specs: [Specification], platforms: [Platform.Name], package: PackageContents,
                       packageURL: String) throws(PodsError) -> [String] {
        let targetFiles = package.targets.map { (target: $0, files: package.files(of: $0)) }
        var needed = Set<String>()
        for spec in specs.sorted(by: { $0.name < $1.name }) {
            var sources = Set<String>()
            for platform in platforms {
                sources.formUnion(FileAccessor(root: package.checkout, specs: [spec], platform: platform).sourceFiles)
            }
            guard !sources.isEmpty else { continue }
            let matched = targetFiles.filter { !$0.files.isDisjoint(with: sources) }.map(\.target.name)
            guard !matched.isEmpty else {
                throw PodsError("No target of Swift package \(packageURL) holds the source files of `\(spec.name)`, so the package "
                    + "products that replace pod `\(podRoot)` cannot be chosen.")
            }
            needed.formUnion(matched)
        }

        let dependencies = Dictionary(package.targets.map { ($0.name, $0.dependencies) }, uniquingKeysWith: { first, _ in first })
        func closure(_ product: PackageContents.Product) -> Set<String> {
            var seen = Set<String>()
            var pending = product.targets
            while let target = pending.popLast() {
                guard seen.insert(target).inserted else { continue }
                pending += dependencies[target] ?? []
            }
            return seen
        }
        let products = package.libraryProducts.map { (product: $0, closure: closure($0)) }

        var chosen: [(product: PackageContents.Product, closure: Set<String>)] = []
        for target in needed.sorted() {
            let candidates = products.filter { $0.product.targets.contains(target) }
            guard let smallest = candidates.min(by: {
                ($0.closure.count, $0.product.targets.count, $0.product.name) < ($1.closure.count, $1.product.targets.count, $1.product.name)
            }) else { continue }
            if !chosen.contains(where: { $0.product.name == smallest.product.name }) { chosen.append(smallest) }
        }
        let covered = chosen.reduce(into: Set<String>()) { $0.formUnion($1.closure) }
        if let missing = needed.sorted().first(where: { !covered.contains($0) }) {
            throw PodsError("Target `\(missing)` of Swift package \(packageURL) holds sources of pod `\(podRoot)` but is in no library "
                + "product, so the pod cannot be replaced by the package.")
        }
        return chosen.map(\.product.name).sorted()
    }
}
