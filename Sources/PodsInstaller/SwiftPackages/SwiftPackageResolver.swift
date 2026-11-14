import Foundation
import PodsCore

/// Resolves SwiftPM packages with `swift package resolve` in a scratch package.
struct SwiftPackageResolver {
    struct Pin: Sendable, Equatable {
        let identity: String
        let url: String
        let version: Version
        let revision: String
    }

    struct Result: Sendable {
        let pins: [Pin]
        /// identity → names of the package's library products.
        let libraryProducts: [String: [String]]
        /// Raw `Package.resolved` contents.
        let resolvedFile: Data
    }

    let workDirectory: URL
    let shell: Shell

    init(workDirectory: URL, shell: Shell) {
        self.workDirectory = workDirectory
        self.shell = shell
    }

    /// `requirements` maps a package URL to its range. `previousResolved` is copied in first so pins are kept,
    /// except for the packages whose identities are in `updating`, which move to their newest versions.
    /// With `readingProducts: false`, `libraryProducts` is left empty (for a resolution that is not final).
    func resolve(_ requirements: [(url: String, lowerBound: Version?, upperBound: Version?, requirement: Requirement?)],
                 previousResolved: Data?, updating: [String] = [], readingProducts: Bool = true) async throws -> Result {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        var dependencies: [String] = []
        for entry in requirements {
            let range: (lower: Version, upper: Version)
            if let lower = entry.lowerBound, let upper = entry.upperBound {
                range = (lower, upper)
            } else if let requirement = entry.requirement {
                range = try Self.range(of: requirement, url: entry.url)
            } else {
                throw PodsError("Swift package \(entry.url) has no version requirement.")
            }
            let lower = try Self.semanticVersion(range.lower, url: entry.url)
            let upper = try Self.semanticVersion(range.upper, url: entry.url)
            dependencies.append("        .package(url: \(Self.swiftLiteral(entry.url)), \"\(lower)\"..<\"\(upper)\"),")
        }
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "SwiftPodsResolution",
            dependencies: [
        \(dependencies.joined(separator: "\n"))
            ]
        )

