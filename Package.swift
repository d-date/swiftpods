// swift-tools-version: 6.4
import PackageDescription

// Strict Swift 6 language mode plus upcoming features we want to adopt early.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "swiftpods",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "swiftpods", targets: ["SwiftPodsCLI"]),
        .library(name: "SwiftPodsKit", targets: ["PodsInstaller"]),
        // The API imported by `Podfile.swift` / `*.podspec.swift`, for editor support.
        .library(name: "SwiftPodsDescription", targets: ["SwiftPodsDescription"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
        .package(url: "https://github.com/tuist/XcodeProj.git", from: "9.0.0"),
    ],
    targets: [
        // Foundation types shared by every module: versions, requirements, platforms, shell.
        .target(name: "PodsCore"),
        // A small evaluator for the Ruby subset used by Podfiles and podspecs.
        .target(name: "PodsDSL", dependencies: ["PodsCore"]),
        // Podspec model (JSON + Ruby DSL) and per-platform attribute resolution.
        .target(name: "PodsSpec", dependencies: ["PodsCore", "PodsDSL"]),
        // Swift manifest API. Standard library only: it is compiled together with user manifests.
        .target(name: "SwiftPodsDescription"),
        // Compiles and runs Swift manifests. The description sources are embedded by a plugin.
        .target(
            name: "PodsManifest",
            dependencies: ["PodsCore", "PodsSpec"],
            plugins: ["EmbedDescriptionPlugin"]
        ),
        .executableTarget(name: "EmbedSources", path: "Plugins/EmbedSources"),
        .plugin(
            name: "EmbedDescriptionPlugin",
            capability: .buildTool(),
            dependencies: ["EmbedSources"]
        ),
        // Podfile model and DSL.
        .target(name: "PodsPodfile", dependencies: ["PodsCore", "PodsDSL", "PodsManifest"]),
        // Podfile.lock / Manifest.lock reading and writing.
        .target(name: "PodsLockfile", dependencies: ["PodsCore", "Yams"]),
        // Spec sources (CDN trunk, git spec repos, local paths).
        .target(name: "PodsSources", dependencies: ["PodsCore", "PodsSpec"]),
        // Dependency resolution.
        .target(name: "PodsResolver", dependencies: ["PodsCore", "PodsSpec", "PodsPodfile", "PodsSources"]),
        // Fetching pod sources (git / http / path) with a local cache.
        .target(name: "PodsDownloader", dependencies: ["PodsCore", "PodsSpec"]),
        // Installation pipeline: sandbox, Pods.xcodeproj generation, user project integration.
        .target(
            name: "PodsInstaller",
            dependencies: [
                "PodsCore", "PodsSpec", "PodsPodfile", "PodsLockfile", "PodsSources",
                "PodsResolver", "PodsDownloader", "PodsManifest",
                .product(name: "XcodeProj", package: "XcodeProj"),
            ]
        ),
        .executableTarget(
            name: "SwiftPodsCLI",
            dependencies: [
                "PodsCore", "PodsSpec", "PodsPodfile", "PodsSources", "PodsManifest", "PodsInstaller",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "PodsCoreTests", dependencies: ["PodsCore"]),
        .testTarget(name: "PodsDSLTests", dependencies: ["PodsDSL"]),
        .testTarget(name: "PodsSpecTests", dependencies: ["PodsSpec"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PodsPodfileTests", dependencies: ["PodsPodfile", "PodsManifest"]),
        .testTarget(name: "PodsManifestTests", dependencies: ["PodsManifest", "SwiftPodsDescription"]),
        .testTarget(name: "PodsLockfileTests", dependencies: ["PodsLockfile"]),
        .testTarget(name: "PodsSourcesTests", dependencies: ["PodsSources"]),
        .testTarget(name: "PodsResolverTests", dependencies: ["PodsResolver"]),
        .testTarget(name: "PodsDownloaderTests", dependencies: ["PodsDownloader"]),
        .testTarget(
            name: "PodsInstallerTests",
            dependencies: [
                "PodsInstaller", "PodsCore", "PodsSpec", "PodsPodfile", "PodsLockfile", "PodsSources",
                .product(name: "XcodeProj", package: "XcodeProj"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets where target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + swiftSettings
}
