public import Foundation
import PodsCore
public import PodsManifest

/// Finds and loads the Podfile of a project in any supported format.
public struct PodfileLoader: Sendable {
    /// Supported file names, in order of precedence.
    public static let fileNames = ["Podfile.swift", "Podfile", "Podfile.json"]

    public let environment: [String: String]
    public let swiftEvaluator: SwiftManifestEvaluator

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        swiftEvaluator: SwiftManifestEvaluator = SwiftManifestEvaluator()
    ) {
        self.environment = environment
        self.swiftEvaluator = swiftEvaluator
    }

    /// The Podfile in `directory`, preferring `Podfile.swift`.
    public static func podfileURL(in directory: URL) -> URL? {
        fileNames.lazy
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func load(_ url: URL) async throws -> Podfile {
        let json: JSON
        switch url.lastPathComponent {
        case let name where name.hasSuffix(".swift"):
            json = try await swiftEvaluator.evaluatePodfile(at: url)
        case let name where name.hasSuffix(".json"):
            json = try JSON(data: try Data(contentsOf: url))
        default:
            json = try RubyPodfileEvaluator.evaluate(
                source: try String(contentsOf: url, encoding: .utf8),
                file: url.path, directory: url.deletingLastPathComponent(), environment: environment
            )
        }
        return try Podfile(json: json)
    }
}
