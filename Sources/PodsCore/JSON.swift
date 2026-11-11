public import Foundation

/// An insertion-ordered JSON object. Key order is preserved so that generated files are stable.
public struct OrderedObject: Sendable, Hashable {
    public private(set) var pairs: [(key: String, value: JSON)]

    public init(_ pairs: [(String, JSON)] = []) {
        self.pairs = []
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> JSON? {
        get { pairs.first { $0.key == key }?.value }
        set {
            if let index = pairs.firstIndex(where: { $0.key == key }) {
                if let newValue { pairs[index].value = newValue } else { pairs.remove(at: index) }
            } else if let newValue {
                pairs.append((key, newValue))
            }
        }
    }

    public var keys: [String] { pairs.map(\.key) }
    public var isEmpty: Bool { pairs.isEmpty }

    public static func == (lhs: OrderedObject, rhs: OrderedObject) -> Bool {
        lhs.pairs.count == rhs.pairs.count && zip(lhs.pairs, rhs.pairs).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        for pair in pairs {
            hasher.combine(pair.key)
            hasher.combine(pair.value)
        }
    }
}

/// A JSON value. Used as the canonical, `Sendable` representation of podspecs and manifests.
public enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(OrderedObject)

    public subscript(key: String) -> JSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): String(b)
        default: nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .string(let s): s == "true" ? true : (s == "false" ? false : nil)
        default: nil
        }
    }

    public var array: [JSON]? {
        if case .array(let a) = self { a } else { nil }
    }

    public var object: OrderedObject? {
        if case .object(let o) = self { o } else { nil }
    }

    /// A string or an array of strings, normalised to an array (podspec "string or list" attributes).
    public var stringList: [String] {
        switch self {
        case .string(let s): [s]
        case .array(let items): items.compactMap(\.string)
        default: []
        }
    }

    // MARK: - Serialization

    public init(data: Data) throws {
        var parser = OrderedJSONParser(bytes: Array(data))
        self = try parser.parse()
    }

    public init(parsing string: String) throws {
        try self.init(data: Data(string.utf8))
    }

    /// Serializes preserving key order and two-space indentation.
    public func serialized(pretty: Bool = true) -> String {
        var output = ""
        write(to: &output, indent: 0, pretty: pretty)
        return output
    }

    private func write(to output: inout String, indent: Int, pretty: Bool) {
        let newline = pretty ? "\n" : ""
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let closingPad = pretty ? String(repeating: "  ", count: indent) : ""
        switch self {
        case .null: output += "null"
        case .bool(let b): output += b ? "true" : "false"
        case .number(let n):
            output += n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .string(let s): output += Self.escape(s)
        case .array(let items):
            if items.isEmpty { output += "[]"; return }
            output += "[" + newline
            for (i, item) in items.enumerated() {
                output += pad
                item.write(to: &output, indent: indent + 1, pretty: pretty)
                output += (i < items.count - 1 ? "," : "") + newline
            }
            output += closingPad + "]"
        case .object(let object):
            if object.isEmpty { output += "{}"; return }
            output += "{" + newline
            for (i, pair) in object.pairs.enumerated() {
                output += pad + Self.escape(pair.key) + (pretty ? ": " : ":")
                pair.value.write(to: &output, indent: indent + 1, pretty: pretty)
                output += (i < object.pairs.count - 1 ? "," : "") + newline
            }
            output += closingPad + "}"
        }
    }

    private static func escape(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case let s where s.value < 0x20: result += String(format: "\\u%04x", s.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

/// A small JSON parser that keeps object key order.
private struct OrderedJSONParser {
    let bytes: [UInt8]
    var index = 0

    struct Failure: Error, CustomStringConvertible {
        let offset: Int
        var description: String { "Invalid JSON at offset \(offset)" }
    }

    mutating func parse() throws -> JSON {
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw Failure(offset: index) }
        return value
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue() throws -> JSON {
        skipWhitespace()
        guard index < bytes.count else { throw Failure(offset: index) }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var object = OrderedObject()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Failure(offset: index) }
                index += 1
                object[key] = try parseValue()
                skipWhitespace()
                guard index < bytes.count else { throw Failure(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
                throw Failure(offset: index)
            }
        case UInt8(ascii: "["):
            index += 1
            var items: [JSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                guard index < bytes.count else { throw Failure(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw Failure(offset: index)
            }
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null"); return .null
        default:
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw Failure(offset: start)
            }
            return .number(number)
        }
    }

    mutating func expectLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw Failure(offset: index)
        }
        index += expected.count
    }

    mutating func parseString() throws -> String {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Failure(offset: index) }
        index += 1
        var scalars = String.UnicodeScalarView()
        var buffer: [UInt8] = []
        func flush() {
            scalars.append(contentsOf: String(decoding: buffer, as: UTF8.self).unicodeScalars)
            buffer.removeAll()
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") { flush(); return String(scalars) }
            if byte != UInt8(ascii: "\\") { buffer.append(byte); continue }
            flush()
            guard index < bytes.count else { break }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "u"):
                var code = try readHex4()
                if (0xD800..<0xDC00).contains(code), index + 1 < bytes.count,
                   bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    index += 2
                    let low = try readHex4()
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            default: scalars.append(Unicode.Scalar(escape))
            }
        }
        throw Failure(offset: index)
    }

    mutating func readHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw Failure(offset: index) }
        index += 4
        return value
    }
}
