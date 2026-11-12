import Foundation
import PodsCore
@testable import PodsInstaller
import PodsSpec
import Testing

struct FileAccessorTests {
    /// GoogleToolboxForMac 4.2.1: `Defines` declares `public_header_files`, `Logger` doesn't.
    /// CocoaPods evaluates the attribute per spec, so `GTMLogger.h` is public too.
    @Test func publicHeaderFilesApplyPerSubspec() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-fa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["GTMDefines.h", "Foundation/GTMLogger.h", "Foundation/GTMLogger.m", "Foundation/GTMLogger+Private.h"] {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let spec = try Specification(json: JSON(parsing: """
        {"name": "GoogleToolboxForMac", "version": "4.2.1", "platforms": {"ios": "9.0"},
         "subspecs": [
           {"name": "Defines", "public_header_files": "GTMDefines.h", "source_files": "GTMDefines.h"},
           {"name": "Logger", "source_files": "Foundation/GTMLogger*.{h,m}", "private_header_files": "Foundation/GTMLogger+Private.h"}
         ]}
        """))
        let specs = try ["GoogleToolboxForMac/Defines", "GoogleToolboxForMac/Logger"].map { try #require(spec.subspec(named: $0)) }
        let files = FileAccessor(root: root, specs: specs, platform: .ios)

        #expect(files.publicHeaders.sorted() == ["Foundation/GTMLogger.h", "GTMDefines.h"])
        #expect(files.privateHeaders == ["Foundation/GTMLogger+Private.h"])
        #expect(files.projectHeaders.isEmpty)
    }
}
