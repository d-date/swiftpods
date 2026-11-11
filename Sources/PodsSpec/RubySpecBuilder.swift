public import Foundation
public import PodsCore
import PodsDSL

/// Evaluates Ruby podspecs (`Pod::Spec.new do |s| ... end`) into podspec JSON.
public enum RubySpecEvaluator {
    public static func evaluate(source: String, file: String, directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JSON {
        let interpreter = Interpreter(file: file, directory: directory, environment: environment)
        let factory = SpecFactory()
        interpreter.define(constant: "Pod::Spec", .object(factory))
        interpreter.define(constant: "Pod::Specification", .object(factory))
        let result = try interpreter.evaluate(source, self: .nil)
        if case .object(let object) = result, let builder = object as? SpecBuilder {
            return builder.json
        }
        guard let builder = factory.created.first else {
            throw DSLError("The file does not define a specification (`Pod::Spec.new`)", file: file, line: 1)
        }
        return builder.json
    }
}

/// `Pod::Spec` – creates specifications.
final class SpecFactory: DSLObject {
    var created: [SpecBuilder] = []
    var dslTypeName: String { "Pod::Spec" }

    func callMethod(_ name: String, _ call: DSLCall) throws -> Value? {
        guard name == "new" else { return nil }
        let builder = SpecBuilder(parent: nil)
        if let nameArgument = call.positional.first?.stringValue { builder.set("name", .string(nameArgument)) }
        created.append(builder)
        if let block = call.block { try call.interpreter.call(block, [.object(builder)]) }
        return .object(builder)
    }
}

/// The object yielded by `Pod::Spec.new`; records attributes as podspec JSON.
final class SpecBuilder: DSLObject {
    private(set) var attributes = OrderedObject()
    private var subspecs: [SpecBuilder] = []
    private var testSpecs: [SpecBuilder] = []
    private var appSpecs: [SpecBuilder] = []
    weak var parent: SpecBuilder?

    init(parent: SpecBuilder?) { self.parent = parent }

    var dslTypeName: String { "Pod::Specification" }

    /// Attributes whose singular writer stores into the plural key.
    private static let pluralKeys: [String: String] = [
        "author": "authors", "resource": "resources", "library": "libraries", "framework": "frameworks",
        "weak_framework": "weak_frameworks", "vendored_framework": "vendored_frameworks",
        "vendored_library": "vendored_libraries", "preserve_path": "preserve_paths",
        "default_subspec": "default_subspecs", "screenshot": "screenshots", "script_phase": "script_phases",
    ]

    var json: JSON {
        var object = attributes
        if !subspecs.isEmpty { object["subspecs"] = .array(subspecs.map(\.json)) }
        if !testSpecs.isEmpty { object["testspecs"] = .array(testSpecs.map(\.json)) }
        if !appSpecs.isEmpty { object["appspecs"] = .array(appSpecs.map(\.json)) }
        return .object(object)
    }

    func set(_ key: String, _ value: JSON) {
        attributes[key] = value
    }

    func callMethod(_ name: String, _ call: DSLCall) throws -> Value? {
        if let platform = Platform.Name(podfileName: name), call.positional.isEmpty {
            return .object(PlatformProxy(spec: self, platform: platform.rawValue))
        }
        if name.hasSuffix("=") {
            try assign(String(name.dropLast()), call.positional.first ?? .nil, call: call, platform: nil)
            return .nil
        }
        switch name {
        case "dependency":
            try addDependency(call, platform: nil)
            return .nil
        case "subspec", "test_spec", "app_spec":
            guard let subspecName = call.positional.first?.stringValue else { throw call.error("\(name) requires a name") }
            let child = SpecBuilder(parent: self)
            child.set("name", .string(subspecName))
            if name == "test_spec" {
                child.set("test_type", .string(call.option("test_type")?.stringValue ?? "unit"))
                testSpecs.append(child)
            } else if name == "app_spec" {
                appSpecs.append(child)
            } else {
                subspecs.append(child)
            }
            if let block = call.block { try call.interpreter.call(block, [.object(child)]) }
            return .object(child)
        case "root":
            var root = self
            while let parent = root.parent { root = parent }
            return .object(root)
        case "name" where parent != nil:
            // Full name, e.g. `Foo/Bar`.
            return .string(fullName)
        case "version", "summary", "description", "homepage", "license", "authors", "source", "name",
             "platforms", "module_name", "swift_versions", "static_framework", "requires_arc",
             "source_files", "resources", "dependencies", "pod_target_xcconfig", "user_target_xcconfig",
             "social_media_url", "documentation_url", "header_dir", "deployment_target", "test_type", "default_subspecs":
            return read(name)
        case "attributes_hash", "to_hash":
            return Value(json)
        case "to_json", "to_pretty_json":
            return .string(json.serialized())
        case "subspecs":
            return .array(subspecs.map { .object($0) })
        default:
            if let value = attributes[name] { return Value(value) }
            return nil
        }
    }

