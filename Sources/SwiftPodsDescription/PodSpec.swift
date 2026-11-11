// SwiftPodsDescription: the API used by `*.podspec.swift` manifests.

/// A pod specification written in Swift, in the style of SwiftPM's `Package.swift`.
///
/// ```swift
/// let podspec = PodSpec(
///     name: "MyKit",
///     version: "1.0.0",
///     summary: "My kit",
///     license: .mit(file: "LICENSE"),
///     source: .git(url: "https://example.com/MyKit.git", tag: "1.0.0"),
///     platforms: [.iOS(.v15)],
///     sourceFiles: ["Sources/**/*.swift"],
///     dependencies: [.pod(name: "Alamofire", from: "5.9.0")]
/// )
/// ```
public final class PodSpec {
    public var name: String
    public var version: String
    public var summary: String?
    public var description: String?
    public var homepage: String?
    public var license: License?
    public var authors: [String: String]
    public var source: SourceLocation?
    public var socialMediaURL: String?
    public var documentationURL: String?
    public var platforms: [SupportedPlatform]
    public var swiftVersions: [String]
    public var cocoapodsVersion: String?
    public var moduleName: String?
    public var headerDir: String?
    public var moduleMap: String?
    public var staticFramework: Bool?
    /// Subspecs used when depending on the pod without naming a subspec. `[]` means none.
    public var defaultSubspecs: [String]?
    public var scriptPhases: [ScriptPhase]
    /// Files, build settings and dependencies of the root spec.
    public var attributes: Attributes
    /// Attributes that only apply on some platforms (`s.ios.frameworks = ...`).
    public var platformSpecific: [PlatformAttributes]
    public var subspecs: [Subspec]
    public var testSpecs: [TestSpec]
    public var appSpecs: [Subspec]

    public init(
        name: String,
        version: String,
        summary: String? = nil,
        description: String? = nil,
        homepage: String? = nil,
        license: License? = nil,
        authors: [String: String] = [:],
        source: SourceLocation? = nil,
        socialMediaURL: String? = nil,
        documentationURL: String? = nil,
        platforms: [SupportedPlatform] = [],
        swiftVersions: [String] = [],
        cocoapodsVersion: String? = nil,
        moduleName: String? = nil,
        headerDir: String? = nil,
        moduleMap: String? = nil,
        staticFramework: Bool? = nil,
        sourceFiles: [String] = [],
        excludeFiles: [String] = [],
        publicHeaderFiles: [String] = [],
        privateHeaderFiles: [String] = [],
        resources: [String] = [],
        resourceBundles: [String: [String]] = [:],
        vendoredFrameworks: [String] = [],
        vendoredLibraries: [String] = [],
        frameworks: [String] = [],
        weakFrameworks: [String] = [],
        libraries: [String] = [],
        compilerFlags: [String] = [],
        podTargetXCConfig: [String: String] = [:],
        userTargetXCConfig: [String: String] = [:],
        preservePaths: [String] = [],
        requiresARC: Bool? = nil,
        dependencies: [Dependency] = [],
        scriptPhases: [ScriptPhase] = [],
        platformSpecific: [PlatformAttributes] = [],
        defaultSubspecs: [String]? = nil,
        subspecs: [Subspec] = [],
        testSpecs: [TestSpec] = [],
        appSpecs: [Subspec] = []
    ) {
        self.name = name
        self.version = version
        self.summary = summary
        self.description = description
        self.homepage = homepage
        self.license = license
        self.authors = authors
        self.source = source
        self.socialMediaURL = socialMediaURL
        self.documentationURL = documentationURL
        self.platforms = platforms
        self.swiftVersions = swiftVersions
        self.cocoapodsVersion = cocoapodsVersion
        self.moduleName = moduleName
        self.headerDir = headerDir
        self.moduleMap = moduleMap
        self.staticFramework = staticFramework
        self.attributes = Attributes(
            sourceFiles: sourceFiles, excludeFiles: excludeFiles, publicHeaderFiles: publicHeaderFiles,
            privateHeaderFiles: privateHeaderFiles, resources: resources, resourceBundles: resourceBundles,
            vendoredFrameworks: vendoredFrameworks, vendoredLibraries: vendoredLibraries, frameworks: frameworks,
            weakFrameworks: weakFrameworks, libraries: libraries, compilerFlags: compilerFlags,
            podTargetXCConfig: podTargetXCConfig, userTargetXCConfig: userTargetXCConfig,
            preservePaths: preservePaths, requiresARC: requiresARC, dependencies: dependencies
        )
        self.scriptPhases = scriptPhases
        self.platformSpecific = platformSpecific
        self.defaultSubspecs = defaultSubspecs
        self.subspecs = subspecs
        self.testSpecs = testSpecs
        self.appSpecs = appSpecs
        _ManifestRegistry.register(.spec(self))
    }

