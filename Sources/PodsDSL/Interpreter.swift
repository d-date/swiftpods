public import Foundation

/// Local variable scope. Blocks get a child scope that can read and assign outer variables.
final class Scope {
    private var variables: [String: Value] = [:]
    let parent: Scope?

    init(parent: Scope? = nil) { self.parent = parent }

    func lookup(_ name: String) -> Value? {
        variables[name] ?? parent?.lookup(name)
    }

    func assign(_ name: String, _ value: Value) {
        if variables[name] == nil, let owner = parent?.owner(of: name) {
            owner.variables[name] = value
        } else {
            variables[name] = value
        }
    }

    func define(_ name: String, _ value: Value) { variables[name] = value }

    private func owner(of name: String) -> Scope? {
        variables[name] != nil ? self : parent?.owner(of: name)
    }

    var allNames: Set<String> {
        Set(variables.keys).union(parent?.allNames ?? [])
    }
}

/// Unwinds the stack for `return`; the value travels in `Interpreter.returnValue`
/// because `Value` is intentionally not `Sendable`.
private struct ReturnSignal: Error {}

/// Evaluates manifests written in the supported Ruby subset.
///
/// The interpreter itself is not `Sendable`: create one per evaluation.
public final class Interpreter {
    public let file: String
    /// Directory of the manifest; relative paths (`File.read`, `__dir__`) resolve against it.
    public let directory: URL
    public let environment: [String: String]
    private var constants: [String: Value] = [:]
    private var methods: [String: (parameters: [String], body: [Node])] = [:]
    private var instanceVariables: [String: Value] = [:]
    private var currentLine = 1
    private var returnValue: Value = .nil
    /// Messages printed with `puts`, surfaced by the host if desired.
    public private(set) var output: [String] = []

    public init(file: String, directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.file = file
        self.directory = directory
        self.environment = environment
        constants["ENV"] = .object(EnvObject(environment))
        constants["File"] = .object(FileObject(directory: directory))
        constants["Pod::VERSION"] = .string("1.16.2")
    }

    /// Registers a constant such as `Pod::Spec` (path components joined by `::`).
    public func define(constant: String, _ value: Value) {
        constants[constant] = value
    }

    public func error(_ message: String, line: Int? = nil) -> DSLError {
        DSLError(message, file: file, line: line ?? currentLine)
    }

    /// Parses and evaluates `source` with `selfValue` as the implicit receiver.
    @discardableResult
    public func evaluate(_ source: String, self selfValue: Value) throws(DSLError) -> Value {
        let program = try Parser.parse(source, file: file)
        do {
            return try evaluate(program, scope: Scope(), self: selfValue)
        } catch let error as DSLError {
            throw error
        } catch is ReturnSignal {
            return returnValue
        } catch {
            throw self.error(String(describing: error))
        }
    }

    /// Invokes a block passed to a host method (e.g. `target 'App' do ... end`).
    @discardableResult
    public func call(_ block: DSLBlock, _ arguments: [Value] = []) throws -> Value {
        let scope = Scope(parent: block.scope)
        if block.parameters.count > 1, arguments.count == 1, case .array(let items) = arguments[0] {
            for (i, name) in block.parameters.enumerated() { scope.define(name, i < items.count ? items[i] : .nil) }
        } else {
            for (i, name) in block.parameters.enumerated() { scope.define(name, i < arguments.count ? arguments[i] : .nil) }
        }
        return try evaluate(block.body, scope: scope, self: block.selfValue)
    }

    // MARK: - Evaluation

    private func evaluate(_ nodes: [Node], scope: Scope, self selfValue: Value) throws -> Value {
        var result = Value.nil
        for node in nodes { result = try evaluate(node, scope: scope, self: selfValue) }
        return result
    }

