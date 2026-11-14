import Foundation
import PodsCore
@testable import PodsLockfile
import Testing

let sampleLockfile = """
PODS:
  - Alamofire (5.9.1)
  - Firebase/CoreOnly (11.0.0):
    - FirebaseCore (= 11.0.0)
  - FirebaseCore (11.0.0):
    - FirebaseCoreInternal (~> 11.0)
  - MyKit (1.0.0):
    - Alamofire (~> 5.9)
  - Nuke (12.0.0)

DEPENDENCIES:
  - Alamofire (~> 5.9)
  - Firebase/CoreOnly
  - MyKit (from `../MyKit`)
  - Nuke (from `https://github.com/kean/Nuke.git`, tag `12.0.0`)

SPEC REPOS:
  trunk:
    - Alamofire
    - Firebase
    - FirebaseCore

EXTERNAL SOURCES:
  MyKit:
    :path: "../MyKit"
  Nuke:
    :git: https://github.com/kean/Nuke.git
    :tag: 12.0.0

CHECKOUT OPTIONS:
  Nuke:
    :git: https://github.com/kean/Nuke.git
    :tag: 12.0.0

SPEC CHECKSUMS:
  Alamofire: f36a35757af4587d8e4f4bfa223ad10be2422b8c
  Firebase: 9f574c08c2396885b5e7e100ed4293d956218af9
  FirebaseCore: 3cf438f431f18c12cdf2aaf64434648b63f7e383
  MyKit: 0123456789abcdef0123456789abcdef01234567
  Nuke: 76543210fedcba9876543210fedcba9876543210

PODFILE CHECKSUM: 8c3f4a1e2b5d6c7e8f9a0b1c2d3e4f5a6b7c8d9e

COCOAPODS: 1.16.2

"""

struct LockfileTests {
    @Test func roundTripIsByteIdentical() throws {
        let lockfile = try Lockfile(yaml: sampleLockfile)
        #expect(lockfile.yaml == sampleLockfile)
    }

    @Test func swiftPackagesRoundTrip() throws {
        let yaml = sampleLockfile.replacingOccurrences(of: "PODFILE CHECKSUM", with: """
        SWIFT PACKAGES:
          https://github.com/google/GoogleUtilities.git:
            pods:
              - GoogleUtilities
            requirement: "< 8.1.1, >= 8.0.0"
            revision: 60da361632d0a91e1d6d4b0e1b3c3d0e9d0e5c0a
            version: 8.1.0

        PODFILE CHECKSUM
        """)
        let lockfile = try Lockfile(yaml: yaml)
        #expect(lockfile.swiftPackages.count == 1)
        #expect(lockfile.swiftPackages[0].pods == ["GoogleUtilities"])
        #expect(lockfile.swiftPackages[0].version == Version(8, 1, 0))
        #expect(lockfile.yaml == yaml)
    }

    @Test func omitsSwiftPackagesSectionWhenEmpty() throws {
        let lockfile = try Lockfile(yaml: sampleLockfile)
        #expect(lockfile.swiftPackages.isEmpty)
        #expect(!lockfile.yaml.contains("SWIFT PACKAGES"))
    }

    @Test func queries() throws {
        let lockfile = try Lockfile(yaml: sampleLockfile)
        #expect(lockfile.version(of: "Firebase/Analytics") == Version(11, 0, 0))
        #expect(lockfile.version(of: "Alamofire") == Version(5, 9, 1))
        #expect(lockfile.pods.first { $0.name == "MyKit" }?.dependencies == ["Alamofire (~> 5.9)"])
        let dependencies = lockfile.parsedDependencies
        #expect(dependencies.map(\.name) == ["Alamofire", "Firebase/CoreOnly", "MyKit", "Nuke"])
        #expect(dependencies[2].externalSource == .path("../MyKit"))
        #expect(dependencies[3].externalSource == .git(url: "https://github.com/kean/Nuke.git", reference: .tag("12.0.0")))
        #expect(dependencies[0].requirement.isSatisfied(by: Version(5, 10)))
    }

    @Test func sortsCaseInsensitivelyAndQuotesAmbiguousScalars() {
        let lockfile = Lockfile(
            pods: [.init(name: "zlib", version: Version(1)), .init(name: "Alamofire", version: Version(5)), .init(name: "abseil", version: Version(1))],
            externalSources: ["X": [":tag": "1.10", ":path": "./X"]],
            podfileChecksum: nil
        )
        let yaml = lockfile.yaml
        #expect(yaml.hasPrefix("PODS:\n  - abseil (1)\n  - Alamofire (5)\n  - zlib (1)\n"))
        #expect(yaml.contains("    :path: \"./X\"\n    :tag: '1.10'"))
    }

    /// Cases follow CocoaPods' `YAMLHelper.process_string`.
    @Test(arguments: [
        ("Alamofire (5.9.1)", "Alamofire (5.9.1)"),
        ("GoogleToolboxForMac/NSData+zlib (4.2.1)", "\"GoogleToolboxForMac/NSData+zlib (4.2.1)\""),
        ("GTMSessionFetcher/Core (< 4.0, >= 3.3.2)", "GTMSessionFetcher/Core (< 4.0, >= 3.3.2)"),
        ("https://github.com/SnapKit/SnapKit.git", "https://github.com/SnapKit/SnapKit.git"),
        ("5.7.1", "5.7.1"),
        ("1.10", "'1.10'"),
        ("true", "'true'"),
        ("", "''"),
        ("./X", "\"./X\""),
        ("-flag", "\"-flag\""),
        ("key:", "\"key:\""),
        ("a#b", "\"a#b\""),
        ("Name With Spaces", "Name With Spaces"),
    ])
    func quotesScalarsLikeCocoaPods(input: String, expected: String) {
        #expect(YAMLWriter.scalar(input) == expected)
    }
}
