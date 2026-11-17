import CryptoKit
public import Foundation
import PodsCore
import PodsManifest
import PodsPodfile
import PodsSpec

/// Options of `swiftpods package`.
public struct DistributionOptions: Sendable {
    /// The distribution's version, used in the binary target URLs.
    public let version: String
    /// Where the zips and a copy of `Package.swift` go; `<Podfile directory>/build/distribution` when `nil`.
    public let outputDirectory: URL?
    /// Whether every product is checked to link on its own.
    public let verify: Bool

    public init(version: String, outputDirectory: URL?, verify: Bool = true) {
        self.version = version
        self.outputDirectory = outputDirectory
        self.verify = verify
    }
}

/// `swiftpods package`: builds the pods of a Podfile with `distribution` into xcframework and resource bundle
/// zips and writes the distribution `Package.swift`.
public struct DistributionBuilder: Sendable {
    public let context: InstallerContext
    public let options: DistributionOptions

    public init(context: InstallerContext, options: DistributionOptions) {
        self.context = context
        self.options = options
    }

    private enum SDK: String, CaseIterable {
        case iphoneos, iphonesimulator
    }

    /// Returns the output directory.
    @discardableResult
    public func build() async throws -> URL {
        let ui = context.ui
        let podfile = try await PodfileLoader(swiftEvaluator: .init(cacheDirectory: context.cacheRoot.appendingPathComponent("Manifests")))
            .load(context.podfileURL)
        guard let settings = podfile.distribution else { throw PodsError("Podfile.swift has no `distribution`.") }
        guard podfile.installationOption("integrate_targets") == false else {
            throw PodsError("`swiftpods package` builds Pods.xcodeproj on its own and needs `installationOptions: .init(integrateTargets: false)` in Podfile.swift.")
        }
        let targets = podfile.resolvedTargets
        guard targets.count == 1, let target = targets.first else {
            throw PodsError("`distribution` needs exactly one target in Podfile.swift, found \(targets.count).")
        }

        let (plan, analysis) = try await Installer(context: context, options: InstallOptions(integrate: false)).installReturningAnalysis()
        guard let platform = plan.aggregateTargets.first?.platform, platform.name == .ios else {
            throw PodsError("`swiftpods package` supports iOS only yet.")
        }

        let podsWithBinary = Set(plan.podTargets.filter { $0.shouldBuild || !$0.files.vendoredFrameworks.isEmpty }.map(\.podName))
        var declared: [String] = []
        for name in target.dependencies.map(\.name) where !declared.contains(name) { declared.append(name) }
        let layout = DistributionLayout.derive(
            declared: declared,
            dependencies: Self.specDependencies(of: plan.pods, platform: platform.name),
            podsWithBinary: podsWithBinary,
            unified: Dictionary(analysis.unifications.map { ($0.podRoot, $0.packageURL) }, uniquingKeysWith: { first, _ in first })
        )
        for warning in layout.warnings { ui.warn(warning) }
        guard !layout.products.isEmpty else { throw PodsError("No pod of target `\(target.name)` has a binary to distribute.") }

        let projectDirectory = context.podfileURL.deletingLastPathComponent()
        let output = (options.outputDirectory ?? projectDirectory.appendingPathComponent("build/distribution")).standardizedFileURL
        let work = projectDirectory.appendingPathComponent("build/work")
        let symroot = work.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try await ui.section("Building pods") {
            for sdk in SDK.allCases { try await xcodebuild(sdk: sdk, platform: platform, symroot: symroot) }
        }
        let checksums = try await ui.section("Assembling xcframeworks") {
            let assembler = XCFrameworkAssembler(shell: context.shell, workDirectory: work.appendingPathComponent("xcframeworks"))
            var checksums: [String: String] = [:]
            for name in layout.binaryTargets {
                guard let podTarget = plan.podTargets.first(where: { $0.podName == name && $0.platform.name == platform.name }) else {
                    throw PodsError("No pod target builds `\(name)`.")
                }
                let xcframework = try await assemble(podTarget, assembler: assembler, platform: platform, symroot: symroot, output: output)
                checksums[name] = try Self.checksum(of: try await zip(xcframework, into: output))
            }
            return checksums
        }
        try await ui.section("Zipping resource bundles") {
            let staging = work.appendingPathComponent("bundles")
            for bundle in ResourceBundles.collect(pods: plan.pods, podsWithBinary: Set(layout.binaryTargets)) {
                // Podspec bundles live in `Resources/<Name>`, without the extension the zip must contain.
                let staged = staging.appendingPathComponent("\(bundle.name).bundle")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
                try FileManager.default.copyItem(at: bundle.directory, to: staged)
                try await zip(staged, into: output)
            }
        }

        let manifest = DistributionManifest.render(
            settings: settings, version: options.version, platform: platform, layout: layout, checksums: checksums,
            dependencies: try Self.packageDependencies(declared: podfile.swiftPackages, unifications: analysis.unifications,
                                                       resolved: analysis.swiftPackages)
        )
        let exports = projectDirectory.appendingPathComponent("Sources/Common/export.swift")
        try FileManager.default.createDirectory(at: exports.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DistributionManifest.renderCommonExports(layout: layout).write(to: exports, atomically: true, encoding: .utf8)
        try manifest.write(to: projectDirectory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try manifest.write(to: output.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        ui.message("Wrote the distribution of \(settings.name) \(options.version) to \(output.path)", style: .success)
        return output
    }

    /// The requirements `Common`'s packages get: every package a pod is unified with, narrowed to what the pods
    /// accept, and every other declared package with its declared range. Sorted by URL.
    static func packageDependencies(declared: [SwiftPackageDependency], unifications: [PackageUnifier.Unification],
                                    resolved: SwiftPackageResolver.Result?) throws -> [DistributionManifest.Dependency] {
        guard !declared.isEmpty || !unifications.isEmpty else { return [] }
        guard let resolved else { throw PodsError("The Swift packages of Podfile.swift were not resolved.") }
        var dependencies: [DistributionManifest.Dependency] = []
        for unification in unifications {
            let packageIdentity = identity(of: unification.packageURL)
            guard let pin = resolved.pins.first(where: { $0.identity == packageIdentity }) else {
                throw PodsError("Swift package \(unification.packageURL) has no resolved version.")
            }
            let requirement = try DistributionRequirement.forUnification(unification, pinned: pin.version, declared: unification.podfileRequirement)
            dependencies.append(.init(url: unification.packageURL, requirement: requirement, products: resolved.libraryProducts[packageIdentity] ?? []))
        }
        for package in declared {
            let unified = dependencies.contains { identity(of: $0.url) == package.identity }
            guard !unified else { continue }
            let range = try SwiftPackageResolver.range(of: package.requirement, url: package.url)
            dependencies.append(.init(url: package.url, requirement: .range(range.lower, range.upper),
                                      products: resolved.libraryProducts[package.identity] ?? []))
        }
        return dependencies.sorted { $0.url < $1.url }
    }

    /// Last path component without `.git`, lowercased (same as `SwiftPackageDependency.identity`).
    private static func identity(of url: String) -> String {
        var name = url.split(separator: "/").last.map(String.init) ?? url
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.lowercased()
    }

    /// Spec name (root or subspec) to the names of the specs it depends on, for every activated spec.
    private static func specDependencies(of pods: [InstalledPod], platform: Platform.Name) -> [String: [String]] {
        var dependencies: [String: [String]] = [:]
        for pod in pods {
            for name in pod.activatedSpecs {
                guard let spec = pod.spec.subspec(named: name) else { continue }
                dependencies[name] = spec.dependencies(for: platform).map(\.name)
            }
        }
        return dependencies
    }

    private func xcodebuild(sdk: SDK, platform: Platform, symroot: URL) async throws {
        let command = [
            "xcrun", "xcodebuild", "-project", context.sandbox.projectURL.path, "-alltargets", "-configuration", "Release",
            "-sdk", sdk.rawValue, "ONLY_ACTIVE_ARCH=NO", "ENABLE_TESTABILITY=NO", "CLANG_ENABLE_MODULE_DEBUGGING=NO",
            // Without SYMROOT, Swift package intermediates land in `<checkout>/build`, which collides with a `BUILD`
            // file in some checkouts on case-insensitive file systems.
            "SYMROOT=\(symroot.path)",
            "\(platform.name.deploymentTargetSetting)=\(platform.effectiveDeploymentTarget)",
        ]
        let result = try await context.shell.execute(command)
        guard result.status == 0 else {
            // xcodebuild prints compiler errors to stdout; its stderr mostly holds the final summary.
            let errors = (result.stdout + "\n" + result.stderr).split(separator: "\n").filter { $0.contains("error:") }
            throw PodsError("Building Pods.xcodeproj for \(sdk.rawValue) failed:\n" + errors.suffix(20).joined(separator: "\n"))
        }
    }

    private func assemble(_ target: PodTarget, assembler: XCFrameworkAssembler, platform: Platform, symroot: URL, output: URL) async throws -> URL {
        let name = target.podName
        let vendored = target.files.vendoredFrameworks
        if !vendored.isEmpty {
            guard !target.shouldBuild else {
                throw PodsError("\(name) has both compiled sources and vendored frameworks, which `swiftpods package` does not support yet.")
            }
            guard vendored.count == 1, vendored[0].lastPathComponent == "\(name).framework" else {
                throw PodsError("`swiftpods package` supports prebuilt pods that vendor exactly `\(name).framework` only yet; \(name) vendors \(vendored.joined(separator: ", ")).")
            }
            return try await assembler.assemblePrebuilt(framework: target.pod.location.appendingPathComponent(vendored[0]), podVersion: target.rootSpec.version,
                                                        minimumOS: platform.effectiveDeploymentTarget.description, output: output)
        }
        guard target.buildType.isFramework, target.moduleName == name else {
            throw PodsError("`swiftpods package` needs `use_frameworks!` and source pods whose module is named like the pod; \(name) builds \(target.productFileName).")
        }
        func framework(_ sdk: SDK) -> URL {
            symroot.appendingPathComponent("Release-\(sdk.rawValue)").appendingPathComponent(target.name).appendingPathComponent(target.productFileName)
        }
        return try await assembler.assembleSource(module: name, deviceFramework: framework(.iphoneos), simulatorFramework: framework(.iphonesimulator), output: output)
    }

    /// Zips `item` as `<output>/<item name>.zip`, with `item`'s name as the top-level entry. Returns the zip.
    @discardableResult
    private func zip(_ item: URL, into output: URL) async throws -> URL {
        let archive = output.appendingPathComponent(item.lastPathComponent + ".zip")
        // `zip` adds to an existing archive instead of replacing it.
        if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
        try await context.shell.run("zip", ["-qry", archive.path, item.lastPathComponent], in: item.deletingLastPathComponent())
        return archive
    }

    /// The SHA-256 SwiftPM expects as a binary target's `checksum`.
    private static func checksum(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}
