public import Foundation
public import PodsCore
import PodsDSL

/// Evaluates a Ruby `Podfile` into the `Podfile#to_hash` JSON format.
public enum RubyPodfileEvaluator {
    public static func evaluate(source: String, file: String, directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JSON {
        let interpreter = Interpreter(file: file, directory: directory, environment: environment)
        let builder = PodfileBuilder()
        interpreter.define(constant: "Pod::Podfile", .object(builder))
        try interpreter.evaluate(source, self: .object(builder))
        return builder.json
    }
}

/// A target definition under construction.
private final class TargetNode {
    let name: String
    var settings = OrderedObject()
    var dependencies: [JSON] = []
    var children: [TargetNode] = []

    init(name: String, abstract: Bool) {
        self.name = name
        if abstract { settings["abstract"] = .bool(true) }
    }

    var json: JSON {
        var object = OrderedObject([("name", .string(name))])
        for pair in settings.pairs { object[pair.key] = pair.value }
        if !dependencies.isEmpty { object["dependencies"] = .array(dependencies) }
        if !children.isEmpty { object["children"] = .array(children.map(\.json)) }
        return .object(object)
    }

    /// Adds a pod name to a `{all:, for_pods:}` style setting.
    func appendForPods(_ key: String, _ pod: String) {
        var setting = settings[key]?.object ?? OrderedObject()
        let pods = setting["for_pods"]?.stringList ?? []
        if !pods.contains(pod) { setting["for_pods"] = .array((pods + [pod]).map(JSON.string)) }
        settings[key] = .object(setting)
    }
}

/// The implicit `self` of a Podfile.
private final class PodfileBuilder: DSLObject {
    private let root = TargetNode(name: "Pods", abstract: true)
    private var stack: [TargetNode]
    private var sources: [String] = []
    private var workspace: String?
    private var installationOptions = OrderedObject()
    private var plugins = OrderedObject()
    private var hooks: [String] = []

    init() { stack = [root] }

    var dslTypeName: String { "Pod::Podfile" }
    private var current: TargetNode { stack.last! }

    var json: JSON {
        var object = OrderedObject()
        if !sources.isEmpty { object["sources"] = .array(sources.map(JSON.string)) }
        if let workspace { object["workspace"] = .string(workspace) }
        if !installationOptions.isEmpty {
            object["installation_method"] = .object(OrderedObject([("name", .string("cocoapods")), ("options", .object(installationOptions))]))
        }
        if !plugins.isEmpty { object["plugins"] = .object(plugins) }
        if !hooks.isEmpty { object["hooks"] = .array(hooks.map(JSON.string)) }
        object["target_definitions"] = .array([root.json])
        return .object(object)
    }

    func callMethod(_ name: String, _ call: DSLCall) throws -> Value? {
        switch name {
        case "source":
            guard let url = call.positional.first?.stringValue else { throw call.error("source requires a URL") }
            if !sources.contains(url) { sources.append(url) }
        case "workspace":
            workspace = call.positional.first?.stringValue
        case "project", "xcodeproj":
            guard let path = call.positional.first?.stringValue else { throw call.error("\(name) requires a path") }
            current.settings["user_project_path"] = .string(path)
            if let configurations = call.positional.dropFirst().first?.hashPairs ?? (call.options.isEmpty ? nil : call.options) {
                current.settings["build_configurations"] = .object(OrderedObject(configurations.map { ($0.key.stringified, .string($0.value.stringified)) }))
            }
        case "platform":
            guard let platform = call.positional.first?.stringValue, let platformName = Platform.Name(podfileName: platform) else {
                throw call.error("Unsupported platform `\(call.positional.first?.stringified ?? "")`")
            }
            let version = call.positional.dropFirst().first.map { JSON.string($0.stringified) } ?? .null
            current.settings["platform"] = .object(OrderedObject([(platformName.rawValue, version)]))
        case "target", "abstract_target":
            guard let targetName = call.positional.first?.stringValue else { throw call.error("\(name) requires a name") }
            let node = TargetNode(name: targetName, abstract: name == "abstract_target")
            current.children.append(node)
            stack.append(node)
            defer { stack.removeLast() }
            if let block = call.block { try call.interpreter.call(block, [.object(self)]) }
        case "abstract!":
            current.settings["abstract"] = .bool(call.positional.first?.isTruthy ?? true)
        case "inherit!":
            guard let mode = call.positional.first?.stringValue else { throw call.error("inherit! requires a mode") }
            current.settings["inheritance"] = .string(mode)
        case "use_frameworks!":
            if let flag = call.positional.first, case .bool(let enabled) = flag {
                current.settings["uses_frameworks"] = .bool(enabled)
            } else if let linkage = call.option("linkage")?.stringValue {
                current.settings["uses_frameworks"] = .object(OrderedObject([
                    ("linkage", .string(linkage)),
                    ("packaging", .string(call.option("packaging")?.stringValue ?? "framework")),
                ]))
            } else {
                current.settings["uses_frameworks"] = .bool(true)
            }
        case "use_modular_headers!":
            current.settings["use_modular_headers"] = .object(OrderedObject([("all", .bool(true))]))
        case "inhibit_all_warnings!":
            current.settings["inhibit_warnings"] = .object(OrderedObject([("all", .bool(true))]))
        case "pod":
            try addPod(call)
        case "install!":
            for pair in call.options {
                installationOptions[pair.key.stringified] = pair.value.json
            }
        case "plugin":
            if let plugin = call.positional.first?.stringValue { plugins[plugin] = call.options.isEmpty ? .object(OrderedObject()) : Value.hash(call.options).json }
        case "pre_install", "post_install", "pre_integrate", "post_integrate":
            hooks.append(name)
        case "podspec":
            // `podspec` pulls the dependencies of a local podspec; recorded as a path dependency.
            let path = call.option("path")?.stringValue ?? "."
            let podName = call.option("name")?.stringValue ?? "__podspec__"
            current.dependencies.append(.object(OrderedObject([(podName, .array([.object(OrderedObject([("path", .string(path))]))]))])))
        case "supports_swift_versions", "ensure_bundler!", "generate_bridge_support!", "set_arc_compatibility_flag!", "link_with":
            break // Accepted for compatibility; no effect.
        default:
            return nil
        }
        return .nil
    }

    private func addPod(_ call: DSLCall) throws {
        guard let podName = call.positional.first?.stringValue else { throw call.error("pod requires a name") }
        var values: [JSON] = call.positional.dropFirst().compactMap { $0.stringValue.map(JSON.string) }
        var options = OrderedObject()
        for pair in call.options {
            let key = pair.key.stringified
            options[key] = pair.value.json
            if key == "modular_headers", pair.value.isTruthy { current.appendForPods("use_modular_headers", Dependency.rootName(of: podName)) }
            if key == "inhibit_warnings", pair.value.isTruthy { current.appendForPods("inhibit_warnings", Dependency.rootName(of: podName)) }
        }
        if !options.isEmpty { values.append(.object(options)) }
        current.dependencies.append(values.isEmpty ? .string(podName) : .object(OrderedObject([(podName, .array(values))])))
    }
}
