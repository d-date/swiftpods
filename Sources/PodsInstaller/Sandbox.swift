public import Foundation
import PodsCore
import PodsSpec

/// The `Pods/` directory and its layout.
public struct Sandbox: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var projectURL: URL { root.appendingPathComponent("Pods.xcodeproj") }
    public var manifestURL: URL { root.appendingPathComponent("Manifest.lock") }
    public var targetSupportFilesURL: URL { root.appendingPathComponent("Target Support Files", isDirectory: true) }
    public var localPodspecsURL: URL { root.appendingPathComponent("Local Podspecs", isDirectory: true) }
    public var publicHeadersURL: URL { root.appendingPathComponent("Headers/Public", isDirectory: true) }
    public var privateHeadersURL: URL { root.appendingPathComponent("Headers/Private", isDirectory: true) }

    public func podDirectory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    public func supportFilesDirectory(_ target: String) -> URL { targetSupportFilesURL.appendingPathComponent(target, isDirectory: true) }

    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Generated content is recreated on every install.
        for generated in [targetSupportFilesURL, root.appendingPathComponent("Headers")] {
            try? FileManager.default.removeItem(at: generated)
        }
        try FileManager.default.createDirectory(at: targetSupportFilesURL, withIntermediateDirectories: true)
    }

    /// Copies a downloaded pod from the cache into `Pods/<Name>` unless it is already there.
    func installPod(named name: String, version: String, from location: URL) throws -> URL {
        let fileManager = FileManager.default
        let destination = podDirectory(name)
        let stamp = destination.appendingPathComponent(".swiftpods-version")
        if let installed = fileManager.contents(atPath: stamp.path), String(decoding: installed, as: UTF8.self) == version {
            return destination
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: location, to: destination)
        try? fileManager.removeItem(at: destination.appendingPathComponent(".swiftpods-complete"))
        try Data(version.utf8).write(to: stamp)
        return destination
    }

    /// Removes pod directories that are no longer installed.
    func removeUnused(keeping names: Set<String>) {
        let fileManager = FileManager.default
        let reserved: Set<String> = ["Headers", "Local Podspecs", "Target Support Files", "Pods.xcodeproj", "Manifest.lock"]
        for entry in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where !reserved.contains(entry) && !entry.hasPrefix(".") {
            if !names.contains(entry) { try? fileManager.removeItem(at: root.appendingPathComponent(entry)) }
        }
        for entry in (try? fileManager.contentsOfDirectory(atPath: localPodspecsURL.path)) ?? [] {
            let name = entry.replacingOccurrences(of: ".podspec.json", with: "")
            if !names.contains(name) { try? fileManager.removeItem(at: localPodspecsURL.appendingPathComponent(entry)) }
        }
    }

    /// Stores the spec of an external pod as JSON, like CocoaPods' `Local Podspecs`.
    func storeLocalPodspec(_ spec: Specification) throws {
        try FileManager.default.createDirectory(at: localPodspecsURL, withIntermediateDirectories: true)
        try spec.json.serialized().write(to: localPodspecsURL.appendingPathComponent("\(spec.name).podspec.json"), atomically: true, encoding: .utf8)
    }

    /// Symlinks headers into `Headers/Public/<dir>` / `Headers/Private/<dir>` so `#import <Pod/Header.h>` works.
    func linkHeaders(_ headers: [String], podRoot: URL, directory: String, mappingsDir: String?, isPublic: Bool) throws {
        let base = (isPublic ? publicHeadersURL : privateHeadersURL).appendingPathComponent(directory, isDirectory: true)
        let fileManager = FileManager.default
        for header in headers {
            var relative = header.lastPathComponent
            if let mappingsDir, header.hasPrefix(mappingsDir.hasSuffix("/") ? mappingsDir : mappingsDir + "/") {
                relative = String(header.dropFirst(mappingsDir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            let link = base.appendingPathComponent(relative)
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: link)
            let target = podRoot.appendingPathComponent(header)
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: Self.relativePath(from: link.deletingLastPathComponent(), to: target))
        }
    }

    /// A relative path from `base` (a directory) to `target`.
    static func relativePath(from base: URL, to target: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(baseComponents.count, targetComponents.count), baseComponents[common] == targetComponents[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: baseComponents.count - common)
        let rest = Array(targetComponents[common...])
        let path = (ups + rest).joined(separator: "/")
        return path.isEmpty ? "." : path
    }
}
