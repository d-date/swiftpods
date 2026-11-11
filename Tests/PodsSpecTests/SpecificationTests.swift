import Foundation
import PodsCore
@testable import PodsSpec
import Testing

func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

struct SpecificationTests {
    @Test func loadsTrunkJSON() async throws {
        let spec = try await SpecLoader().load(try fixture("Alamofire.podspec.json"))
        #expect(spec.name == "Alamofire")
        #expect(spec.version == Version(5, 9, 1))
        #expect(spec.source == .git(url: "https://github.com/Alamofire/Alamofire.git", reference: .tag("5.9.1"), submodules: false))
        #expect(spec.deploymentTarget(for: .ios) == Version(10, 0))
        #expect(spec.swiftVersions == [Version(5)])
        #expect(spec.moduleName == "Alamofire")
        let consumer = spec.consumer(for: .ios)
        #expect(consumer.sourceFiles == ["Source/**/*.swift"])
        #expect(consumer.frameworks == ["CFNetwork"])
        #expect(consumer.resourceBundles.map(\.name) == ["Alamofire"])
        #expect(spec.checksum?.count == 40)
    }

    @Test func subspecsAndPlatformSpecificDependencies() async throws {
        let spec = try await SpecLoader().load(try fixture("Firebase.podspec.json"))
        #expect(spec.defaultSubspecNames == ["Core"])
        #expect(spec.defaultSubspecs.map(\.name) == ["Firebase/Core"])
        let core = try #require(spec.subspec(named: "Firebase/Core"))
        let iosDependencies = core.dependencies(for: .ios).map(\.name)
        #expect(iosDependencies.contains("FirebaseAnalytics"))
        #expect(iosDependencies.contains("Firebase/CoreOnly"))
        #expect(core.supports(Platform(.ios, Version(15, 0))))
        #expect(!core.supports(Platform(.ios, Version(11, 0))))
        #expect(!core.supports(Platform(.watchos, Version(10, 0))) || core.availablePlatforms.contains { $0.name == .watchos })
        // Depending on the root pulls in the default subspec only.
        #expect(spec.dependencies(for: .ios).map(\.name) == ["Firebase/Core"])
    }

    @Test func rubyPodspecMatchesCocoaPodsJSON() throws {
        let source = """
        Pod::Spec.new do |s|
          s.name         = 'Foo'
          s.version      = '1.2.0'
          s.summary      = 'Foo does things.'
          s.homepage     = 'https://example.com/foo'
          s.license      = { :type => 'MIT', :file => 'LICENSE' }
          s.author       = { 'Jane' => 'jane@example.com' }
          s.source       = { :git => 'https://example.com/foo.git', :tag => "v#{s.version}" }
          s.ios.deployment_target = '12.0'
          s.osx.deployment_target = '10.15'
          s.swift_version = '5.9'
          s.default_subspec = 'Core'
          s.framework    = 'UIKit'
          s.pod_target_xcconfig = { 'OTHER_SWIFT_FLAGS' => '-DFOO' }

          s.subspec 'Core' do |core|
            core.source_files = 'Sources/Core/**/*.{h,m,swift}'
            core.ios.frameworks = 'CoreTelephony'
            core.dependency 'Bar', '~> 1.0', '>= 1.0.2'
          end

          s.subspec 'Extras' do |extras|
            extras.source_files = 'Sources/Extras/**/*.swift'
            extras.dependency 'Foo/Core'
          end

          s.test_spec 'Tests' do |t|
            t.source_files = 'Tests/**/*.swift'
          end
        end
        """
        let json = try RubySpecEvaluator.evaluate(source: source, file: "Foo.podspec", directory: URL(fileURLWithPath: "/tmp"), environment: [:])
        #expect(json["source"]?["tag"]?.string == "v1.2.0")
        #expect(json["platforms"]?["ios"]?.string == "12.0")
        #expect(json["authors"]?["Jane"]?.string == "jane@example.com")
        #expect(json["swift_versions"]?.stringList == ["5.9"])
        #expect(json["frameworks"]?.string == "UIKit")
        #expect(json["testspecs"]?.array?.first?["test_type"]?.string == "unit")

        let spec = try Specification(json: json)
        #expect(spec.subspecs.map(\.name) == ["Foo/Core", "Foo/Extras"])
        #expect(spec.testSpecs.map(\.name) == ["Foo/Tests"])
        let core = try #require(spec.subspec(named: "Foo/Core"))
        let consumer = core.consumer(for: .ios)
        // Inherited from the root plus platform specific additions.
        #expect(consumer.frameworks == ["UIKit", "CoreTelephony"])
        #expect(core.consumer(for: .osx).frameworks == ["UIKit"])
        #expect(consumer.podTargetXCConfig.first?.value == "-DFOO")
        let bar = try #require(consumer.dependencies.first { $0.name == "Bar" })
        #expect(bar.requirement.isSatisfied(by: Version(1, 0, 5)))
        #expect(!bar.requirement.isSatisfied(by: Version(1, 0, 1)))
        #expect(spec.dependencies(for: .ios).map(\.name) == ["Foo/Core"])
    }

    @Test func platformShorthand() throws {
        let json = try RubySpecEvaluator.evaluate(source: """
        Pod::Spec.new do |s|
          s.name = 'P'
          s.version = '1.0'
          s.platform = :ios, '13.0'
        end
        """, file: "P.podspec", directory: URL(fileURLWithPath: "/tmp"), environment: [:])
        let spec = try Specification(json: json)
        #expect(spec.declaredPlatforms == [Platform(.ios, Version(13, 0))])
        #expect(!spec.supports(Platform(.osx)))
    }

    @Test func prefixHeaderCanBeDisabled() throws {
        let disabled = try Specification(json: try JSON(parsing: #"{"name":"P","version":"1.0","prefix_header_file":false}"#))
        #expect(disabled.consumer(for: .ios).prefixHeaderFile == nil)
        #expect(disabled.consumer(for: .ios).isPrefixHeaderDisabled)
        let custom = try Specification(json: try JSON(parsing: #"{"name":"P","version":"1.0","prefix_header_file":"P-Prefix.pch"}"#))
        #expect(custom.consumer(for: .ios).prefixHeaderFile == "P-Prefix.pch")
    }

    @Test func moduleNameIsC99Identifier() throws {
        let spec = try Specification(json: try JSON(parsing: #"{"name":"Foo-Bar","version":"1.0"}"#))
        #expect(spec.moduleName == "Foo_Bar")
    }

    @Test func missingVersionIsReported() {
        #expect(throws: Specification.SpecError.missingAttribute("version", spec: "X")) {
            try Specification(json: try JSON(parsing: #"{"name":"X"}"#))
        }
    }
}
