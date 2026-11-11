import Foundation
import PathKit
import XcodeProj

/// Builds a minimal iOS app project (app + unit tests) for installer tests.
enum FixtureProject {
    static func create(in directory: URL, name: String = "App", deploymentTarget: String = "16.0") throws -> URL {
        let sources = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        import SwiftUI

        @main
        struct FixtureApp: App {
            var body: some Scene { WindowGroup { Text("Hello") } }
        }
        """.write(to: sources.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        let pbxproj = PBXProj()
        func add<T: PBXObject>(_ object: T) -> T { pbxproj.add(object: object); return object }

        let appFile = add(PBXFileReference(sourceTree: .group, lastKnownFileType: "sourcecode.swift", path: "App.swift"))
        let appGroup = add(PBXGroup(children: [appFile], sourceTree: .group, path: name))
        let products = add(PBXGroup(sourceTree: .group, name: "Products"))
        let mainGroup = add(PBXGroup(children: [appGroup, products], sourceTree: .group))

        func configurations(_ settings: BuildSettings) -> XCConfigurationList {
            let debug = add(XCBuildConfiguration(name: "Debug", buildSettings: settings))
            let release = add(XCBuildConfiguration(name: "Release", buildSettings: settings))
            return add(XCConfigurationList(buildConfigurations: [debug, release], defaultConfigurationName: "Release"))
        }
        let common: BuildSettings = [
            "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": .string(deploymentTarget), "SWIFT_VERSION": "5.0",
            "TARGETED_DEVICE_FAMILY": "1,2", "CODE_SIGNING_ALLOWED": "NO", "GENERATE_INFOPLIST_FILE": "YES",
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        ]

        let appProduct = add(PBXFileReference(sourceTree: .buildProductsDir, explicitFileType: "wrapper.application", path: "\(name).app", includeInIndex: false))
        products.children.append(appProduct)
        var appSettings = common
        appSettings["PRODUCT_NAME"] = "$(TARGET_NAME)"
        appSettings["PRODUCT_BUNDLE_IDENTIFIER"] = .string("com.example.\(name)")
        appSettings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
        let appSources = add(PBXSourcesBuildPhase(files: [add(PBXBuildFile(file: appFile))]))
        let appFrameworks = add(PBXFrameworksBuildPhase())
        let app = add(PBXNativeTarget(
            name: name, buildConfigurationList: configurations(appSettings), buildPhases: [appSources, appFrameworks],
            productName: name, product: appProduct, productType: .application
        ))

        let testProduct = add(PBXFileReference(sourceTree: .buildProductsDir, explicitFileType: "wrapper.cfbundle", path: "\(name)Tests.xctest", includeInIndex: false))
        products.children.append(testProduct)
        var testSettings = common
        testSettings["PRODUCT_NAME"] = "$(TARGET_NAME)"
        testSettings["PRODUCT_BUNDLE_IDENTIFIER"] = .string("com.example.\(name)Tests")
        testSettings["TEST_HOST"] = .string("$(BUILT_PRODUCTS_DIR)/\(name).app/\(name)")
        testSettings["BUNDLE_LOADER"] = "$(TEST_HOST)"
        let tests = add(PBXNativeTarget(
            name: "\(name)Tests", buildConfigurationList: configurations(testSettings),
            buildPhases: [add(PBXSourcesBuildPhase()), add(PBXFrameworksBuildPhase())],
            productName: "\(name)Tests", product: testProduct, productType: .unitTestBundle
        ))

        let project = add(PBXProject(
            name: name, buildConfigurationList: configurations(["SDKROOT": "iphoneos"]), compatibilityVersion: "Xcode 14.0",
            preferredProjectObjectVersion: 56, minimizedProjectReferenceProxies: nil, mainGroup: mainGroup,
            developmentRegion: "en", knownRegions: ["en", "Base"], productsGroup: products, targets: [app, tests]
        ))
        pbxproj.rootObject = project
        let url = directory.appendingPathComponent("\(name).xcodeproj")
        try XcodeProj(workspace: XCWorkspace(), pbxproj: pbxproj).write(path: Path(url.path))
        return url
    }

    /// A local pod with Swift and Objective-C code, a resource bundle and a dependency on another local pod.
    static func createLocalPods(in directory: URL) throws {
        let fileManager = FileManager.default
        func write(_ contents: String, _ path: String) throws {
            let url = directory.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("""
        Pod::Spec.new do |s|
          s.name = 'Greeter'
          s.version = '1.0.0'
          s.summary = 'Greets.'
          s.homepage = 'https://example.com'
          s.license = { :type => 'MIT', :text => 'MIT License' }
          s.authors = { 'Example' => 'e@example.com' }
          s.source = { :git => 'https://example.com/Greeter.git', :tag => s.version.to_s }
          s.ios.deployment_target = '15.0'
          s.swift_version = '5.9'
          s.source_files = 'Sources/**/*.swift'
          s.resource_bundles = { 'GreeterResources' => ['Resources/*.json'] }
          s.dependency 'Decorator'
        end
        """, "LocalPods/Greeter/Greeter.podspec")
        try write("""
        import Decorator

        public enum Greeter {
            public static func greet(_ name: String) -> String { SPDecorator.decorate("Hello, \\(name)") }
        }
        """, "LocalPods/Greeter/Sources/Greeter.swift")
        try write("{\"greeting\": \"hi\"}", "LocalPods/Greeter/Resources/strings.json")

        try write("""
        import SwiftPodsDescription

        let podspec = PodSpec(
            name: "Decorator",
            version: "0.3.0",
            summary: "Decorates strings.",
            homepage: "https://example.com",
            license: .mit(file: nil),
            authors: ["Example": "e@example.com"],
            source: .git(url: "https://example.com/Decorator.git", tag: "0.3.0"),
            platforms: [.iOS(.v15)],
            sourceFiles: ["Sources/**/*.{h,m}"],
            publicHeaderFiles: ["Sources/Public/*.h"]
        )
        """, "LocalPods/Decorator/Decorator.podspec.swift")
        try write("""
        #import <Foundation/Foundation.h>
        NS_ASSUME_NONNULL_BEGIN
        @interface SPDecorator : NSObject
        + (NSString *)decorate:(NSString *)text;
        @end
        NS_ASSUME_NONNULL_END
        """, "LocalPods/Decorator/Sources/Public/SPDecorator.h")
        try write("""
        #import "SPDecorator.h"
        @implementation SPDecorator
        + (NSString *)decorate:(NSString *)text { return [NSString stringWithFormat:@"*%@*", text]; }
        @end
        """, "LocalPods/Decorator/Sources/SPDecorator.m")
    }
}
