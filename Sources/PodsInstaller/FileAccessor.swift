import Foundation
import PodsCore
import PodsSpec

/// The files of a pod target for one platform, resolved from the spec's file patterns.
/// All paths are relative to the pod's root directory.
struct FileAccessor: Sendable {
    static let headerExtensions: Set<String> = ["h", "hh", "hpp", "ipp", "tpp", "hxx", "def", "inl", "inc"]
    static let sourceExtensions: Set<String> = headerExtensions.union(["m", "mm", "c", "cc", "cpp", "cxx", "c++", "s", "S", "swift", "metal"])
    static let compiledExtensions: Set<String> = ["m", "mm", "c", "cc", "cpp", "cxx", "c++", "s", "S", "swift", "metal"]

    var sourceFiles: [String] = []
    var publicHeaders: [String] = []
    var privateHeaders: [String] = []
    var projectHeaders: [String] = []
    var resources: [String] = []
    var resourceBundles: [(name: String, files: [String])] = []
    var vendoredFrameworks: [String] = []
    var vendoredLibraries: [String] = []
    var preservePaths: [String] = []
    /// The spec's `module_map`.
    var moduleMap: String?
    /// A `module.modulemap` shipped next to the public headers (SwiftPM-style `include/`).
    /// Static libraries use it instead of a generated one; frameworks always generate theirs.
    var shippedModuleMap: String?
    var isModuleMapDisabled = false

    /// The module map a static library should expose, if not generated.
    var staticLibraryModuleMap: String? { moduleMap ?? shippedModuleMap }
    var prefixHeader: String?
    var headerMappingsDir: String?
    var headerDir: String?
    /// Vendored `.xcframework`s with the shape of their slices.
    var xcframeworks: [XCFramework] = []

    /// A vendored `.xcframework`, described from its `Info.plist`.
    struct XCFramework: Sendable, Equatable {
        /// Path relative to the pod root.
        let path: String
        /// `Foo.framework` or `libFoo.a` inside each slice.
        let libraryPath: String
        let hasHeaders: Bool

        var isFramework: Bool { libraryPath.hasSuffix(".framework") }
        /// The name passed to the linker (`-framework Foo` / `-lFoo`).
        var linkName: String {
            var name = libraryPath.deletingPathExtension
            if !isFramework, name.hasPrefix("lib") { name.removeFirst(3) }
            return name
        }

        init?(path: String, root: URL) {
            let plist = root.appendingPathComponent(path).appendingPathComponent("Info.plist")
            guard let data = FileManager.default.contents(atPath: plist.path),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let libraries = object["AvailableLibraries"] as? [[String: Any]],
                  let libraryPath = libraries.first?["LibraryPath"] as? String
            else { return nil }
            self.path = path
            self.libraryPath = libraryPath
            self.hasHeaders = libraries.contains { $0["HeadersPath"] != nil }
        }
    }

    /// Vendored `.framework` bundles (excluding xcframeworks).
    var plainFrameworks: [String] { vendoredFrameworks.filter { $0.hasSuffix(".framework") } }

    var compiledSources: [String] { sourceFiles.filter { Self.compiledExtensions.contains($0.pathExtension) } }
    var headers: [String] { sourceFiles.filter { Self.headerExtensions.contains($0.pathExtension) } }
    var usesSwift: Bool { sourceFiles.contains { $0.hasSuffix(".swift") } }
    var hasObjCHeaders: Bool { !publicHeaders.isEmpty }
    var hasCompiledSources: Bool { !compiledSources.isEmpty }

    /// Every file referenced by the pod (used to clean up downloaded sources and build the project).
    var allFiles: [String] {
        sourceFiles + resources + resourceBundles.flatMap(\.files) + vendoredFrameworks + vendoredLibraries
            + preservePaths + [moduleMap, prefixHeader].compactMap { $0 }
    }

    init() {}

