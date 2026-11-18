import Foundation
import PodsCore
import PodsPodfile
import PodsSpec

/// Turns an analysis into pod targets and aggregate targets.
struct TargetBuilder {
    let analysis: Analysis
    let podfileURL: URL
    let projectDirectory: URL

    private struct VariantKey: Hashable {
        let root: String
        let platform: Platform.Name
        let buildType: BuildType
    }

    private struct Variant {
        var specNames: Set<String> = []
        var deploymentTargets: [Version] = []
        var inhibitWarnings = false
    }

    func build() throws -> InstallationPlan {
        let pods = Dictionary(uniqueKeysWithValues: analysis.pods.map { ($0.name, $0) })
        let targets = analysis.podfile.resolvedTargets

        // 1. Which specs each user target needs, grouped into variants (pod × platform × build type).
        var variants: [VariantKey: Variant] = [:]
        var aggregateRoots: [String: [VariantKey]] = [:]
        for target in targets {
            let platform = analysis.targetPlatforms[target.name]!
            let closure = try specClosure(for: target.dependencies.map(\.dependency), platform: platform.name, pods: pods)
            let frameworkSettings = target.usesFrameworks
            var keys: [VariantKey] = []
            for (root, specNames) in closure.sorted(by: { $0.key < $1.key }) {
                guard let pod = pods[root] else { continue }
                var buildType = BuildType(frameworkSettings)
                if buildType == .dynamicFramework, pod.spec.isStaticFramework { buildType = .staticFramework }
                let key = VariantKey(root: root, platform: platform.name, buildType: buildType)
                variants[key, default: Variant()].specNames.formUnion(specNames)
                variants[key]!.deploymentTargets.append(platform.effectiveDeploymentTarget)
                let inhibit = target.inhibitAllWarnings || target.inhibitWarningsForPods.contains(root)
                    || target.dependencies.contains { $0.dependency.rootName == root && $0.inhibitWarnings == true }
                variants[key]!.inhibitWarnings = variants[key]!.inhibitWarnings || inhibit
                keys.append(key)
            }
            aggregateRoots[target.label] = keys
        }

        // 2. Name the variants: suffixes are only added when a pod has several variants.
        let names = variantNames(Array(variants.keys))

        // 3. Pod targets.
        var podTargets: [VariantKey: PodTarget] = [:]
        for (key, variant) in variants {
            let pod = pods[key.root]!
            let specs = variant.specNames.sorted().compactMap { pod.spec.subspec(named: $0) }.filter { $0.kind == .library }
            let minimum = variant.deploymentTargets.min() ?? Platform(key.platform).effectiveDeploymentTarget
            let platform = Platform(key.platform, max(minimum, pod.spec.deploymentTarget(for: key.platform) ?? minimum))
            let files = FileAccessor(root: pod.location, specs: specs, platform: key.platform)
            var dependencyRoots = Set<String>()
            for spec in specs {
                for dependency in spec.dependencies(for: key.platform) { dependencyRoots.insert(dependency.rootName) }
            }
            let packageProducts = try packageProducts(replacing: dependencyRoots)
            // The products are linked once, statically, by the aggregate target; a dynamic framework would need them too.
            if key.buildType == .dynamicFramework, !packageProducts.isEmpty {
                throw PodsError(
                    "`\(names[key]!)` depends on pods replaced by Swift packages (\(packageProducts.map(\.product).joined(separator: ", "))), "
                        + "which is not supported yet with dynamic frameworks. Use `use_frameworks! :linkage => :static` or static libraries."
                )
            }
            podTargets[key] = PodTarget(
                name: names[key]!, pod: pod, specs: specs, platform: platform, buildType: key.buildType,
                dependencyNames: [], inhibitWarnings: variant.inhibitWarnings,
                swiftVersion: files.usesSwift ? (pod.spec.swiftVersions.max()?.rawValue ?? "5.0") : nil,
                packageProducts: packageProducts,
                files: files
            )
        }
        // Dependencies between pod targets.
        for (key, target) in podTargets {
            var dependencyRoots = Set<String>()
            for spec in target.specs {
                for dependency in spec.dependencies(for: key.platform) where dependency.rootName != key.root {
                    dependencyRoots.insert(dependency.rootName)
                }
            }
            podTargets[key]!.dependencyNames = dependencyRoots.sorted().compactMap { root in
                podTargets[VariantKey(root: root, platform: key.platform, buildType: key.buildType)]?.name
                    ?? podTargets.first { $0.key.root == root && $0.key.platform == key.platform }?.value.name
            }
        }
        let byName = Dictionary(uniqueKeysWithValues: podTargets.values.map { ($0.name, $0) })

        // 4. Aggregate targets.
        var aggregates: [AggregateTarget] = []
        for target in targets {
            let names = topologicalOrder(aggregateRoots[target.label]!.compactMap { podTargets[$0]?.name }, targets: byName)
            let searchPathNames = target.searchPathsTargets.flatMap { label in
                aggregateRoots[label]?.compactMap { podTargets[$0]?.name } ?? []
            }
            let projectURL = analysis.targetProjects[target.name]
            let info = projectURL.flatMap { analysis.userProjects[$0] }
            // Pod targets only depend on package products; the aggregate links them, once.
            var products = names.flatMap { byName[$0]!.packageProducts }
            products += try packageProducts(replacing: Set(target.dependencies.map(\.dependency.rootName)))
            for product in target.packageProducts {
                guard let package = analysis.podfile.swiftPackages.first(where: { $0.identity == product.package.lowercased() }) else {
                    throw PodsError("Target `\(target.name)` uses product `\(product.name)` of undeclared Swift package `\(product.package)`.")
                }
                products.append(PackageProductRef(packageURL: package.url, product: product.name))
            }
            let buildType = BuildType(target.usesFrameworks)
            // The aggregate links the products statically; a dynamic `Pods-<Target>` framework is not supported yet.
            if buildType == .dynamicFramework, !products.isEmpty {
                throw PodsError(
                    "Target `\(target.name)` links Swift package products (\(products.map(\.product).joined(separator: ", "))), "
                        + "which is not supported yet with dynamic frameworks. Use `use_frameworks! :linkage => :static` or static libraries."
                )
            }
            aggregates.append(AggregateTarget(
                definition: target,
                platform: analysis.targetPlatforms[target.name]!,
                podTargetNames: names,
                searchPathPodTargetNames: searchPathNames.filter { !names.contains($0) },
                userProject: projectURL,
                clientRoot: projectURL?.deletingLastPathComponent() ?? projectDirectory,
                buildConfigurations: info?.configurations ?? ["Debug", "Release"],
                buildType: buildType,
                packageProducts: products.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            ))
        }

        return InstallationPlan(
            podfile: analysis.podfile, podfileURL: podfileURL, pods: analysis.pods,
            podTargets: topologicalOrder(byName.keys.sorted(), targets: byName).map { byName[$0]! },
            aggregateTargets: aggregates,
            swiftPackages: try packageReferences()
        )
    }

