@testable import PodsInstaller
import Testing

struct DistributionLayoutTests {
    // Edges copied from google-mlkit-swiftpm 9.0's Podfile.lock (PODS: section, version constraints dropped).
    static let mlKitDependencies: [String: [String]] = [
        "GoogleDataTransport": ["nanopb", "PromisesObjC"],
        "GoogleMLKit/BarcodeScanning": ["GoogleMLKit/MLKitCore", "MLKitBarcodeScanning"],
        "GoogleMLKit/DigitalInkRecognition": ["GoogleMLKit/MLKitCore", "MLKitDigitalInkRecognition"],
        "GoogleMLKit/EntityExtraction": ["GoogleMLKit/MLKitCore", "MLKitEntityExtraction"],
        "GoogleMLKit/FaceDetection": ["GoogleMLKit/MLKitCore", "MLKitFaceDetection"],
        "GoogleMLKit/ImageLabeling": ["GoogleMLKit/MLKitCore", "MLKitImageLabeling"],
        "GoogleMLKit/ImageLabelingCustom": ["GoogleMLKit/MLKitCore", "MLKitImageLabelingCustom"],
        "GoogleMLKit/LanguageID": ["GoogleMLKit/MLKitCore", "MLKitLanguageID"],
        "GoogleMLKit/MLKitCore": ["MLKitCommon"],
        "GoogleMLKit/ObjectDetection": ["GoogleMLKit/MLKitCore", "MLKitObjectDetection"],
        "GoogleMLKit/ObjectDetectionCustom": ["GoogleMLKit/MLKitCore", "MLKitObjectDetectionCustom"],
        "GoogleMLKit/PoseDetection": ["GoogleMLKit/MLKitCore", "MLKitPoseDetection"],
        "GoogleMLKit/PoseDetectionAccurate": ["GoogleMLKit/MLKitCore", "MLKitPoseDetectionAccurate"],
        "GoogleMLKit/SegmentationSelfie": ["GoogleMLKit/MLKitCore", "MLKitSegmentationSelfie"],
        "GoogleMLKit/SmartReply": ["GoogleMLKit/MLKitCore", "MLKitSmartReply"],
        "GoogleMLKit/TextRecognition": ["GoogleMLKit/MLKitCore", "MLKitTextRecognition"],
        "GoogleMLKit/TextRecognitionChinese": ["GoogleMLKit/MLKitCore", "MLKitTextRecognitionChinese"],
        "GoogleMLKit/TextRecognitionDevanagari": ["GoogleMLKit/MLKitCore", "MLKitTextRecognitionDevanagari"],
        "GoogleMLKit/TextRecognitionJapanese": ["GoogleMLKit/MLKitCore", "MLKitTextRecognitionJapanese"],
        "GoogleMLKit/TextRecognitionKorean": ["GoogleMLKit/MLKitCore", "MLKitTextRecognitionKorean"],
        "GoogleMLKit/Translate": ["GoogleMLKit/MLKitCore", "MLKitTranslate"],
        "GoogleToolboxForMac/Defines": [],
        "GoogleToolboxForMac/Logger": ["GoogleToolboxForMac/Defines"],
        "GoogleToolboxForMac/NSData+zlib": ["GoogleToolboxForMac/Defines"],
        "GoogleToolboxForMac/StringEncoding": ["GoogleToolboxForMac/Defines"],
        "GoogleUtilities/Environment": ["GoogleUtilities/Privacy"],
        "GoogleUtilities/Logger": ["GoogleUtilities/Environment", "GoogleUtilities/Privacy"],
        "GoogleUtilities/Privacy": [],
        "GoogleUtilities/UserDefaults": ["GoogleUtilities/Logger", "GoogleUtilities/Privacy"],
        "GTMSessionFetcher/Core": [],
        "MLImage": [],
        "MLKitBarcodeScanning": ["MLKitCommon", "MLKitVision"],
        "MLKitCommon": ["GoogleDataTransport", "GoogleToolboxForMac/Logger", "GoogleToolboxForMac/NSData+zlib", "GoogleUtilities/Logger", "GoogleUtilities/UserDefaults", "GTMSessionFetcher/Core"],
        "MLKitDigitalInkRecognition": ["MLKitCommon", "MLKitMDD", "SSZipArchive"],
        "MLKitEntityExtraction": ["MLKitNaturalLanguage"],
        "MLKitFaceDetection": ["MLKitCommon", "MLKitVision"],
        "MLKitImageLabeling": ["MLKitCommon", "MLKitImageLabelingCommon", "MLKitVision", "MLKitVisionKit"],
        "MLKitImageLabelingCommon": ["MLKitCommon", "MLKitVision"],
        "MLKitImageLabelingCustom": ["MLKitCommon", "MLKitImageLabelingCommon", "MLKitVision", "MLKitVisionKit"],
        "MLKitLanguageID": ["MLKitNaturalLanguage"],
        "MLKitMDD": ["MLKitCommon"],
        "MLKitNaturalLanguage": ["GoogleToolboxForMac/Logger", "GoogleToolboxForMac/NSData+zlib", "GoogleToolboxForMac/StringEncoding", "GTMSessionFetcher/Core", "MLKitCommon"],
        "MLKitObjectDetection": ["MLKitCommon", "MLKitObjectDetectionCommon", "MLKitVision", "MLKitVisionKit"],
        "MLKitObjectDetectionCommon": ["MLKitCommon", "MLKitVision"],
        "MLKitObjectDetectionCustom": ["MLKitCommon", "MLKitObjectDetectionCommon", "MLKitVision", "MLKitVisionKit"],
        "MLKitPoseDetection": ["MLKitCommon", "MLKitPoseDetectionCommon", "MLKitXenoCommon"],
        "MLKitPoseDetectionAccurate": ["MLKitCommon", "MLKitPoseDetectionCommon", "MLKitXenoCommon"],
        "MLKitPoseDetectionCommon": ["MLKitCommon", "MLKitXenoCommon"],
        "MLKitSegmentationCommon": ["MLKitCommon", "MLKitXenoCommon"],
        "MLKitSegmentationSelfie": ["MLKitSegmentationCommon"],
        "MLKitSmartReply": ["MLKitLanguageID", "MLKitNaturalLanguage"],
        "MLKitTextRecognition": ["MLKitCommon", "MLKitTextRecognitionCommon", "MLKitVision"],
        "MLKitTextRecognitionChinese": ["MLKitCommon", "MLKitTextRecognitionCommon", "MLKitVision"],
        "MLKitTextRecognitionCommon": ["MLKitCommon", "MLKitVision"],
        "MLKitTextRecognitionDevanagari": ["MLKitCommon", "MLKitTextRecognitionCommon", "MLKitVision"],
        "MLKitTextRecognitionJapanese": ["MLKitCommon", "MLKitTextRecognitionCommon", "MLKitVision"],
        "MLKitTextRecognitionKorean": ["MLKitCommon", "MLKitTextRecognitionCommon", "MLKitVision"],
        "MLKitTranslate": ["MLKitNaturalLanguage", "SSZipArchive"],
        "MLKitVision": ["GoogleToolboxForMac/Logger", "GoogleToolboxForMac/NSData+zlib", "GTMSessionFetcher/Core", "MLImage", "MLKitCommon"],
        "MLKitVisionKit": ["MLKitCommon", "MLKitImageLabelingCommon", "MLKitObjectDetectionCommon", "MLKitVision"],
        "MLKitXenoCommon": ["MLKitCommon", "MLKitVision"],
        "nanopb": ["nanopb/decode", "nanopb/encode"],
        "nanopb/decode": [],
        "nanopb/encode": [],
        "PromisesObjC": [],
        "SSZipArchive": [],
    ]