    /// Collects the files of `specs` (a root spec and/or subspecs of the same pod) for `platform`.
    init(root: URL, specs: [Specification], platform: Platform.Name) {
        let glob = Glob(root: root)
        let paths = glob.allPaths()
        func match(_ patterns: [String], extensions: Set<String>? = nil) -> [String] {
            patterns.isEmpty ? [] : glob.match(patterns, directoryExtensions: extensions, in: paths)
        }
        func unique(_ items: [String]) -> [String] {
            var seen = Set<String>()
            return items.filter { seen.insert($0).inserted }
        }

        // CocoaPods has one file accessor per spec: `public_header_files` only restricts the
        // headers of the spec that declares (or inherits) it.
        var publicHeaderSet = Set<String>()
        var privateHeaderSet = Set<String>()
        var projectHeaderSet = Set<String>()
        for spec in specs {
            let consumer = spec.consumer(for: platform)
            let excluded = Set(match(consumer.excludeFiles, extensions: Self.sourceExtensions))
            let sources = match(consumer.sourceFiles, extensions: Self.sourceExtensions).filter { !excluded.contains($0) }
            sourceFiles += sources
            let specHeaders = sources.filter { Self.headerExtensions.contains($0.pathExtension) }
            if consumer.publicHeaderFiles.isEmpty {
                publicHeaderSet.formUnion(specHeaders)
            } else {
                publicHeaderSet.formUnion(Set(match(consumer.publicHeaderFiles)).intersection(specHeaders))
            }
            privateHeaderSet.formUnion(match(consumer.privateHeaderFiles))
            projectHeaderSet.formUnion(match(consumer.projectHeaderFiles))
            resources += match(consumer.resources, extensions: nil).filter { !excluded.contains($0) }
            for bundle in consumer.resourceBundles {
                let files = match(bundle.patterns, extensions: nil)
                if let index = resourceBundles.firstIndex(where: { $0.name == bundle.name }) {
                    resourceBundles[index].files = unique(resourceBundles[index].files + files)
                } else {
                    resourceBundles.append((bundle.name, files))
                }
            }
            vendoredFrameworks += match(consumer.vendoredFrameworks)
            vendoredLibraries += match(consumer.vendoredLibraries)
            preservePaths += match(consumer.preservePaths)
            moduleMap = moduleMap ?? consumer.moduleMap
            isModuleMapDisabled = isModuleMapDisabled || consumer.isModuleMapDisabled
            prefixHeader = prefixHeader ?? consumer.prefixHeaderFile
            headerMappingsDir = headerMappingsDir ?? consumer.headerMappingsDir
            headerDir = headerDir ?? consumer.headerDir
        }
        sourceFiles = unique(sourceFiles)
        resources = unique(resources)
        vendoredFrameworks = unique(vendoredFrameworks)
        xcframeworks = vendoredFrameworks.filter { $0.hasSuffix(".xcframework") }.compactMap { XCFramework(path: $0, root: root) }
        vendoredLibraries = unique(vendoredLibraries)
        preservePaths = unique(preservePaths)

        let allHeaders = headers
        privateHeaders = allHeaders.filter { privateHeaderSet.contains($0) }
        projectHeaders = allHeaders.filter { projectHeaderSet.contains($0) && !privateHeaderSet.contains($0) }
        publicHeaders = allHeaders.filter { header in
            if privateHeaderSet.contains(header) || projectHeaderSet.contains(header) { return false }
            return publicHeaderSet.contains(header)
        }
        // Headers that are neither public nor private are project headers.
        projectHeaders += allHeaders.filter { !publicHeaders.contains($0) && !privateHeaders.contains($0) && !projectHeaders.contains($0) }
        if moduleMap == nil {
            let directories = Set(publicHeaders.map { $0.deletingLastPathComponent })
            shippedModuleMap = directories.sorted()
                .map { $0.isEmpty ? "module.modulemap" : $0 + "/module.modulemap" }
                .first { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        }
    }
}