    var json: _JSON {
        var object: [(String, _JSON)] = [("name", .string(name)), ("version", .string(version))]
        func string(_ key: String, _ value: String?) { if let value { object.append((key, .string(value))) } }
        string("summary", summary)
        string("description", description)
        string("homepage", homepage)
        if let license { object.append(("license", license.json)) }
        if !authors.isEmpty { object.append(("authors", _JSON.sortedObject(authors.mapValues(_JSON.string)))) }
        if let source { object.append(("source", source.json)) }
        string("social_media_url", socialMediaURL)
        string("documentation_url", documentationURL)
        if !platforms.isEmpty { object.append(("platforms", .object(platforms.map { ($0.name, $0.version.map(_JSON.string) ?? .null) }))) }
        if !swiftVersions.isEmpty { object.append(("swift_versions", .array(swiftVersions.map(_JSON.string)))) }
        string("cocoapods_version", cocoapodsVersion)
        string("module_name", moduleName)
        string("header_dir", headerDir)
        string("module_map", moduleMap)
        if let staticFramework { object.append(("static_framework", .bool(staticFramework))) }
        if let defaultSubspecs { object.append(("default_subspecs", .array(defaultSubspecs.map(_JSON.string)))) }
        if !scriptPhases.isEmpty { object.append(("script_phases", .array(scriptPhases.map(\.json)))) }
        object += attributes.jsonPairs
        object += platformSpecific.map { ($0.platform, .object($0.attributes.jsonPairs)) }
        if !subspecs.isEmpty { object.append(("subspecs", .array(subspecs.map(\.json)))) }
        if !testSpecs.isEmpty { object.append(("testspecs", .array(testSpecs.map(\.json)))) }
        if !appSpecs.isEmpty { object.append(("appspecs", .array(appSpecs.map(\.json)))) }
        return .object(object)
    }
}

// MARK: - Root attributes

extension PodSpec {
    public struct License: Sendable {
        public var type: String
        public var file: String?
        public var text: String?

        public init(type: String, file: String? = nil, text: String? = nil) {
            self.type = type
            self.file = file
            self.text = text
        }

        public static func mit(file: String? = "LICENSE") -> License { License(type: "MIT", file: file) }
        public static func apache2(file: String? = "LICENSE") -> License { License(type: "Apache-2.0", file: file) }
        public static func bsd(file: String? = "LICENSE") -> License { License(type: "BSD", file: file) }

        var json: _JSON {
            var pairs: [(String, _JSON)] = [("type", .string(type))]
            if let file { pairs.append(("file", .string(file))) }
            if let text { pairs.append(("text", .string(text))) }
            return .object(pairs)
        }
    }

    /// Where the pod's files are downloaded from (`s.source`).
    public enum SourceLocation: Sendable {
        case git(url: String, tag: String? = nil, branch: String? = nil, commit: String? = nil, submodules: Bool = false)
        case http(url: String, type: String? = nil, sha256: String? = nil)

        var json: _JSON {
            switch self {
            case .git(let url, let tag, let branch, let commit, let submodules):
                var object: [(String, _JSON)] = [("git", .string(url))]
                if let tag { object.append(("tag", .string(tag))) }
                if let branch { object.append(("branch", .string(branch))) }
                if let commit { object.append(("commit", .string(commit))) }
                if submodules { object.append(("submodules", .bool(true))) }
                return .object(object)
            case .http(let url, let type, let sha256):
                var object: [(String, _JSON)] = [("http", .string(url))]
                if let type { object.append(("type", .string(type))) }
                if let sha256 { object.append(("sha256", .string(sha256))) }
                return .object(object)
            }
        }
    }

    public struct ScriptPhase: Sendable {
        public enum Position: String, Sendable {
            case beforeCompile = "before_compile", afterCompile = "after_compile", any
        }

        public var name: String
        public var script: String
        public var shellPath: String
        public var inputFiles: [String]
        public var outputFiles: [String]
        public var position: Position

        public init(name: String, script: String, shellPath: String = "/bin/sh", inputFiles: [String] = [], outputFiles: [String] = [], position: Position = .any) {
            self.name = name
            self.script = script
            self.shellPath = shellPath
            self.inputFiles = inputFiles
            self.outputFiles = outputFiles
            self.position = position
        }

        var json: _JSON {
            .object([
                ("name", .string(name)), ("script", .string(script)), ("shell_path", .string(shellPath)),
                ("input_files", .array(inputFiles.map(_JSON.string))), ("output_files", .array(outputFiles.map(_JSON.string))),
                ("execution_position", .string(position.rawValue)),
            ])
        }
    }