    // MARK: - Swift packages

    /// The roots of the final SwiftPM resolution: declared packages with their Podfile range, narrowed for unified ones,
    /// and the version that resolution pinned.
    private func packageReferences() throws -> [(url: String, lowerBound: Version, upperBound: Version, version: Version)] {
        guard let resolution = analysis.swiftPackages else { return [] }
        var references: [String: (url: String, lowerBound: Version, upperBound: Version)] = [:]
        for package in analysis.podfile.swiftPackages {
            let range = try SwiftPackageResolver.range(of: package.requirement, url: package.url)
            references[package.identity] = (package.url, range.lower, range.upper)
        }
        for unification in analysis.unifications {
            references[try packageIdentity(of: unification.packageURL)] = (unification.packageURL, unification.lowerBound, unification.upperBound)
        }
        return try references.sorted { $0.key < $1.key }.map { identity, reference in
            guard let pin = resolution.pins.first(where: { $0.identity == identity }) else {
                throw PodsError("Swift package \(reference.url) is missing from the resolved packages.")
            }
            return (reference.url, reference.lowerBound, reference.upperBound, pin.version)
        }
    }

    /// The products of the packages that replace the pods among `roots` (those holding the code of the pods' activated
    /// specs), ordered by pod.
    private func packageProducts(replacing roots: Set<String>) throws -> [PackageProductRef] {
        var result: [PackageProductRef] = []
        for unification in analysis.unifications where roots.contains(unification.podRoot) {
            let products = analysis.unifiedProducts[unification.podRoot] ?? []
            guard !products.isEmpty else {
                throw PodsError("No library product of Swift package \(unification.packageURL) holds the code of pod `\(unification.podRoot)`.")
            }
            for product in products {
                let reference = PackageProductRef(packageURL: unification.packageURL, product: product)
                if !result.contains(reference) { result.append(reference) }
            }
        }
        return result
    }