    private func evaluate(_ node: Node, scope: Scope, self selfValue: Value) throws -> Value {
        switch node {
        case .located(let line, let inner):
            currentLine = line
            return try evaluate(inner, scope: scope, self: selfValue)
        case .literal(let value):
            return value
        case .string(let parts):
            var result = ""
            for part in parts {
                switch part {
                case .text(let text): result += text
                case .code(let nodes): result += try evaluate(nodes, scope: scope, self: selfValue).stringified
                }
            }
            return .string(result)
        case .array(let items):
            return .array(try items.map { try evaluate($0, scope: scope, self: selfValue) })
        case .hash(let pairs):
            var result: [(key: Value, value: Value)] = []
            for pair in pairs {
                let key = try evaluate(pair.key, scope: scope, self: selfValue)
                let value = try evaluate(pair.value, scope: scope, self: selfValue)
                Self.store(&result, key, value)
            }
            return .hash(result)
        case .range(let lower, let upper, let exclusive):
            guard case .int(let a) = try evaluate(lower, scope: scope, self: selfValue),
                  case .int(let b) = try evaluate(upper, scope: scope, self: selfValue)
            else { throw error("Only integer ranges are supported") }
            return .range(a, exclusive ? b - 1 : b)
        case .variable(let name):
            if let value = scope.lookup(name) { return value }
            return try callMethod(receiver: nil, name: name, call: makeCall([], block: nil), scope: scope, self: selfValue)
        case .instanceVariable(let name):
            return instanceVariables[name] ?? .nil
        case .constant(let path):
            return try resolveConstant(path)
        case .selfReference:
            return selfValue
        case .call(let receiverNode, let name, let arguments, let blockNode, let safe):
            return try evaluateCall(receiverNode, name, arguments, blockNode, safe: safe, scope: scope, self: selfValue)
        case .index(let receiverNode, let indexNodes):
            let receiver = try evaluate(receiverNode, scope: scope, self: selfValue)
            let indices = try indexNodes.map { try evaluate($0, scope: scope, self: selfValue) }
            var copy = receiver
            return try invoke(&copy, "[]", makeCall(indices, block: nil), scope: scope, self: selfValue)
        case .assign(let target, let valueNode):
            let value = try evaluate(valueNode, scope: scope, self: selfValue)
            try assign(target, value, scope: scope, self: selfValue)
            return value
        case .opAssign(let target, let op, let valueNode):
            let current: Value
            if case .variable(let name) = target {
                current = scope.lookup(name) ?? .nil
            } else {
                current = try evaluate(target, scope: scope, self: selfValue)
            }
            let value: Value
            switch op {
            case "||": value = current.isTruthy ? current : try evaluate(valueNode, scope: scope, self: selfValue)
            case "&&": value = current.isTruthy ? try evaluate(valueNode, scope: scope, self: selfValue) : current
            default:
                var receiver = current
                value = try invoke(&receiver, op, makeCall([try evaluate(valueNode, scope: scope, self: selfValue)], block: nil), scope: scope, self: selfValue)
            }
            try assign(target, value, scope: scope, self: selfValue)
            return value
        case .binary(let op, let lhsNode, let rhsNode):
            var lhs = try evaluate(lhsNode, scope: scope, self: selfValue)
            let rhs = try evaluate(rhsNode, scope: scope, self: selfValue)
            let result = try invoke(&lhs, op, makeCall([rhs], block: nil), scope: scope, self: selfValue)
            if op == "<<" { try writeBack(lhsNode, lhs, scope: scope, self: selfValue) }
            return result
        case .not(let inner):
            return .bool(!(try evaluate(inner, scope: scope, self: selfValue)).isTruthy)
        case .and(let lhs, let rhs):
            let left = try evaluate(lhs, scope: scope, self: selfValue)
            return left.isTruthy ? try evaluate(rhs, scope: scope, self: selfValue) : left
        case .or(let lhs, let rhs):
            let left = try evaluate(lhs, scope: scope, self: selfValue)
            return left.isTruthy ? left : try evaluate(rhs, scope: scope, self: selfValue)
        case .ternary(let condition, let a, let b):
            return try evaluate(try evaluate(condition, scope: scope, self: selfValue).isTruthy ? a : b, scope: scope, self: selfValue)
        case .conditional(let branches, let elseBody):
            for branch in branches where try evaluate(branch.condition, scope: scope, self: selfValue).isTruthy {
                return try evaluate(branch.body, scope: scope, self: selfValue)
            }
            return try elseBody.map { try evaluate($0, scope: scope, self: selfValue) } ?? .nil
        case .caseWhen(let subjectNode, let whens, let elseBody):
            let subject = try subjectNode.map { try evaluate($0, scope: scope, self: selfValue) }
            for clause in whens {
                for valueNode in clause.values {
                    var value = try evaluate(valueNode, scope: scope, self: selfValue)
                    let matched: Bool = if let subject {
                        try invoke(&value, "===", makeCall([subject], block: nil), scope: scope, self: selfValue).isTruthy
                    } else {
                        value.isTruthy
                    }
                    if matched { return try evaluate(clause.body, scope: scope, self: selfValue) }
                }
            }
            return try elseBody.map { try evaluate($0, scope: scope, self: selfValue) } ?? .nil
        case .whileLoop(let condition, let body, let negated):
            var iterations = 0
            while try evaluate(condition, scope: scope, self: selfValue).isTruthy != negated {
                iterations += 1
                guard iterations < 100_000 else { throw error("Loop did not terminate") }
                _ = try evaluate(body, scope: scope, self: selfValue)
            }
            return .nil
        case .def(let name, let parameters, let body):
            methods[name] = (parameters, body)
            return .symbol(name)
        case .begin(let body, let rescueBody, let ensureBody):
            defer { if let ensureBody { _ = try? evaluate(ensureBody, scope: scope, self: selfValue) } }
            do {
                return try evaluate(body, scope: scope, self: selfValue)
            } catch let signal as ReturnSignal {
                throw signal
            } catch {
                guard let rescueBody else { throw error }
                return try evaluate(rescueBody, scope: scope, self: selfValue)
            }
        case .returnValue(let valueNode):
            returnValue = try valueNode.map { try evaluate($0, scope: scope, self: selfValue) } ?? .nil
            throw ReturnSignal()
        case .lambda(let blockNode):
            return .block(DSLBlock(parameters: blockNode.parameters, body: blockNode.body, scope: scope, selfValue: selfValue))
        }
    }