    /// A dependency of a spec on another pod. External sources are not allowed in podspecs.
    public struct Dependency: Sendable {
        let name: String
        let constraints: [String]

        public static func pod(name: String, _ requirement: VersionRequirement? = nil) -> Dependency {
            Dependency(name: name, constraints: requirement?.constraints ?? [])
        }

        public static func pod(name: String, from version: String) -> Dependency {
            .pod(name: name, .upToNextMajor(from: version))
        }

        public static func pod(name: String, exact version: String) -> Dependency {
            .pod(name: name, .exact(version))
        }

        public static func pod(name: String, _ range: Range<String>) -> Dependency {
            .pod(name: name, .range(range))
        }
    }
}

// MARK: - Shared attributes

extension PodSpec {
    /// Files, build settings and dependencies, shared by root specs, subspecs and platform overrides.
    public struct Attributes: Sendable {
        public var sourceFiles: [String]
        public var excludeFiles: [String]
        public var publicHeaderFiles: [String]
        public var privateHeaderFiles: [String]
        public var resources: [String]
        public var resourceBundles: [String: [String]]
        public var vendoredFrameworks: [String]
        public var vendoredLibraries: [String]
        public var frameworks: [String]
        public var weakFrameworks: [String]
        public var libraries: [String]
        public var compilerFlags: [String]
        public var podTargetXCConfig: [String: String]
        public var userTargetXCConfig: [String: String]
        public var preservePaths: [String]
        public var requiresARC: Bool?
        public var dependencies: [Dependency]

        public init(
            sourceFiles: [String] = [], excludeFiles: [String] = [], publicHeaderFiles: [String] = [],
            privateHeaderFiles: [String] = [], resources: [String] = [], resourceBundles: [String: [String]] = [:],
            vendoredFrameworks: [String] = [], vendoredLibraries: [String] = [], frameworks: [String] = [],
            weakFrameworks: [String] = [], libraries: [String] = [], compilerFlags: [String] = [],
            podTargetXCConfig: [String: String] = [:], userTargetXCConfig: [String: String] = [:],
            preservePaths: [String] = [], requiresARC: Bool? = nil, dependencies: [Dependency] = []
        ) {
            self.sourceFiles = sourceFiles
            self.excludeFiles = excludeFiles
            self.publicHeaderFiles = publicHeaderFiles
            self.privateHeaderFiles = privateHeaderFiles
            self.resources = resources
            self.resourceBundles = resourceBundles
            self.vendoredFrameworks = vendoredFrameworks
            self.vendoredLibraries = vendoredLibraries
            self.frameworks = frameworks
            self.weakFrameworks = weakFrameworks
            self.libraries = libraries
            self.compilerFlags = compilerFlags
            self.podTargetXCConfig = podTargetXCConfig
            self.userTargetXCConfig = userTargetXCConfig
            self.preservePaths = preservePaths
            self.requiresARC = requiresARC
            self.dependencies = dependencies
        }

        var jsonPairs: [(String, _JSON)] {
            var object: [(String, _JSON)] = []
            func list(_ key: String, _ values: [String]) {
                if !values.isEmpty { object.append((key, .array(values.map(_JSON.string)))) }
            }
            func dictionary(_ key: String, _ values: [String: String]) {
                if !values.isEmpty { object.append((key, _JSON.sortedObject(values.mapValues(_JSON.string)))) }
            }
            list("source_files", sourceFiles)
            list("exclude_files", excludeFiles)
            list("public_header_files", publicHeaderFiles)
            list("private_header_files", privateHeaderFiles)
            list("resources", resources)
            if !resourceBundles.isEmpty {
                object.append(("resource_bundles", _JSON.sortedObject(resourceBundles.mapValues { .array($0.map(_JSON.string)) })))
            }
            list("vendored_frameworks", vendoredFrameworks)
            list("vendored_libraries", vendoredLibraries)
            list("frameworks", frameworks)
            list("weak_frameworks", weakFrameworks)
            list("libraries", libraries)
            list("compiler_flags", compilerFlags)
            dictionary("pod_target_xcconfig", podTargetXCConfig)
            dictionary("user_target_xcconfig", userTargetXCConfig)
            list("preserve_paths", preservePaths)
            if let requiresARC { object.append(("requires_arc", .bool(requiresARC))) }
            if !dependencies.isEmpty {
                object.append(("dependencies", .object(dependencies.map { ($0.name, .array($0.constraints.map(_JSON.string))) })))
            }
            return object
        }
    }

    /// Attributes for a single platform, e.g. `.iOS(frameworks: ["UIKit"])`.
    public struct PlatformAttributes: Sendable {
        let platform: String
        public var attributes: Attributes

