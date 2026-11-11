import CryptoKit
public import Foundation
public import PodsCore
import PodsDSL

/// Converts a Swift podspec (`*.podspec.swift`) into podspec JSON.
/// Injected so that `PodsSpec` does not depend on the Swift compiler integration.
public protocol SwiftManifestEvaluating: Sendable {
    func evaluateSpec(at url: URL) async throws -> JSON
}

/// Loads specifications from files in any supported format.
public struct SpecLoader: Sendable {
    public enum Format: Sendable, Equatable {
        case json, ruby, swift

        public init?(url: URL) {
            let name = url.lastPathComponent
            if name.hasSuffix(".podspec.json") { self = .json }
            else if name.hasSuffix(".podspec.swift") { self = .swift }
            else if name.hasSuffix(".podspec") { self = .ruby }
            else { return nil }
        }
    }

    public let swiftEvaluator: (any SwiftManifestEvaluating)?
    public let environment: [String: String]

    public init(swiftEvaluator: (any SwiftManifestEvaluating)? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.swiftEvaluator = swiftEvaluator
        self.environment = environment
    }

    public func load(_ url: URL) async throws -> Specification {
        guard let format = Format(url: url) else {
            throw PodsError("Unsupported podspec file `\(url.lastPathComponent)`")
        }
        let data = try Data(contentsOf: url)
        let checksum = Self.sha1(data)
        let json: JSON
        switch format {
        case .json:
            json = try JSON(data: data)
        case .ruby:
            json = try RubySpecEvaluator.evaluate(
                source: String(decoding: data, as: UTF8.self), file: url.path,
                directory: url.deletingLastPathComponent(), environment: environment
            )
        case .swift:
            guard let swiftEvaluator else { throw PodsError("Swift podspecs are not supported in this context") }
            json = try await swiftEvaluator.evaluateSpec(at: url)
        }
        return try Specification(json: json, checksum: checksum)
    }

    /// Loads podspec JSON text (e.g. downloaded from the CDN).
    public static func load(jsonData data: Data) throws -> Specification {
        try Specification(json: try JSON(data: data), checksum: sha1(data))
    }

    /// Finds a podspec for `name` in `directory` (Swift, Ruby, then JSON).
    public static func podspecURL(named name: String?, in directory: URL) -> URL? {
        let fileManager = FileManager.default
        if let name {
            for suffix in [".podspec.swift", ".podspec", ".podspec.json"] {
                let candidate = directory.appendingPathComponent(name + suffix)
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.sorted().first { Format(url: URL(fileURLWithPath: $0)) != nil }
            .map { directory.appendingPathComponent($0) }
    }

    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