    private func makeCall(_ positional: [Value], options: [(key: Value, value: Value)] = [], block: DSLBlock?) -> DSLCall {
        DSLCall(positional: positional, options: options, block: block, interpreter: self, line: currentLine)
    }

    private func evaluateCall(
        _ receiverNode: Node?, _ name: String, _ argumentNodes: [Argument], _ blockNode: BlockNode?,
        safe: Bool, scope: Scope, self selfValue: Value
    ) throws -> Value {
        var positional: [Value] = []
        var options: [(key: Value, value: Value)] = []
        var block = blockNode.map { DSLBlock(parameters: $0.parameters, body: $0.body, scope: scope, selfValue: selfValue) }
        for argument in argumentNodes {
            switch argument {
            case .positional(let node):
                positional.append(try evaluate(node, scope: scope, self: selfValue))
            case .splat(let node):
                switch try evaluate(node, scope: scope, self: selfValue) {
                case .array(let items): positional += items
                case .hash(let pairs): options += pairs
                case let other: positional.append(other)
                }
            case .pair(let keyNode, let valueNode):
                let key = try evaluate(keyNode, scope: scope, self: selfValue)
                Self.store(&options, key, try evaluate(valueNode, scope: scope, self: selfValue))
            case .blockPass(let node):
                switch try evaluate(node, scope: scope, self: selfValue) {
                case .block(let b): block = b
                case .symbol(let method):
                    // `&:to_s`
                    block = DSLBlock(parameters: ["it"], body: [.call(receiver: .variable("it"), name: method, arguments: [], block: nil, safeNavigation: false)], scope: Scope(), selfValue: .nil)
                default: throw error("Expected a block after '&'")
                }
            }
        }
        let call = makeCall(positional, options: options, block: block)
        guard let receiverNode else {
            return try callMethod(receiver: nil, name: name, call: call, scope: scope, self: selfValue)
        }
        var receiver = try evaluate(receiverNode, scope: scope, self: selfValue)
        if safe, case .nil = receiver { return .nil }
        let result = try invoke(&receiver, name, call, scope: scope, self: selfValue)
        if Builtins.mutatingMethods.contains(name) {
            try writeBack(receiverNode, receiver, scope: scope, self: selfValue)
        }
        return result
    }