        """
        try manifest.write(to: workDirectory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let resolvedURL = workDirectory.appendingPathComponent("Package.resolved")
        if let previousResolved {
            try previousResolved.write(to: resolvedURL)
        } else if fileManager.fileExists(atPath: resolvedURL.path) {
            // A leftover file from an earlier run would keep old pins when updating.
            try fileManager.removeItem(at: resolvedURL)
        }

        // Without pins, `update` fetches the repositories and picks the newest versions; `resolve` would
        // keep the checkouts left in `.build` by an earlier run (also for packages missing from the pins),
        // so packages to move are named to `update` rather than dropped from the pins.
        let arguments = previousResolved == nil ? ["update"] : updating.isEmpty ? ["resolve"] : ["update"] + updating
        try await shell.run("swift", ["package"] + arguments, in: workDirectory)
        // SwiftPM writes no `Package.resolved` when there is nothing to pin.
        let resolvedFile = fileManager.fileExists(atPath: resolvedURL.path) ? try Data(contentsOf: resolvedURL) : Data()
        let pins = resolvedFile.isEmpty ? [] : try Self.pins(fromResolved: resolvedFile)
        return Result(pins: pins, libraryProducts: readingProducts ? try await libraryProducts() : [:], resolvedFile: resolvedFile)
    }

    /// Reads the pins of a `Package.resolved` file (format version 2 or 3).
    static func pins(fromResolved data: Data) throws -> [Pin] {
        let json = try JSON(data: data)
        guard let entries = json["pins"]?.array else {
            throw PodsError("Unsupported Package.resolved format (version \(json["version"]?.string ?? "unknown")).")
        }
        return try entries.map { entry in
            guard let identity = entry["identity"]?.string, let url = entry["location"]?.string,
                  let revision = entry["state"]?["revision"]?.string else {
                throw PodsError("Invalid pin in Package.resolved.")
            }
            guard let version = entry["state"]?["version"]?.string.flatMap(Version.init) else {
                throw PodsError("Swift package \(url) is not pinned to a version.")
            }
            return Pin(identity: identity, url: url, version: version, revision: revision)
        }
        .sorted { $0.identity < $1.identity }
    }

    /// A `Package.resolved` (format version 2) holding `pins`; `nil` when there are none, so that SwiftPM resolves from scratch.
    static func resolvedFile(pins: [Pin]?) -> Data? {
        guard let pins, !pins.isEmpty else { return nil }
        let entries = pins.map { pin -> JSON in
            // SwiftPM records local repositories (`file://` URLs) by path.
            let path = pin.url.hasPrefix("file://") ? String(pin.url.dropFirst(7)) : pin.url
            return .object(OrderedObject([
                ("identity", .string(pin.identity)),
                ("kind", .string(path.hasPrefix("/") ? "localSourceControl" : "remoteSourceControl")),
                ("location", .string(path)),
                ("state", .object(OrderedObject([("revision", .string(pin.revision)), ("version", .string(pin.version.description))]))),
            ]))
        }
        let json = JSON.object(OrderedObject([("pins", .array(entries)), ("version", .number(2))]))
        return Data((json.serialized() + "\n").utf8)
    }

    /// Library products of every package of the last resolution, read from each checkout's manifest.
    func libraryProducts() async throws -> [String: [String]] {
        let output = try await shell.run("swift", ["package", "show-dependencies", "--format", "json"], in: workDirectory)
        var checkouts: [String: String] = [:]
        func collect(_ node: JSON) {
            for dependency in node["dependencies"]?.array ?? [] {
                if let identity = dependency["identity"]?.string, let path = dependency["path"]?.string {
                    checkouts[identity] = path
                }
                collect(dependency)
            }
        }
        collect(try JSON(parsing: output.stdout))

        let shell = shell
        let workDirectory = workDirectory
        return try await withThrowingTaskGroup(of: (String, [String]).self) { group in
            for (identity, path) in checkouts {
                group.addTask {
                    let dump = try await shell.run("swift", ["package", "dump-package", "--package-path", path], in: workDirectory)
                    let products = try JSON(parsing: dump.stdout)["products"]?.array ?? []
                    return (identity, products.compactMap { product in
                        product["type"]?["library"] == nil ? nil : product["name"]?.string
                    })
                }
            }
            var result: [String: [String]] = [:]
            for try await (identity, names) in group { result[identity] = names }
            return result
        }
    }

    /// Converts a CocoaPods-style requirement to a half-open SwiftPM range.
    static func range(of requirement: Requirement, url: String) throws -> (lower: Version, upper: Version) {
        var lower: Version?
        var upper: Version?
        func raiseLower(_ version: Version) { if lower.map({ version > $0 }) ?? true { lower = version } }
        func lowerUpper(_ version: Version) { if upper.map({ version < $0 }) ?? true { upper = version } }
        for constraint in requirement.constraints {
            switch constraint.op {
            case .greaterThanOrEqual: raiseLower(constraint.version)
            case .lessThan: lowerUpper(constraint.version)
            case .lessThanOrEqual: lowerUpper(nextPatch(constraint.version))
            case .equal:
                raiseLower(constraint.version)
                lowerUpper(nextPatch(constraint.version))
            case .optimistic:
                raiseLower(constraint.version)
                lowerUpper(constraint.version.optimisticUpperBound)
            case .notEqual, .greaterThan:
                throw PodsError("The requirement `\(requirement)` of Swift package \(url) cannot be expressed as a SwiftPM range.")
            }
        }
        guard let lower, let upper else {
            throw PodsError("The requirement `\(requirement)` of Swift package \(url) needs both a lower and an upper bound.")
        }
        return (lower, upper)
    }

    /// The smallest release above `version` (SwiftPM versions have three components).
    private static func nextPatch(_ version: Version) -> Version {
        Version(version.major, version.minor, version.patch + 1)
    }

    /// `major.minor.patch[-prerelease]`, as SwiftPM requires.
    static func semanticVersion(_ version: Version, url: String) throws -> String {
        guard version.release.count <= 3 else {
            throw PodsError("Version \(version) of Swift package \(url) is not a semantic version.")
        }
        var result = "\(version.major).\(version.minor).\(version.patch)"
        if version.isPreRelease { result += "-" + version.preRelease.map(\.description).joined(separator: ".") }
        return result
    }

    /// A Swift string literal; URLs never contain quotes or backslashes, but escape them anyway.
    private static func swiftLiteral(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
