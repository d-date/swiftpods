import Foundation
import PodsCore
@testable import PodsInstaller
import Testing

/// Acceptance tests against the real ML Kit pods (the setup of google-mlkit-swiftpm): the Google libraries that
/// ML Kit's prebuilt binaries depend on come from SwiftPM instead of being built as pods.
/// Uses the network (CDN, GitHub, dl.google.com), so opt-in: `SWIFTPODS_MLKIT=1 swift test`.
/// `SWIFTPODS_MLKIT_CACHE` sets a persistent download cache for reruns.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTPODS_MLKIT"] == "1"))
struct MLKitAcceptanceTests {
    static let subspecs = [
        "FaceDetection", "BarcodeScanning",
        "TextRecognition", "TextRecognitionChinese", "TextRecognitionDevanagari", "TextRecognitionJapanese", "TextRecognitionKorean",
        "ImageLabeling", "ImageLabelingCustom", "ObjectDetection", "ObjectDetectionCustom",
        "PoseDetection", "PoseDetectionAccurate", "SegmentationSelfie",
        "DigitalInkRecognition", "EntityExtraction", "LanguageID", "Translate", "SmartReply",
    ]

    let root: URL
    let cache: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-mlkit-\(UUID().uuidString)")
        let persistent = ProcessInfo.processInfo.environment["SWIFTPODS_MLKIT_CACHE"].map { URL(fileURLWithPath: $0) }
        cache = persistent ?? root.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try FixtureProject.create(in: root, deploymentTarget: "15.5")
    }

    /// Writes the ML Kit `Podfile.swift` for target `App`, declaring gtm-session-fetcher with `gtmRange`.
    private func writePodfile(gtmRange: String = #""3.5.0"..<"6.0.0""#) throws {
        let pods = Self.subspecs.map { #"                .pod(name: "GoogleMLKit/\#($0)", "~> 9.0.0"),"# }.joined(separator: "\n")
        try """
        import SwiftPodsDescription

        let podfile = Podfile(
            platform: .iOS("15.5"),
            useFrameworks: .static,
            packages: [
                .package(url: "https://github.com/google/promises.git", from: "2.4.0"),
                .package(url: "https://github.com/google/GoogleDataTransport.git", from: "10.1.0"),
                .package(url: "https://github.com/google/GoogleUtilities.git", from: "8.1.0"),
                .package(url: "https://github.com/google/gtm-session-fetcher.git", \(gtmRange)),
                .package(url: "https://github.com/firebase/nanopb.git", .upToNextMinor(from: "2.30910.0")),
            ],
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

    private func context() throws -> InstallerContext {
        try InstallerContext(projectDirectory: root, cacheRoot: cache, ui: .capturing())
    }

    @Test func mlkitPodsUnifyOnSwiftPM() async throws {
        try writePodfile()
        let analysis = try await Analyzer(context: try context(), options: InstallOptions()).analyze()
        let pods = Set(analysis.pods.map(\.name))
        for unified in ["GoogleUtilities", "GoogleDataTransport", "GTMSessionFetcher", "nanopb", "PromisesObjC"] {
            #expect(!pods.contains(unified), "\(unified) should come from SwiftPM")
        }
        #expect(pods.contains("GoogleToolboxForMac"))
        #expect(pods.contains("SSZipArchive"))

        // MLKitCommon requires GTMSessionFetcher/Core `< 4.0`, which bounds the declared `3.5.0..<6.0.0`.
        let gtm = try #require(analysis.unifications.first { $0.podRoot == "GTMSessionFetcher" })
        #expect(gtm.upperBound <= Version(4, 0, 0))
        // Pod nanopb 3.30910.x is tagged at the same commits as package nanopb 2.30910.x.
        let nanopb = try #require(analysis.swiftPackages?.pins.first { $0.identity == "nanopb" })
        #expect(nanopb.version.major == 2)

        try await Installer(context: try context(), options: InstallOptions()).install()
    }

    @Test func mlkitRejectsGTM4() async throws {
        try writePodfile(gtmRange: #""4.0.0"..<"6.0.0""#)
        let error = await #expect(throws: PodsError.self) {
            try await Analyzer(context: try context(), options: InstallOptions()).analyze()
        }
        let message = error?.message ?? ""
        #expect(message.contains("MLKitCommon"), "\(message)")
        #expect(message.contains("< 4.0"), "\(message)")
    }

    /// Builds the integrated app: CocoaPods' `-ObjC` loads every ML Kit object file, so any symbol the
    /// prebuilt binaries expect from the SwiftPM packages must be linked (exactly once).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTPODS_XCODEBUILD"] == "1"))
    func mlkitAppLinks() async throws {
        try writePodfile()
        try await Installer(context: try context(), options: InstallOptions()).install()
        try """
        import MLKitBarcodeScanning
        import SwiftUI

        @main
        struct FixtureApp: App {
            init() { _ = BarcodeScanner.barcodeScanner() }
            var body: some Scene { WindowGroup { Text("Hello") } }
        }
        """.write(to: root.appendingPathComponent("App/App.swift"), atomically: true, encoding: .utf8)

        let output = try await Shell().execute([
            "xcodebuild", "-workspace", "App.xcworkspace", "-scheme", "App", "-configuration", "Debug",
            "-sdk", "iphonesimulator", "-derivedDataPath", root.appendingPathComponent("DerivedData").path,
            "CODE_SIGNING_ALLOWED=NO", "build",
        ], in: root)
        let log = output.stdout + output.stderr
        #expect(output.status == 0, "\(output.stdout.suffix(4000))\n\(output.stderr.suffix(2000))")
        #expect(!log.contains("duplicate symbol"))
        #expect(!log.contains("Undefined symbols"))
    }
}