    /// SwiftPM identity of a package: declared packages keep the Podfile URL, indirect ones the pin's location.
    private func packageIdentity(of url: String) throws -> String {
        if let declared = analysis.podfile.swiftPackages.first(where: { $0.url == url }) { return declared.identity }
        guard let pin = analysis.swiftPackages?.pins.first(where: { $0.url == url }) else {
            throw PodsError("Swift package \(url) is missing from the resolved packages.")
        }
        return pin.identity
    }

    /// Spec names needed for `dependencies` on `platform`, grouped by root pod.
    private func specClosure(for dependencies: [Dependency], platform: Platform.Name, pods: [String: InstalledPod]) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        var queue = dependencies.map(\.name)
        var visited = Set<String>()
        while let name = queue.popLast() {
            guard visited.insert(name).inserted else { continue }
            let root = Dependency.rootName(of: name)
            guard let pod = pods[root] else {
                // Pods replaced by SwiftPM packages have no pod target.
                if analysis.unifications.contains(where: { $0.podRoot == root }) { continue }
                throw PodsError("`\(root)` was not resolved.")
            }
            guard let spec = pod.spec.subspec(named: name) else {
                throw PodsError("`\(pod.spec.name) (\(pod.spec.version))` has no subspec named `\(name)`.")
            }
            result[root, default: []].insert(name)
            queue += spec.dependencies(for: platform).map(\.name)
        }
        return result
    }

    private func variantNames(_ keys: [VariantKey]) -> [VariantKey: String] {
        var names: [VariantKey: String] = [:]
        for (root, group) in Dictionary(grouping: keys, by: \.root) {
            let multiplePlatforms = Set(group.map(\.platform)).count > 1
            let multipleTypes = Set(group.map(\.buildType)).count > 1
            for key in group {
                var name = root
                if multiplePlatforms { name += "-" + key.platform.targetSuffix }
                if multipleTypes {
                    let suffix = switch key.buildType {
                    case .staticLibrary: "-Library"
                    case .staticFramework: "-StaticFramework"
                    case .dynamicFramework: "-Framework"
                    }
                    name += suffix
                }
                names[key] = name
            }
        }
        return names
    }

    /// Orders target names so that dependencies come first (stable for unrelated targets).
    private func topologicalOrder(_ names: [String], targets: [String: PodTarget]) -> [String] {
        var ordered: [String] = []
        var visited = Set<String>()
        func visit(_ name: String) {
            guard visited.insert(name).inserted, let target = targets[name] else { return }
            for dependency in target.dependencyNames { visit(dependency) }
            ordered.append(name)
        }
        for name in names.sorted() { visit(name) }
        // Only keep the requested names (dependencies of pods are part of the closure anyway).
        let requested = Set(names)
        return ordered.filter { requested.contains($0) }
    }
}