    static let gulURL = "https://github.com/google/GoogleUtilities.git"
    static let nanopbURL = "https://github.com/firebase/nanopb.git"

    static var mlKitBinaries: Set<String> {
        var names = Set(mlKitDependencies.keys.map { String($0.split(separator: "/")[0]) }.filter { $0.hasPrefix("MLKit") || $0 == "MLImage" })
        names.formUnion(["GoogleToolboxForMac", "SSZipArchive"])
        return names
    }

    @Test func derivesMLKitShapedProducts() {
        let layout = DistributionLayout.derive(
            declared: [
                "GoogleMLKit/BarcodeScanning", "GoogleMLKit/DigitalInkRecognition",
                "GoogleMLKit/LanguageID", "GoogleMLKit/PoseDetectionAccurate",
            ],
            dependencies: Self.mlKitDependencies,
            podsWithBinary: Self.mlKitBinaries,
            unified: ["GoogleUtilities": Self.gulURL, "nanopb": Self.nanopbURL]
        )
        #expect(layout.products.map(\.name) == ["MLKitBarcodeScanning", "MLKitDigitalInkRecognition", "MLKitLanguageID", "MLKitPoseDetectionAccurate"])
        #expect(layout.commonTargets == ["GoogleToolboxForMac", "MLKitCommon"])
        #expect(layout.products[3].targets == ["MLKitPoseDetectionAccurate", "MLImage", "MLKitPoseDetectionCommon", "MLKitVision", "MLKitXenoCommon", "Common"])
        #expect(!layout.products[2].targets.contains("MLKitXenoCommon"))
        #expect(layout.unifiedPackageURLs == [Self.gulURL, Self.nanopbURL].sorted())
        #expect(layout.binaryTargets.contains("SSZipArchive"))
        #expect(!layout.binaryTargets.contains("GoogleUtilities"))
        #expect(layout.warnings.isEmpty)
    }