        public static func iOS(_ attributes: Attributes) -> PlatformAttributes { .init(platform: "ios", attributes: attributes) }
        public static func macOS(_ attributes: Attributes) -> PlatformAttributes { .init(platform: "osx", attributes: attributes) }
        public static func tvOS(_ attributes: Attributes) -> PlatformAttributes { .init(platform: "tvos", attributes: attributes) }
        public static func watchOS(_ attributes: Attributes) -> PlatformAttributes { .init(platform: "watchos", attributes: attributes) }
        public static func visionOS(_ attributes: Attributes) -> PlatformAttributes { .init(platform: "visionos", attributes: attributes) }
    }

    /// A subspec (`s.subspec 'Core' do |core| ... end`) or app spec.
    public struct Subspec: Sendable {
        public var name: String
        public var platforms: [SupportedPlatform]
        public var attributes: Attributes
        public var platformSpecific: [PlatformAttributes]
        public var defaultSubspecs: [String]?
        public var subspecs: [Subspec]

        public static func subspec(
            name: String,
            platforms: [SupportedPlatform] = [],
            sourceFiles: [String] = [],
            excludeFiles: [String] = [],
            publicHeaderFiles: [String] = [],
            privateHeaderFiles: [String] = [],
            resources: [String] = [],
            resourceBundles: [String: [String]] = [:],
            vendoredFrameworks: [String] = [],
            vendoredLibraries: [String] = [],
            frameworks: [String] = [],
            weakFrameworks: [String] = [],
            libraries: [String] = [],
            compilerFlags: [String] = [],
            podTargetXCConfig: [String: String] = [:],
            userTargetXCConfig: [String: String] = [:],
            preservePaths: [String] = [],
            requiresARC: Bool? = nil,
            dependencies: [Dependency] = [],
            platformSpecific: [PlatformAttributes] = [],
            defaultSubspecs: [String]? = nil,
            subspecs: [Subspec] = []
        ) -> Subspec {
            Subspec(
                name: name, platforms: platforms,
                attributes: Attributes(
                    sourceFiles: sourceFiles, excludeFiles: excludeFiles, publicHeaderFiles: publicHeaderFiles,
                    privateHeaderFiles: privateHeaderFiles, resources: resources, resourceBundles: resourceBundles,
                    vendoredFrameworks: vendoredFrameworks, vendoredLibraries: vendoredLibraries, frameworks: frameworks,
                    weakFrameworks: weakFrameworks, libraries: libraries, compilerFlags: compilerFlags,
                    podTargetXCConfig: podTargetXCConfig, userTargetXCConfig: userTargetXCConfig,
                    preservePaths: preservePaths, requiresARC: requiresARC, dependencies: dependencies
                ),
                platformSpecific: platformSpecific, defaultSubspecs: defaultSubspecs, subspecs: subspecs
            )
        }

        var json: _JSON {
            var object: [(String, _JSON)] = [("name", .string(name))]
            if !platforms.isEmpty { object.append(("platforms", .object(platforms.map { ($0.name, $0.version.map(_JSON.string) ?? .null) }))) }
            if let defaultSubspecs { object.append(("default_subspecs", .array(defaultSubspecs.map(_JSON.string)))) }
            object += attributes.jsonPairs
            object += platformSpecific.map { ($0.platform, .object($0.attributes.jsonPairs)) }
            if !subspecs.isEmpty { object.append(("subspecs", .array(subspecs.map(\.json)))) }
            return .object(object)
        }
    }

    /// A test spec (`s.test_spec 'Tests' do |t| ... end`).
    public struct TestSpec: Sendable {
        public enum TestType: String, Sendable { case unit, ui }

        public var name: String
        public var testType: TestType
        public var requiresAppHost: Bool
        public var attributes: Attributes

        public static func testSpec(
            name: String = "Tests",
            testType: TestType = .unit,
            requiresAppHost: Bool = false,
            sourceFiles: [String] = [],
            resources: [String] = [],
            frameworks: [String] = [],
            podTargetXCConfig: [String: String] = [:],
            dependencies: [Dependency] = []
        ) -> TestSpec {
            TestSpec(
                name: name, testType: testType, requiresAppHost: requiresAppHost,
                attributes: Attributes(sourceFiles: sourceFiles, resources: resources, frameworks: frameworks,
                                       podTargetXCConfig: podTargetXCConfig, dependencies: dependencies)
            )
        }

        var json: _JSON {
            var object: [(String, _JSON)] = [("name", .string(name)), ("test_type", .string(testType.rawValue))]
            if requiresAppHost { object.append(("requires_app_host", .bool(true))) }
            object += attributes.jsonPairs
            return .object(object)
        }
    }
}
