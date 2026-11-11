import Foundation
public import PodsCore

/// A host object exposed to manifests (e.g. the Podfile DSL or a `Pod::Spec` being built).
///
/// Interpreter values are confined to the evaluation that created them, so host objects
/// don't need to be `Sendable`; hosts convert the result into `Sendable` models.
public protocol DSLObject: AnyObject {
    /// Name shown in error messages (`Pod::Spec`, `Podfile`, ...).
    var dslTypeName: String { get }
    /// Handles `receiver.name(arguments) { block }`. Return `nil` if the method is unknown.
    func callMethod(_ name: String, _ call: DSLCall) throws -> Value?
}

/// The arguments of a method call made from a manifest.
public struct DSLCall {
    public let positional: [Value]
    /// Trailing `key: value` / `:key => value` pairs.
    public let options: [(key: Value, value: Value)]
    public let block: DSLBlock?
    public let interpreter: Interpreter
    public let line: Int

    /// All arguments as Ruby would pass them (options become a trailing hash).
    public var arguments: [Value] {
        options.isEmpty ? positional : positional + [.hash(options)]
    }

    public func error(_ message: String) -> DSLError {
        interpreter.error(message, line: line)
    }

    /// Looks up an option by symbol or string key.
    public func option(_ key: String) -> Value? {
        options.first { $0.key.stringValue == key }?.value
    }
}

/// A Ruby block or lambda captured by the interpreter.
public final class DSLBlock {
    let parameters: [String]
    let body: [Node]
    let scope: Scope
    let selfValue: Value

    init(parameters: [String], body: [Node], scope: Scope, selfValue: Value) {
        self.parameters = parameters
        self.body = body
        self.scope = scope
        self.selfValue = selfValue
    }

    public var arity: Int { parameters.count }
}

/// A dynamically typed Ruby value.
public enum Value {
    case `nil`
    case bool(Bool)
    case int(Int)
    case float(Double)
    case string(String)
    case symbol(String)
    case array([Value])
    /// Insertion-ordered hash.
    case hash([(key: Value, value: Value)])
    case range(Int, Int)
    case object(any DSLObject)
    case block(DSLBlock)

    public var isTruthy: Bool {
        switch self {
        case .nil, .bool(false): false
        default: true
        }
    }

    /// Strings and symbols as Swift strings; `nil` otherwise.
    public var stringValue: String? {
        switch self {
        case .string(let s), .symbol(let s): s
        default: nil
        }
    }

    public var arrayValue: [Value]? {
        if case .array(let items) = self { items } else { nil }
    }

    public var hashPairs: [(key: Value, value: Value)]? {
        if case .hash(let pairs) = self { pairs } else { nil }
    }

    /// Ruby's `to_s`.
    public var stringified: String {
        switch self {
        case .nil: ""
        case .bool(let b): b ? "true" : "false"
        case .int(let i): String(i)
        case .float(let d): d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
        case .string(let s), .symbol(let s): s
        case .array: inspected
        case .hash: inspected
        case .range(let a, let b): "\(a)..\(b)"
        case .object(let o): "#<\(o.dslTypeName)>"
        case .block: "#<Proc>"
        }
    }

    /// Ruby's `inspect`.
    public var inspected: String {
        switch self {
        case .nil: "nil"
        case .string(let s): "\"\(s)\""
        case .symbol(let s): ":\(s)"
        case .array(let items): "[" + items.map(\.inspected).joined(separator: ", ") + "]"
        case .hash(let pairs): "{" + pairs.map { "\($0.key.inspected)=>\($0.value.inspected)" }.joined(separator: ", ") + "}"
        default: stringified
        }
    }

    public var typeName: String {
        switch self {
        case .nil: "NilClass"
        case .bool(let b): b ? "TrueClass" : "FalseClass"
        case .int: "Integer"
        case .float: "Float"
        case .string: "String"
        case .symbol: "Symbol"
        case .array: "Array"
        case .hash: "Hash"
        case .range: "Range"
        case .object(let o): o.dslTypeName
        case .block: "Proc"
        }
    }

    /// Converts to plain data: strings, numbers, booleans, arrays, dictionaries.
    /// Symbols become strings and hash keys are stringified, matching podspec JSON.
    public var json: JSON {
        switch self {
        case .nil: .null
        case .bool(let b): .bool(b)
        case .int(let i): .number(Double(i))
        case .float(let d): .number(d)
        case .string(let s), .symbol(let s): .string(s)
        case .array(let items): .array(items.map(\.json))
        case .hash(let pairs): .object(OrderedObject(pairs.map { ($0.key.stringified, $0.value.json) }))
        case .range(let a, let b): .array((a...max(a, b)).map { .number(Double($0)) })
        case .object(let o): .string("#<\(o.dslTypeName)>")
        case .block: .null
        }
    }

    public init(_ json: JSON) {
        switch json {
        case .null: self = .nil
        case .bool(let b): self = .bool(b)
        case .number(let d): self = d == d.rounded() && abs(d) < 1e15 ? .int(Int(d)) : .float(d)
        case .string(let s): self = .string(s)
        case .array(let items): self = .array(items.map(Value.init))
        case .object(let object): self = .hash(object.pairs.map { (.string($0.key), Value($0.value)) })
        }
    }
}

extension Value: Equatable {
    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.nil, .nil): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.float(let a), .float(let b)): a == b
        case (.int(let a), .float(let b)), (.float(let b), .int(let a)): Double(a) == b
        case (.string(let a), .string(let b)): a == b
        case (.symbol(let a), .symbol(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.hash(let a), .hash(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.range(let a1, let b1), .range(let a2, let b2)): a1 == a2 && b1 == b2
        case (.object(let a), .object(let b)): a === b
        case (.block(let a), .block(let b)): a === b
        default: false
        }
    }
}