    var fullName: String {
        let own = attributes["name"]?.string ?? ""
        guard let parent else { return own }
        return parent.fullName + "/" + own
    }

    private func read(_ key: String) -> Value {
        if let value = attributes[key] { return Value(value) }
        // Subspecs read root attributes such as `version`.
        if let parent, ["version", "source", "homepage", "license", "authors", "summary"].contains(key) {
            return parent.read(key)
        }
        return .nil
    }

    fileprivate func assign(_ key: String, _ value: Value, call: DSLCall, platform: String?) throws {
        var key = Self.pluralKeys[key] ?? key
        var json = value.json
        switch key {
        case "platform":
            // `s.platform = :ios, '12.0'` or `s.platform = :ios`.
            var items = value.arrayValue ?? [value]
            guard let platformName = items.first?.stringValue, Platform.Name(podfileName: platformName) != nil else {
                throw call.error("Invalid platform")
            }
            items.removeFirst()
            key = "platforms"
            let normalized = Platform.Name(podfileName: platformName)!.rawValue
            json = .object(OrderedObject([(normalized, items.first.map { .string($0.stringified) } ?? .null)]))
        case "deployment_target":
            // `s.ios.deployment_target = '12.0'` → platforms.ios
            guard let platform else {
                set("deployment_target", .string(value.stringified))
                return
            }
            var platforms = attributes["platforms"]?.object ?? OrderedObject()
            platforms[platform] = .string(value.stringified)
            set("platforms", .object(platforms))
            return
        case "version", "swift_version":
            json = .string(value.stringified)
            if key == "swift_version" {
                // CocoaPods stores both `swift_version` and `swift_versions`.
                set("swift_versions", .array((value.arrayValue ?? [value]).map { .string($0.stringified) }))
                if value.arrayValue != nil { return }
            }
        case "swift_versions":
            json = .array((value.arrayValue ?? [value]).map { .string($0.stringified) })
        case "dependencies":
            throw call.error("Use `dependency` to declare dependencies")
        default:
            break
        }
        if let platform {
            var platformObject = attributes[platform]?.object ?? OrderedObject()
            platformObject[key] = json
            set(platform, .object(platformObject))
        } else {
            set(key, json)
        }
    }

    fileprivate func addDependency(_ call: DSLCall, platform: String?) throws {
        guard let name = call.positional.first?.stringValue else { throw call.error("dependency requires a name") }
        let requirements = call.positional.dropFirst().compactMap(\.stringValue)
        if !call.options.isEmpty {
            throw call.error("Podspec dependencies cannot use external sources (\(name))")
        }
        let target = platform.map { attributes[$0]?.object ?? OrderedObject() } ?? attributes
        var dependencies = target["dependencies"]?.object ?? OrderedObject()
        let existing = dependencies[name]?.stringList ?? []
        dependencies[name] = .array((existing + requirements).map(JSON.string))
        if let platform {
            var platformObject = attributes[platform]?.object ?? OrderedObject()
            platformObject["dependencies"] = .object(dependencies)
            set(platform, .object(platformObject))
        } else {
            set("dependencies", .object(dependencies))
        }
    }
}

/// `s.ios`, `s.osx`, ... – writes attributes under a platform key.
final class PlatformProxy: DSLObject {
    let spec: SpecBuilder
    let platform: String

    init(spec: SpecBuilder, platform: String) {
        self.spec = spec
        self.platform = platform
    }

    var dslTypeName: String { "PlatformProxy" }

    func callMethod(_ name: String, _ call: DSLCall) throws -> Value? {
        if name.hasSuffix("=") {
            try spec.assign(String(name.dropLast()), call.positional.first ?? .nil, call: call, platform: platform)
            return .nil
        }
        if name == "dependency" {
            try spec.addDependency(call, platform: platform)
            return .nil
        }
        if name == "deployment_target" {
            return spec.attributes["platforms"]?[platform].map(Value.init) ?? .nil
        }
        return spec.attributes[platform]?[name].map(Value.init) ?? .nil
    }
}
