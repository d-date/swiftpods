import Foundation
import PodsCore

/// Checks that every product of a distribution package links on its own, before anything is uploaded: for each
/// product, an iOS executable that depends on that product only is built for the simulator and the device, linked
/// with `-ObjC -all_load` as consumers are told to. `-all_load` loads every member of every linked library, so a
/// symbol any of them needs from a binary target the product lacks shows up as undefined.
struct ProductLinkVerifier {
    let shell: Shell
    /// Scratch space; each product gets a subdirectory, replaced on every run, next to the shared package clones.
    let workDirectory: URL
    /// The distribution's deployment target.
    let deploymentTarget: Version

    private static let packageName = "Distribution"
    private static let appName = "SwiftPodsLinkCheck"
    private static let destinations = [("iOS Simulator", "generic/platform=iOS Simulator"), ("iOS", "generic/platform=iOS")]

    /// The executable's deployment target is at least 18.0: below it, swiftc links the Swift back-deployment
    /// libraries twice, which `-all_load` turns into duplicate symbols that an app linked by clang does not get.
    private var appDeploymentTarget: Version { max(deploymentTarget, Version(18, 0, 0)) }

    /// - Parameter packageDirectory: the distribution directory: `Package.swift`, `Sources`, and the unzipped
    ///   `<Name>.xcframework` of every binary target.
    func verify(products: [String], packageDirectory: URL) async throws {
        let manifest = try Self.localManifest(String(contentsOf: packageDirectory.appendingPathComponent("Package.swift"), encoding: .utf8))
        for product in products {
            let scratch = workDirectory.appendingPathComponent(product)
            if FileManager.default.fileExists(atPath: scratch.path) { try FileManager.default.removeItem(at: scratch) }
            let package = try writePackage(manifest: manifest, from: packageDirectory, in: scratch.appendingPathComponent(Self.packageName))
            let app = try writeApp(product: product, package: package, in: scratch.appendingPathComponent(Self.appName))
            for (name, destination) in Self.destinations {
                let result = try await shell.execute([
                    "xcrun", "xcodebuild", "build", "-scheme", Self.appName, "-destination", destination,
                    "-derivedDataPath", scratch.appendingPathComponent("DerivedData").path,
                    // Shared, so the distribution's Swift packages are cloned once rather than once per product;
                    // the leading dot keeps it apart from product directories.
                    "-clonedSourcePackagesDirPath", workDirectory.appendingPathComponent(".SourcePackages").path,
                    "CODE_SIGNING_ALLOWED=NO",
                ], in: app)
                guard result.status == 0 else {
                    throw PodsError("Product \(product) does not link on its own for \(name):\n" + Self.failureSummary(result.stdout + "\n" + result.stderr))
                }
            }
        }
    }

    /// `manifest` with every `.binaryTarget(name:url:checksum:)` turned into `.binaryTarget(name:path:)` pointing
    /// at `<Name>.xcframework` in the package root.
    static func localManifest(_ manifest: String) throws -> String {
        let remote = #/url: "[^"]*/([^"/]+\.xcframework)\.zip",\s*checksum: "[0-9a-f]+"\)/#
        let local = manifest.replacing(remote) { match in #"path: "\#(match.1)")"# }
        guard !local.contains("checksum:") else { throw PodsError("Could not point the binary targets of Package.swift at local xcframeworks.") }
        return local
    }

    /// The distribution package with local binary targets. SwiftPM needs binary target paths inside the package
    /// root, so the xcframeworks and `Sources` are symbolic links into `source`.
    private func writePackage(manifest: String, from source: URL, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for item in try FileManager.default.contentsOfDirectory(atPath: source.path)
        where item == "Sources" || item.hasSuffix(".xcframework") {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(item),
                                                       withDestinationURL: source.appendingPathComponent(item))
        }
        return directory
    }

    private func writeApp(product: String, package: URL, in directory: URL) throws -> URL {
        let sources = directory.appendingPathComponent("Sources/\(Self.appName)")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
          name: "\(Self.appName)",
          platforms: [.iOS("\(appDeploymentTarget)")],
          dependencies: [.package(path: "../\(package.lastPathComponent)")],
          targets: [
            .executableTarget(
              name: "\(Self.appName)",
              dependencies: [.product(name: \(Self.literal(product)), package: "\(Self.packageName)")],
              linkerSettings: [.unsafeFlags(["-Xlinker", "-ObjC", "-Xlinker", "-all_load"])]),
          ]
        )

        """.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "print(\"linked\")\n".write(to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        return directory
    }

    /// The first block of undefined symbols in an xcodebuild log, or its `error:` lines when there is none.
    static func failureSummary(_ log: String) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        if let start = lines.firstIndex(where: { $0.hasPrefix("Undefined symbols") }) {
            let block = lines[start...].prefix { !$0.hasPrefix("ld: ") }
            return block.prefix(20).joined(separator: "\n")
        }
        return lines.filter { $0.contains("error:") }.suffix(20).joined(separator: "\n")
    }

    /// A Swift string literal for a product name.
    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
