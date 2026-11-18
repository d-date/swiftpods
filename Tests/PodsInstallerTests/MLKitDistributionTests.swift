import Foundation
import PodsCore
@testable import PodsInstaller
import Testing

/// Acceptance test of `swiftpods package` against the real ML Kit pods: regenerates google-mlkit-swiftpm's
/// distribution (release 9.0.3) from a Podfile.swift and compares the generated `Package.swift` with the one
/// published at tag `9.0.3`.
///
/// Uses the network (CDN, GitHub, dl.google.com) and builds the pods and 19 × 2 verification apps, so opt-in:
/// `SWIFTPODS_MLKIT=1 SWIFTPODS_XCODEBUILD=1 swift test --filter MLKitDistributionTests`.
/// `SWIFTPODS_MLKIT_CACHE` sets a persistent download cache for reruns.
///
/// Example app (manual check, 2026-11-17, Xcode 27.2): the Example app at tag `9.0.3` (iOS 26, all 19 products
/// plus Firebase 13.1.1) builds for `generic/platform=iOS Simulator` against the generated package with local
/// binary targets: the tag's checkout with the generated `Package.swift` (binary targets turned into `path:`),
/// `Sources/Common` and the unzipped xcframeworks in place of the repository's. SwiftPM resolved nanopb 2.30910.1
/// and gtm-session-fetcher 5.3.1, both inside the unsafe overrides only. Not automated: it needs the full
/// Firebase graph and adds about two minutes.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTPODS_MLKIT"] == "1"
    && ProcessInfo.processInfo.environment["SWIFTPODS_XCODEBUILD"] == "1"))
struct MLKitDistributionTests {
    static let referenceRepository = "https://github.com/d-date/google-mlkit-swiftpm"
    static let referenceTag = "9.0.3"
    /// Targets the reference lists that the ML Kit 9.0 pod graph does not reach (accepted in the design).
    static let acceptedMissing: [String: Set<String>] = [
        "MLKitLanguageID": ["MLKitXenoCommon"],
        "MLKitTranslate": ["MLKitXenoCommon"],
        "MLKitSmartReply": ["MLKitXenoCommon"],
    ]
    /// The products of the unified packages that hold the code of the pod subspecs ML Kit 9.0 activates
    /// (GoogleUtilities Environment/Logger/UserDefaults, GTMSessionFetcher/Core, PromisesObjC, nanopb, GoogleDataTransport).
    static let expectedCommonProducts: Set<String> = [
        "GULEnvironment", "GULLogger", "GULUserDefaults", "GTMSessionFetcherCore", "FBLPromises", "nanopb", "GoogleDataTransport",
    ]

