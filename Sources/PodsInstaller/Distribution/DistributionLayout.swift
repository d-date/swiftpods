/// The products and binary targets of a generated distribution Package.swift, derived from the pod graph.
struct DistributionLayout: Equatable, Sendable {
    struct Product: Equatable, Sendable {
        let name: String
        /// Targets of the product, excluding members of Common; the last one is always "Common".
        let targets: [String]
    }

    let products: [Product]
    /// Binary targets every product needs, sorted.
    let commonTargets: [String]
    /// Every binary target of any product, sorted.
    let binaryTargets: [String]
    /// Packages the Common target depends on, sorted.
    let unifiedPackageURLs: [String]
    let warnings: [String]

    /// - Parameters:
    ///   - declared: pod dependency names of the distribution target, in order (may be subspecs).
    ///   - dependencies: pod or subspec name to the pod or subspec names it depends on.
    ///   - podsWithBinary: roots that produce a binary (vendored framework or compiled sources).
    ///   - unified: pod root to package URL.
    static func derive(
        declared: [String],
        dependencies: [String: [String]],
        podsWithBinary: Set<String>,
        unified: [String: String]
    ) -> DistributionLayout {
        var warnings: [String] = []
        // Product name to the node names its closure starts from, in declaration order.
        var productStarts: [(name: String, starts: [String])] = []

        for dependency in declared {
            let root = rootName(dependency)
            guard dependency != root else {
                addProduct(root, starts: [dependency], to: &productStarts)
                continue
            }
            // Roots the subspec depends on directly, outside its own root.
            var edgesByRoot: [String: [String]] = [:]
            for target in dependencies[dependency] ?? [] {
                let targetRoot = rootName(target)
                if targetRoot != root, podsWithBinary.contains(targetRoot) { edgesByRoot[targetRoot, default: []].append(target) }
            }
            let roots = edgesByRoot.keys.sorted()
            if let first = roots.first {
                if roots.count > 1 {
                    warnings.append("\(dependency) depends on several binary pods (\(roots.joined(separator: ", "))); using \(first) as its product and ignoring \(roots.dropFirst().joined(separator: ", ")).")
                }
                addProduct(first, starts: edgesByRoot[first] ?? [], to: &productStarts)
            } else if podsWithBinary.contains(root) {
                addProduct(root, starts: [dependency], to: &productStarts)
            } else {
                warnings.append("\(dependency) has no binary target, so no product is generated for it.")
            }
        }

        var closures: [String: Set<String>] = [:]
        for (name, starts) in productStarts {
            let roots = Set(reachable(from: starts, dependencies: dependencies).map(rootName))
            let closure = roots.intersection(podsWithBinary)
            if closure.isEmpty {
                warnings.append("\(name) has no binary target, so no product is generated for it.")
            } else {
                closures[name] = closure
            }
        }
        let productNames = productStarts.map(\.name).filter { closures[$0] != nil }

        var common = closures.values.first ?? []
        for closure in closures.values { common.formIntersection(closure) }

        let products = productNames.map { name in
            let rest = closures[name, default: []].subtracting(common).subtracting([name]).sorted()
            return Product(name: name, targets: [name] + rest + ["Common"])
        }

        let reachableRoots = Set(reachable(from: declared, dependencies: dependencies).map(rootName))
        let urls = Set(reachableRoots.compactMap { unified[$0] })

        return DistributionLayout(
            products: products,
            commonTargets: common.sorted(),
            binaryTargets: closures.values.reduce(into: Set<String>()) { $0.formUnion($1) }.sorted(),
            unifiedPackageURLs: urls.sorted(),
            warnings: warnings
        )
    }

    private static func addProduct(_ name: String, starts: [String], to products: inout [(name: String, starts: [String])]) {
        if let index = products.firstIndex(where: { $0.name == name }) {
            products[index].starts += starts
        } else {
            products.append((name, starts))
        }
    }

    private static func rootName(_ name: String) -> String {
        name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? name
    }

    /// Every node name reachable from `starts` (inclusive), following subspec edges.
    private static func reachable(from starts: [String], dependencies: [String: [String]]) -> Set<String> {
        var seen = Set<String>()
        var pending = starts
        while let node = pending.popLast() {
            guard seen.insert(node).inserted else { continue }
            pending += dependencies[node] ?? []
        }
        return seen
    }
}