    /// Implicit-receiver call: user `def`s, then the host `self`, then global functions.
    private func callMethod(receiver: Value?, name: String, call: DSLCall, scope: Scope, self selfValue: Value) throws -> Value {
        // Manifests are data: never let one run arbitrary commands, whatever the host supports.
        if Builtins.forbiddenFunctions.contains(name) {
            throw error("Running shell commands from a manifest is not supported ('\(name)')")
        }
        if let method = methods[name] {
            let methodScope = Scope()
            for (i, parameter) in method.parameters.enumerated() {
                methodScope.define(parameter, i < call.arguments.count ? call.arguments[i] : .nil)
            }
            do {
                return try evaluate(method.body, scope: methodScope, self: selfValue)
            } catch is ReturnSignal {
                return returnValue
            }
        }
        if case .object(let object) = selfValue, let result = try object.callMethod(name, call) {
            return result
        }
        if let result = try Builtins.global(name, call, interpreter: self) {
            return result
        }
        throw error("Undefined method or variable '\(name)' for \(selfValue.typeName)")
    }

    /// Calls `name` on an explicit receiver.
    func invoke(_ receiver: inout Value, _ name: String, _ call: DSLCall, scope: Scope, self selfValue: Value) throws -> Value {
        if case .object(let object) = receiver {
            if let result = try object.callMethod(name, call) { return result }
            if name == "nil?" { return .bool(false) }
            if name == "respond_to?" { return .bool(false) }
            throw error("Undefined method '\(name)' for \(object.dslTypeName)")
        }
        if case .block(let block) = receiver, ["call", "()", "yield", "[]"].contains(name) {
            return try self.call(block, call.arguments)
        }
        return try Builtins.call(&receiver, name, call, interpreter: self)
    }

    private func assign(_ target: Node, _ value: Value, scope: Scope, self selfValue: Value) throws {
        switch target {
        case .variable(let name):
            scope.assign(name, value)
        case .instanceVariable(let name):
            instanceVariables[name] = value
        case .constant(let path):
            constants[path.joined(separator: "::")] = value
        case .call(let receiverNode?, let name, _, _, _):
            var receiver = try evaluate(receiverNode, scope: scope, self: selfValue)
            _ = try invoke(&receiver, name + "=", makeCall([value], block: nil), scope: scope, self: selfValue)
            try writeBack(receiverNode, receiver, scope: scope, self: selfValue)
        case .call(nil, let name, _, _, _):
            scope.assign(name, value)
        case .index(let receiverNode, let indexNodes):
            var receiver = try evaluate(receiverNode, scope: scope, self: selfValue)
            let indices = try indexNodes.map { try evaluate($0, scope: scope, self: selfValue) }
            _ = try invoke(&receiver, "[]=", makeCall(indices + [value], block: nil), scope: scope, self: selfValue)
            try writeBack(receiverNode, receiver, scope: scope, self: selfValue)
        default:
            throw error("Cannot assign to this expression")
        }
    }