    let root: URL
    let cache: URL
    let shell = Shell()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-mlkit-distribution-\(UUID().uuidString)")
        let persistent = ProcessInfo.processInfo.environment["SWIFTPODS_MLKIT_CACHE"].map { URL(fileURLWithPath: $0) }
        cache = persistent ?? root.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The `Podfile.swift` of `MLKitAcceptanceTests` plus `distribution`, targets not integrated, and the two
    /// unsafe overrides google-mlkit-swiftpm needs.
    private func writePodfile() throws {
        let pods = MLKitAcceptanceTests.subspecs.map { #"                .pod(name: "GoogleMLKit/\#($0)", "~> 9.0.0"),"# }.joined(separator: "\n")
        try """
        import SwiftPodsDescription

        let podfile = Podfile(
            platform: .iOS("15.5"),
            useFrameworks: .static,
            installationOptions: .init(integrateTargets: false),
            packages: [
                .package(url: "https://github.com/google/promises.git", from: "2.4.0"),
                .package(url: "https://github.com/google/GoogleDataTransport.git", from: "10.1.0"),
                .package(url: "https://github.com/google/GoogleUtilities.git", from: "8.1.0"),
                .package(url: "https://github.com/google/gtm-session-fetcher.git", "3.5.0"..<"6.0.0",
                         overridingPodRequirements: .unsafe(reason: "ABI checked by hand for Firebase 13 (google-mlkit-swiftpm #124, #125)")),
                .package(url: "https://github.com/firebase/nanopb.git", "2.30910.0"..<"2.30911.0",
                         overridingPodRequirements: .unsafe(reason: "Firebase 13.1.1 requires 2.30910.1, a fork commit of the pods' 2.30910.0")),
            ],
            distribution: .init(name: "GoogleMLKitSwiftPM", url: "\(Self.referenceRepository)"),
            targets: [
                .target(
                    name: "App",
                    dependencies: [
        \(pods)
                    ]
                ),
            ]
        )
        """.write(to: root.appendingPathComponent("Podfile.swift"), atomically: true, encoding: .utf8)
    }

    @Test func regeneratesGoogleMLKitSwiftPM() async throws {
        try writePodfile()
        let context = try InstallerContext(projectDirectory: root, cacheRoot: cache, ui: .capturing())
        let clock = ContinuousClock()

        // Built without verification, then verified as `build()` does, to time the two separately.
        var output: URL!
        let buildTime = try await clock.measure {
            output = try await DistributionBuilder(context: context, options: DistributionOptions(version: Self.referenceTag, outputDirectory: nil, verify: false)).build()
        }
        let generatedText = try String(contentsOf: output.appendingPathComponent("Package.swift"), encoding: .utf8)
        let generated = try Manifest(generatedText)

        let verificationTime = try await clock.measure {
            try await ProductLinkVerifier(shell: shell, workDirectory: root.appendingPathComponent("build/work/verification"),
                                          deploymentTarget: Version(15, 5, 0))
                .verify(products: generated.products.map(\.name), packageDirectory: output)
        }
        print("ML Kit distribution: build \(buildTime), verification of \(generated.products.count) products \(verificationTime)")

        let checkout = root.appendingPathComponent("google-mlkit-swiftpm")
        try await shell.run("git", ["clone", "--quiet", "--depth", "1", "--branch", Self.referenceTag, Self.referenceRepository, checkout.path])
        let reference = try Manifest(String(contentsOf: checkout.appendingPathComponent("Package.swift"), encoding: .utf8))

        #expect(generated.products.count == 19)
        // Products follow the Podfile's declaration order, which differs from the hand-written manifest's.
        #expect(Set(generated.products.map(\.name)) == Set(reference.products.map(\.name)))
        #expect(Set(generated.binaryTargets.keys) == Set(reference.binaryTargets.keys))
        #expect(Set(generated.binaryTargets.values) == Set(reference.binaryTargets.values), "release asset URLs")
        #expect(!reference.commonMembers.isEmpty)
        #expect(generated.commonMembers == reference.commonMembers)
        #expect(generated.commonProducts == Self.expectedCommonProducts)

        let common = generated.commonMembers.union(reference.commonMembers)
        for product in reference.products {
            let ours = generated.products.first { $0.name == product.name }?.targets ?? []
            let expected = product.targets.subtracting(common).subtracting(Self.acceptedMissing[product.name] ?? [])
            #expect(ours.subtracting(common) == expected, "\(product.name)")
        }

        let warnings = generatedText.split(separator: "\n").filter { $0.hasPrefix("#warning(") }
        #expect(warnings.count == 2, "\(warnings)")
        #expect(warnings.contains { $0.contains("gtm-session-fetcher") }, "\(warnings)")
        #expect(warnings.contains { $0.contains("nanopb") }, "\(warnings)")
    }

    /// The parts of a distribution `Package.swift` the comparison needs, read with regexes from the layout both
    /// google-mlkit-swiftpm's hand-written manifest and swiftpods' renderer use.
    struct Manifest {
        struct Product { let name: String; let targets: Set<String> }

        let products: [Product]
        /// Binary target name to URL.
        let binaryTargets: [String: String]
        /// The binary targets `Common` depends on (not the Swift package products).
        let commonMembers: Set<String>
        /// The Swift package products `Common` depends on.
        let commonProducts: Set<String>

        init(_ text: String) throws {
            products = text.matches(of: #/\.library\(\s*name: "([^"]+)",\s*targets: \[([^\]]*)\]\)/#).map { match in
                Product(name: String(match.1), targets: Set(match.2.matches(of: #/"([^"]+)"/#).map { String($0.1) }))
            }
            binaryTargets = Dictionary(uniqueKeysWithValues: text.matches(of: #/\.binaryTarget\(\s*name: "([^"]+)",\s*url: "([^"]+)"/#).map {
                (String($0.1), String($0.2))
            })
            let common = try #require(text.firstMatch(of: #/name: "Common",\s*dependencies: \[([^\]]*)\]/#))
            commonMembers = Set(common.1.matches(of: #/^\s*"([^"]+)",/#.anchorsMatchLineEndings()).map { String($0.1) })
            commonProducts = Set(common.1.matches(of: #/\.product\(name: "([^"]+)"/#).map { String($0.1) })
        }
    }
}