    @Test func skipsProductWithoutBinaryTargets() {
        let layout = DistributionLayout.derive(
            declared: ["Umbrella/Only", "Real"],
            dependencies: ["Umbrella/Only": ["Unified"], "Real": []],
            podsWithBinary: ["Real"],
            unified: ["Unified": "https://example.com/unified.git"]
        )
        #expect(layout.products.map(\.name) == ["Real"])
        #expect(layout.warnings.count == 1)
        #expect(layout.warnings.first?.contains("Umbrella/Only") == true)
        #expect(layout.unifiedPackageURLs == ["https://example.com/unified.git"])
    }

    @Test func severalDirectBinaryDependenciesWarn() {
        let layout = DistributionLayout.derive(
            declared: ["Umbrella/Both"],
            dependencies: ["Umbrella/Both": ["Zeta", "Alpha"], "Alpha": [], "Zeta": []],
            podsWithBinary: ["Alpha", "Zeta"],
            unified: [:]
        )
        #expect(layout.products.map(\.name) == ["Alpha"])
        #expect(layout.warnings.count == 1)
        #expect(layout.warnings.first?.contains("Zeta") == true)
    }

    @Test func declaredUmbrellaRootWithoutBinaryUsesItsBinaryDependency() {
        let layout = DistributionLayout.derive(
            declared: ["Umbrella", "Empty"],
            dependencies: ["Umbrella": ["Leaf", "Shared"], "Leaf": ["Shared"], "Shared": [], "Empty": []],
            podsWithBinary: ["Leaf", "Shared"],
            unified: [:]
        )
        // Umbrella has no binary of its own, so it is never a target; Leaf becomes the product.
        #expect(layout.products.map(\.name) == ["Leaf"])
        #expect(layout.products.first?.targets == ["Leaf", "Common"])
        #expect(layout.commonTargets == ["Shared"])
        #expect(layout.warnings.count == 2)
        #expect(layout.warnings.contains { $0.contains("Umbrella") && $0.contains("Shared") })
        #expect(layout.warnings.contains { $0.contains("Empty") })
    }

    @Test func unifiedPodsAreNeverBinaryTargetsOrProducts() {
        let url = "https://example.com/unified.git"
        let layout = DistributionLayout.derive(
            declared: ["Umbrella/Sub", "Real"],
            dependencies: ["Umbrella/Sub": ["Unified"], "Real": ["Unified"], "Unified": []],
            podsWithBinary: ["Real", "Unified"],
            unified: ["Unified": url]
        )
        #expect(layout.products.map(\.name) == ["Real"])
        #expect(layout.products.first?.targets == ["Real", "Common"])
        #expect(layout.commonTargets.isEmpty)
        #expect(layout.binaryTargets == ["Real"])
        #expect(layout.unifiedPackageURLs == [url])
        #expect(layout.warnings.count == 1)
    }

    @Test func singleProductPutsTheRestOfItsClosureInCommon() {
        let layout = DistributionLayout.derive(
            declared: ["Main"],
            dependencies: ["Main": ["Base", "Extra"], "Base": [], "Extra": []],
            podsWithBinary: ["Main", "Base", "Extra"],
            unified: [:]
        )
        #expect(layout.commonTargets == ["Base", "Extra"])
        #expect(layout.products.first?.targets == ["Main", "Common"])
    }

    @Test func nestedProductStaysATargetOfTheProductThatDependsOnIt() {
        let layout = DistributionLayout.derive(
            declared: ["A", "B"],
            dependencies: ["A": ["Base"], "B": ["A", "Base", "Own"], "Base": [], "Own": []],
            podsWithBinary: ["A", "B", "Base", "Own"],
            unified: [:]
        )
        #expect(layout.commonTargets == ["Base"])
        #expect(layout.products.map(\.targets) == [["A", "Common"], ["B", "A", "Own", "Common"]])
    }
}