    /// Value types emulate Ruby's reference semantics by storing mutated receivers back into variables.
    private func writeBack(_ node: Node, _ value: Value, scope: Scope, self selfValue: Value) throws {
        switch node {
        case .variable(let name): scope.assign(name, value)
        case .instanceVariable(let name): instanceVariables[name] = value
        case .index:
            try assign(node, value, scope: scope, self: selfValue)
        default: break
        }
    }

    private func resolveConstant(_ path: [String]) throws -> Value {
        let key = path.joined(separator: "::")
        if let value = constants[key] { return value }
        // Allow `::Pod::Spec` and nested lookups such as `Pod::Specification` aliases.
        if path.count > 1, let value = constants[path.dropFirst().joined(separator: "::")] { return value }
        throw error("Uninitialized constant \(key)")
    }

    static func store(_ pairs: inout [(key: Value, value: Value)], _ key: Value, _ value: Value) {
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            pairs[index].value = value
        } else {
            pairs.append((key, value))
        }
    }

    func print(_ line: String) { output.append(line) }
}

/// `ENV` – read-only access to environment variables.
final class EnvObject: DSLObject {
    let values: [String: String]
    init(_ values: [String: String]) { self.values = values }
    var dslTypeName: String { "ENV" }

    func callMethod(_ name: String, _ call: DSLCall) throws -> Value? {
        let key = call.positional.first?.stringValue
        switch name {
        case "[]": return key.flatMap { values[$0] }.map(Value.string) ?? .nil
        case "fetch":
            if let key, let value = values[key] { return .string(value) }
            if call.positional.count > 1 { return call.positional[1] }
            if let block = call.block { return try call.interpreter.call(block, [.string(key ?? "")]) }
            throw call.error("key not found: \"\(key ?? "")\"")
        case "key?", "has_key?", "include?": return .bool(key.map { values[$0] != nil } ?? false)
        case "[]=": throw call.error("Modifying ENV is not supported")
        default: return nil
        }
    }
}

/// `File` – a sandboxed subset relative to the manifest directory.
final class FileObject: DSLObject {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    var dslTypeName: String { "File" }

    private func url(_ value: Value?, _ call: DSLCall) throws -> URL {
        guard let path = value?.stringValue else { throw call.error("Expected a path") }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
    }

    func callMethod(_ name: String, _ call: DSLCall) throws -> Value? {
        switch name {
        case "read":
            let url = try url(call.positional.first, call)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                throw call.error("No such file - \(url.path)")
            }
            return .string(contents)
        case "exist?", "exists?", "file?":
            return .bool(FileManager.default.fileExists(atPath: try url(call.positional.first, call).path))
        case "directory?":
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: try url(call.positional.first, call).path, isDirectory: &isDirectory)
            return .bool(exists && isDirectory.boolValue)
        case "join":
            return .string(call.positional.map(\.stringified).joined(separator: "/"))
        case "basename":
            var base = (call.positional.first?.stringified ?? "").split(separator: "/").last.map(String.init) ?? ""
            if let suffix = call.positional.dropFirst().first?.stringValue, base.hasSuffix(suffix) { base.removeLast(suffix.count) }
            return .string(base)
        case "dirname":
            let path = call.positional.first?.stringified ?? ""
            return .string((path as NSString).deletingLastPathComponent.isEmpty ? "." : (path as NSString).deletingLastPathComponent)
        case "extname":
            let ext = ((call.positional.first?.stringified ?? "") as NSString).pathExtension
            return .string(ext.isEmpty ? "" : "." + ext)
        case "expand_path":
            let base = call.positional.dropFirst().first.map { try? url($0, call) } ?? directory
            let path = call.positional.first?.stringified ?? "."
            let resolved = path.hasPrefix("/") ? URL(fileURLWithPath: path) : (base ?? directory).appendingPathComponent(path)
            return .string(resolved.standardizedFileURL.path)
        default:
            return nil
        }
    }
}
