import CryptoKit
public import Foundation
public import PodsCore
public import PodsSpec

/// Compiles and runs Swift manifests (`Podfile.swift`, `*.podspec.swift`) and returns their JSON.
///
/// The `SwiftPodsDescription` sources are compiled together with the manifest in a single
/// file. `#sourceLocation` keeps compiler diagnostics pointing at the user's file and line.
/// Compiled manifests are cached by content hash.
public struct SwiftManifestEvaluator: SwiftManifestEvaluating {
    public enum Kind: String, Sendable {
        case podfile
        case podspec
    }

    public struct CompilationError: Error, CustomStringConvertible {
        public let manifest: String
        public let diagnostics: String
        public var description: String { "Failed to compile \(manifest):\n\(diagnostics)" }
    }

    public let cacheDirectory: URL
    public let shell: Shell
    /// Command used to invoke the compiler (overridable with `SWIFTPODS_SWIFTC`).
    public let compiler: [String]

    public init(
        cacheDirectory: URL = SwiftManifestEvaluator.defaultCacheDirectory,
        shell: Shell = Shell(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.cacheDirectory = cacheDirectory
        self.shell = shell
        if let custom = environment["SWIFTPODS_SWIFTC"] {
            self.compiler = [custom]
        } else {
            self.compiler = ["xcrun", "--sdk", "macosx", "swiftc"]
        }
    }

    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftPods/Manifests", isDirectory: true)
    }

    public func evaluateSpec(at url: URL) async throws -> JSON {
        try await evaluate(url, expecting: .podspec)
    }

    public func evaluatePodfile(at url: URL) async throws -> JSON {
        try await evaluate(url, expecting: .podfile)
    }

    /// Compiles (or reuses) the manifest program, runs it and decodes its JSON output.
    public func evaluate(_ url: URL, expecting kind: Kind) async throws -> JSON {
        let source = try String(contentsOf: url, encoding: .utf8)
        let program = Self.program(for: source, path: url.path)
        let key = SHA256.hash(data: Data((program + compiler.joined(separator: " ")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let executable = cacheDirectory.appendingPathComponent(key).appendingPathComponent("manifest")

        if !FileManager.default.isExecutableFile(atPath: executable.path) {
            try await compile(program, to: executable, manifest: url)
        }

        let output = try await shell.execute([executable.path], in: url.deletingLastPathComponent())
        guard output.status == 0 else {
            throw PodsError("Evaluating \(url.lastPathComponent) failed (exit \(output.status)):\n\(output.stderr)\(output.stdout)")
        }
        guard let start = output.stdout.range(of: "<swiftpods-manifest>"),
              let end = output.stdout.range(of: "</swiftpods-manifest>", range: start.upperBound..<output.stdout.endIndex)
        else {
            let message = output.stdout.split(separator: "\n").first { $0.hasPrefix("swiftpods: error:") }
            throw PodsError(message.map(String.init) ?? "\(url.lastPathComponent) did not produce a manifest")
        }
        let envelope = try JSON(parsing: String(output.stdout[start.upperBound..<end.lowerBound]))
        guard envelope["kind"]?.string == kind.rawValue, let manifest = envelope["manifest"] else {
            throw PodsError("\(url.lastPathComponent) must create a `\(kind == .podfile ? "Podfile" : "PodSpec")`")
        }
        return manifest
    }

    /// The single-file program: description API + user manifest + entry point.
    static func program(for source: String, path: String) -> String {
        // The API is part of the same module, so its import must be dropped.
        let userSource = source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.trimmingWhitespace() == "import SwiftPodsDescription" ? "" : String(line)
        }.joined(separator: "\n")
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        \(embeddedDescriptionSources)
        #sourceLocation(file: "\(escapedPath)", line: 1)
        \(userSource)
        #sourceLocation()
        __swiftpodsEmitManifest()

        """
    }

    private func compile(_ program: String, to executable: URL, manifest: URL) async throws {
        let fileManager = FileManager.default
        let workDirectory = cacheDirectory.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let mainFile = workDirectory.appendingPathComponent("main.swift")
        try program.write(to: mainFile, atomically: true, encoding: .utf8)
        let product = workDirectory.appendingPathComponent("manifest")
        let output = try await shell.execute(
            compiler + ["-swift-version", "6", "-Onone", "-suppress-warnings", mainFile.path, "-o", product.path],
            in: workDirectory
        )
        guard output.status == 0 else {
            throw CompilationError(manifest: manifest.lastPathComponent, diagnostics: output.stderr.trimmingWhitespace())
        }
        // Move into place atomically so concurrent evaluations never see a partial binary.
        try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: executable.path) { return }
        do {
            try fileManager.moveItem(at: product, to: executable)
        } catch where fileManager.isExecutableFile(atPath: executable.path) {
            // Another evaluation won the race.
        }
    }
}
