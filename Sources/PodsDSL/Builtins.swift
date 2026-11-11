import Foundation
import PodsCore

/// Built-in methods of core Ruby types and global functions.
enum Builtins {
    /// Methods that mutate their receiver; the interpreter writes the result back to the variable.
    static let mutatingMethods: Set<String> = [
        "<<", "push", "append", "concat", "unshift", "prepend", "insert", "pop", "shift", "delete", "clear",
        "merge!", "update", "store", "[]=", "uniq!", "compact!", "flatten!", "sort!", "reverse!", "map!",
        "select!", "reject!", "delete_if", "keep_if", "strip!", "chomp!", "gsub!", "sub!", "upcase!", "downcase!",
    ]

    /// Functions that would execute external commands.
    static let forbiddenFunctions: Set<String> = ["system", "exec", "spawn", "`", "fork", "eval", "instance_eval", "class_eval"]

    // MARK: - Global functions

    static func global(_ name: String, _ call: DSLCall, interpreter: Interpreter) throws -> Value? {
        switch name {
        case "puts", "print", "p", "warn":
            interpreter.print(call.positional.map { name == "p" ? $0.inspected : $0.stringified }.joined(separator: "\n"))
            return .nil
        case "require", "require_relative", "load", "using", "gem":
            return .bool(true) // Libraries are not loaded; supported features are built in.
        case "raise", "abort", "fail":
            throw call.error(call.positional.last?.stringified ?? "Error raised from manifest")
        case "lambda", "proc":
            guard let block = call.block else { throw call.error("\(name) requires a block") }
            return .block(block)
        case "block_given?":
            return .bool(false)
        case "__dir__":
            return .string(interpreter.directory.path)
        case "Integer":
            guard let value = call.positional.first, let int = Int(value.stringified.trimmingWhitespace()) else {
                throw call.error("invalid value for Integer()")
            }
            return .int(int)
        case "String":
            return .string(call.positional.first?.stringified ?? "")
        case "Array":
            switch call.positional.first {
            case .array(let items)?: return .array(items)
            case .nil?, nil: return .array([])
            case let value?: return .array([value])
            }
        case "format", "sprintf":
            guard let template = call.positional.first?.stringValue else { return .string("") }
            return .string(format(template, Array(call.positional.dropFirst())))
        default:
            return nil
        }
    }

    /// A minimal `%s` / `%d` formatter.
    static func format(_ template: String, _ arguments: [Value]) -> String {
        var result = ""
        var remaining = arguments[...]
        var iterator = template.makeIterator()
        while let c = iterator.next() {
            guard c == "%" else { result.append(c); continue }
            switch iterator.next() {
            case "s"?, "d"?, "i"?: result += remaining.popFirst()?.stringified ?? ""
            case "%"?: result.append("%")
            case let other?: result.append("%"); result.append(other)
            case nil: result.append("%")
            }
        }
        return result
    }

    // MARK: - Methods on values

    static func call(_ receiver: inout Value, _ name: String, _ call: DSLCall, interpreter: Interpreter) throws -> Value {
        let args = call.arguments
        let arg = args.first

        // Methods shared by every value.
        switch name {
        case "nil?": return .bool(receiver == .nil)
        case "to_s": return .string(receiver.stringified)
        case "inspect": return .string(receiver.inspected)
        case "==", "eql?", "equal?": return .bool(receiver == arg)
        case "!=": return .bool(receiver != arg)
        case "!": return .bool(!receiver.isTruthy)
        case "frozen?": return .bool(true)
        case "freeze", "dup", "clone", "itself", "to_str": return receiver
        case "class": return .string(receiver.typeName)
        case "is_a?", "kind_of?", "instance_of?":
            return .bool(arg?.stringValue == receiver.typeName || (arg?.stringValue == "Numeric" && (receiver.typeName == "Integer" || receiver.typeName == "Float")))
        case "respond_to?":
            return .bool(true)
        case "tap":
            if let block = call.block { _ = try interpreter.call(block, [receiver]) }
            return receiver
        case "then", "yield_self":
            guard let block = call.block else { return receiver }
            return try interpreter.call(block, [receiver])
        case "===":
            if case .range(let a, let b) = receiver, case .int(let n)? = arg { return .bool(a <= n && n <= b) }
            if case .string(let pattern) = receiver, case .string(let subject)? = arg, name == "===" {
                return .bool(pattern == subject)
            }
            return .bool(receiver == arg)
        default: break
        }

        switch receiver {
        case .nil:
            switch name {
            case "to_a": return .array([])
            case "to_i": return .int(0)
            case "empty?": return .bool(true)
            default: break
            }
        case .bool(let b):
            switch name {
            case "&": return .bool(b && (arg?.isTruthy ?? false))
            case "|": return .bool(b || (arg?.isTruthy ?? false))
            default: break
            }
        case .int, .float:
            if let result = try numeric(receiver, name, arg, call) { return result }
        case .string(let string):
            if let result = try self.string(&receiver, string, name, args, call, interpreter) { return result }
        case .symbol(let symbol):
            switch name {
            case "to_sym": return receiver
            case "to_proc": return .block(DSLBlock(parameters: ["it"], body: [.call(receiver: .variable("it"), name: symbol, arguments: [], block: nil, safeNavigation: false)], scope: Scope(), selfValue: .nil))
            case "<=>": return compare(.string(symbol), arg.map { .string($0.stringified) } ?? .nil)
            case "length", "size", "upcase", "downcase", "start_with?", "end_with?":
                var asString = Value.string(symbol)
                return try self.call(&asString, name, call, interpreter: interpreter)
            default: break
            }
        case .array(let items):
            if let result = try array(&receiver, items, name, args, call, interpreter) { return result }
        case .hash(let pairs):
            if let result = try hash(&receiver, pairs, name, args, call, interpreter) { return result }
        case .range(let a, let b):
            var asArray = Value.array(a > b ? [] : (a...b).map(Value.int))
            switch name {
            case "first": return .int(a)
            case "last": return .int(b)
            case "include?", "cover?", "member?":
                if case .int(let n)? = arg { return .bool(a <= n && n <= b) }
                return .bool(false)
            default: return try self.call(&asArray, name, call, interpreter: interpreter)
            }
        case .object, .block:
            break
        }
        throw call.error("Undefined method '\(name)' for \(receiver.typeName)")
    }

    // MARK: Numbers

    private static func numeric(_ receiver: Value, _ name: String, _ arg: Value?, _ call: DSLCall) throws -> Value? {
        func double(_ v: Value?) -> Double? {
            switch v {
            case .int(let i)?: Double(i)
            case .float(let d)?: d
            default: nil
            }
        }
        if case .int(let a) = receiver, case .int(let b)? = arg {
            switch name {
            case "+": return .int(a + b)
            case "-": return .int(a - b)
            case "*": return .int(a * b)
            case "/":
                guard b != 0 else { throw call.error("divided by 0") }
                return .int(Int((Double(a) / Double(b)).rounded(.down)))
            case "%": return b == 0 ? .nil : .int(((a % b) + b) % b)
            case "**": return .int(Int(pow(Double(a), Double(b))))
            default: break
            }
        }
        let lhs = double(receiver)!
        switch name {
        case "+", "-", "*", "/", "**", "<", ">", "<=", ">=", "<=>":
            guard let rhs = double(arg) else { throw call.error("\(arg?.typeName ?? "nil") can't be coerced into \(receiver.typeName)") }
            switch name {
            case "+": return .float(lhs + rhs)
            case "-": return .float(lhs - rhs)
            case "*": return .float(lhs * rhs)
            case "/": return .float(lhs / rhs)
            case "**": return .float(pow(lhs, rhs))
            case "<": return .bool(lhs < rhs)
            case ">": return .bool(lhs > rhs)
            case "<=": return .bool(lhs <= rhs)
            case ">=": return .bool(lhs >= rhs)
            default: return .int(lhs < rhs ? -1 : (lhs > rhs ? 1 : 0))
            }
        case "to_i", "floor", "to_int": return .int(Int(lhs.rounded(.down)))
        case "ceil": return .int(Int(lhs.rounded(.up)))
        case "round": return .int(Int(lhs.rounded()))
        case "to_f": return .float(lhs)
        case "zero?": return .bool(lhs == 0)
        case "positive?": return .bool(lhs > 0)
        case "negative?": return .bool(lhs < 0)
        case "abs": if case .int(let i) = receiver { return .int(abs(i)) } else { return .float(abs(lhs)) }
        case "times":
            guard case .int(let n) = receiver, let block = call.block else { return nil }
            for i in 0..<max(0, n) { _ = try call.interpreter.call(block, [.int(i)]) }
            return receiver
        default: return nil
        }
    }

    // MARK: Strings

    private static func string(
        _ receiver: inout Value, _ s: String, _ name: String, _ args: [Value], _ call: DSLCall, _ interpreter: Interpreter
    ) throws -> Value? {
        let arg = args.first
        switch name {
        case "+":
            guard case .string(let other)? = arg else { throw call.error("no implicit conversion of \(arg?.typeName ?? "nil") into String") }
            return .string(s + other)
        case "*":
            guard case .int(let n)? = arg else { return nil }
            return .string(String(repeating: s, count: max(0, n)))
        case "%":
            if case .array(let items)? = arg { return .string(format(s, items)) }
            return .string(format(s, arg.map { [$0] } ?? []))
        case "<<", "concat":
            let result = Value.string(s + (arg?.stringified ?? ""))
            receiver = result
            return result
        case "<", ">", "<=", ">=", "<=>":
            guard let other = arg?.stringValue else { return nil }
            switch name {
            case "<": return .bool(s < other)
            case ">": return .bool(s > other)
            case "<=": return .bool(s <= other)
            case ">=": return .bool(s >= other)
            default: return compare(receiver, .string(other))
            }
        case "=~", "match", "match?":
            guard let pattern = arg?.stringValue, let regex = try? NSRegularExpression(pattern: pattern) else { return .nil }
            let range = regex.rangeOfFirstMatch(in: s, range: NSRange(s.startIndex..., in: s))
            if name == "match?" { return .bool(range.location != NSNotFound) }
            return range.location == NSNotFound ? .nil : .int(range.location)
        case "to_s", "to_str": return receiver
        case "to_sym", "intern": return .symbol(s)
        case "to_i": return .int(Int(s.prefix(while: { $0.isNumber || $0 == "-" })) ?? 0)
        case "to_f": return .float(Double(s.trimmingWhitespace()) ?? 0)
        case "length", "size": return .int(s.count)
        case "empty?": return .bool(s.isEmpty)
        case "strip": return .string(s.trimmingWhitespace())
        case "lstrip": return .string(String(s.drop(while: { $0.isWhitespace })))
        case "rstrip": return .string(String(s.reversed().drop(while: { $0.isWhitespace }).reversed()))
        case "chomp":
            if let suffix = arg?.stringValue { return .string(s.hasSuffix(suffix) ? String(s.dropLast(suffix.count)) : s) }
            return .string(s.hasSuffix("\n") ? String(s.dropLast()) : s)
        case "strip!", "chomp!", "upcase!", "downcase!":
            var copy = receiver
            receiver = try Builtins.call(&copy, String(name.dropLast()), call, interpreter: interpreter)
            return receiver
        case "upcase": return .string(s.uppercased())
        case "downcase": return .string(s.lowercased())
        case "capitalize": return .string(s.prefix(1).uppercased() + s.dropFirst().lowercased())
        case "reverse": return .string(String(s.reversed()))
        case "start_with?": return .bool(args.contains { $0.stringValue.map(s.hasPrefix) ?? false })
        case "end_with?": return .bool(args.contains { $0.stringValue.map(s.hasSuffix) ?? false })
        case "include?": return .bool(arg?.stringValue.map(s.contains) ?? false)
        case "split":
            let separator = arg?.stringValue
            let parts: [String] = if let separator, separator != " " {
                s.components(separatedBy: separator)
            } else {
                s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            }
            return .array(parts.map(Value.string))
        case "lines":
            return .array(s.split(separator: "\n", omittingEmptySubsequences: false).map { .string(String($0) + "\n") }.dropLast(s.hasSuffix("\n") ? 1 : 0))
        case "chars": return .array(s.map { .string(String($0)) })
        case "sub", "gsub", "sub!", "gsub!", "tr", "delete":
            let global = name.hasPrefix("g") || name == "tr" || name == "delete"
            guard let pattern = arg?.stringValue else { return nil }
            let replacement = name == "delete" ? "" : (args.count > 1 ? args[1].stringified : "")
            let result: String
            if name == "tr" || name == "delete" {
                let replacementChars = Array(replacement)
                result = String(s.compactMap { c -> Character? in
                    guard let i = Array(pattern).firstIndex(of: c) else { return c }
                    if name == "delete" { return nil }
                    return replacementChars.isEmpty ? nil : replacementChars[min(i, replacementChars.count - 1)]
                })
            } else if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..., in: s)
                let template = replacement.replacingOccurrences(of: "\\\\(\\d)", with: "\\$$1", options: .regularExpression)
                if global {
                    result = regex.stringByReplacingMatches(in: s, range: range, withTemplate: template)
                } else if let match = regex.firstMatch(in: s, range: range) {
                    let replaced = regex.replacementString(for: match, in: s, offset: 0, template: template)
                    var replacedString = s
                    if let matched = Range(match.range, in: s) { replacedString.replaceSubrange(matched, with: replaced) }
                    result = replacedString
                } else {
                    result = s
                }
            } else {
                result = global ? s.replacingOccurrences(of: pattern, with: replacement)
                    : s.range(of: pattern).map { s.replacingCharacters(in: $0, with: replacement) } ?? s
            }
            if name.hasSuffix("!") { receiver = .string(result) }
            return .string(result)
        case "[]":
            switch arg {
            case .int(let i)?:
                let index = i < 0 ? s.count + i : i
                guard index >= 0, index < s.count else { return .nil }
                if args.count > 1, case .int(let length) = args[1] {
                    return .string(String(s.dropFirst(index).prefix(length)))
                }
                return .string(String(s[s.index(s.startIndex, offsetBy: index)]))
            case .range(let a, let b)?:
                let lower = max(0, a < 0 ? s.count + a : a)
                let upper = b < 0 ? s.count + b : b
                guard lower <= upper, lower < s.count else { return .string("") }
                return .string(String(s.dropFirst(lower).prefix(upper - lower + 1)))
            case .string(let sub)?:
                return s.contains(sub) ? .string(sub) : .nil
            default: return .nil
            }
        case "each_line":
            guard let block = call.block else { return nil }
            for line in s.split(separator: "\n") { _ = try interpreter.call(block, [.string(String(line) + "\n")]) }
            return receiver
        default:
            return nil
        }
    }

    // MARK: Arrays

    private static func array(
        _ receiver: inout Value, _ items: [Value], _ name: String, _ args: [Value], _ call: DSLCall, _ interpreter: Interpreter
    ) throws -> Value? {
        let arg = args.first
        func each(_ body: (Value) throws -> Void) throws {
            guard call.block != nil else { throw call.error("\(name) requires a block") }
            for item in items { try body(item) }
        }
        func yield(_ item: Value) throws -> Value {
            try interpreter.call(call.block!, [item])
        }
        switch name {
        case "<<", "push", "append":
            receiver = .array(items + args)
            return receiver
        case "concat":
            receiver = .array(items + args.flatMap { $0.arrayValue ?? [$0] })
            return receiver
        case "unshift", "prepend":
            receiver = .array(args + items)
            return receiver
        case "pop":
            receiver = .array(Array(items.dropLast()))
            return items.last ?? .nil
        case "shift":
            receiver = .array(Array(items.dropFirst()))
            return items.first ?? .nil
        case "delete":
            receiver = .array(items.filter { $0 != arg })
            return items.contains { $0 == arg } ? arg! : .nil
        case "clear":
            receiver = .array([])
            return receiver
        case "+":
            guard case .array(let other)? = arg else { throw call.error("no implicit conversion into Array") }
            return .array(items + other)
        case "-":
            guard case .array(let other)? = arg else { throw call.error("no implicit conversion into Array") }
            return .array(items.filter { !other.contains($0) })
        case "&":
            guard case .array(let other)? = arg else { return nil }
            return .array(unique(items.filter { other.contains($0) }))
        case "|":
            guard case .array(let other)? = arg else { return nil }
            return .array(unique(items + other))
        case "[]":
            switch arg {
            case .int(let i)?:
                let index = i < 0 ? items.count + i : i
                if args.count > 1, case .int(let length) = args[1] {
                    guard index >= 0, index <= items.count else { return .nil }
                    return .array(Array(items[index..<min(items.count, index + length)]))
                }
                return index >= 0 && index < items.count ? items[index] : .nil
            case .range(let a, let b)?:
                let lower = a < 0 ? items.count + a : a
                let upper = min(items.count - 1, b < 0 ? items.count + b : b)
                guard lower >= 0, lower <= items.count else { return .nil }
                return .array(lower > upper ? [] : Array(items[lower...upper]))
            default: return .nil
            }
        case "[]=":
            guard case .int(let i)? = arg, args.count == 2 else { return nil }
            var copy = items
            let index = i < 0 ? copy.count + i : i
            while copy.count <= index { copy.append(.nil) }
            copy[index] = args[1]
            receiver = .array(copy)
            return args[1]
        case "first":
            if case .int(let n)? = arg { return .array(Array(items.prefix(n))) }
            return items.first ?? .nil
        case "last":
            if case .int(let n)? = arg { return .array(Array(items.suffix(n))) }
            return items.last ?? .nil
        case "length", "size", "count":
            if let block = call.block { return .int(try items.filter { try interpreter.call(block, [$0]).isTruthy }.count) }
            if let arg { return .int(items.filter { $0 == arg }.count) }
            return .int(items.count)
        case "empty?": return .bool(items.isEmpty)
        case "any?":
            if let block = call.block { return .bool(try items.contains { try interpreter.call(block, [$0]).isTruthy }) }
            return .bool(items.contains { $0.isTruthy })
        case "all?":
            guard let block = call.block else { return .bool(items.allSatisfy(\.isTruthy)) }
            return .bool(try items.allSatisfy { try interpreter.call(block, [$0]).isTruthy })
        case "none?":
            guard let block = call.block else { return .bool(!items.contains { $0.isTruthy }) }
            return .bool(try !items.contains { try interpreter.call(block, [$0]).isTruthy })
        case "include?", "member?": return .bool(items.contains { $0 == arg })
        case "index", "find_index":
            if let block = call.block { return try items.firstIndex { try interpreter.call(block, [$0]).isTruthy }.map(Value.int) ?? .nil }
            return items.firstIndex { $0 == arg }.map(Value.int) ?? .nil
        case "join":
            let separator = arg?.stringValue ?? ""
            return .string(flatten(items).map(\.stringified).joined(separator: separator))
        case "flatten": return .array(flatten(items))
        case "flatten!": receiver = .array(flatten(items)); return receiver
        case "compact": return .array(items.filter { $0 != .nil })
        case "compact!": receiver = .array(items.filter { $0 != .nil }); return receiver
        case "uniq": return .array(unique(items))
        case "uniq!": receiver = .array(unique(items)); return receiver
        case "reverse": return .array(items.reversed())
        case "sort", "sort!":
            let sorted = try items.sorted { a, b in
                if let block = call.block { return try interpreter.call(block, [a, b]) == .int(-1) }
                return compare(a, b) == .int(-1)
            }
            if name == "sort!" { receiver = .array(sorted) }
            return .array(sorted)
        case "sort_by":
            guard let block = call.block else { return nil }
            let keyed = try items.map { ($0, try interpreter.call(block, [$0])) }
            return .array(keyed.sorted { compare($0.1, $1.1) == .int(-1) }.map(\.0))
        case "min": return items.min { compare($0, $1) == .int(-1) } ?? .nil
        case "max": return items.max { compare($0, $1) == .int(-1) } ?? .nil
        case "sum":
            var total = arg ?? .int(0)
            for item in items { total = try Builtins.call(&total, "+", DSLCall(positional: [item], options: [], block: nil, interpreter: interpreter, line: call.line), interpreter: interpreter) }
            return total
        case "each":
            try each { _ = try yield($0) }
            return receiver
        case "each_with_index":
            guard let block = call.block else { return nil }
            for (i, item) in items.enumerated() { _ = try interpreter.call(block, [item, .int(i)]) }
            return receiver
        case "each_with_object", "inject", "reduce":
            guard let block = call.block else { return nil }
            var memo = arg ?? items.first ?? .nil
            let source = arg == nil ? Array(items.dropFirst()) : items
            for item in source {
                if name == "each_with_object" {
                    _ = try interpreter.call(block, [item, memo])
                } else {
                    memo = try interpreter.call(block, [memo, item])
                }
            }
            return memo
        case "map", "collect", "map!", "flat_map":
            guard call.block != nil else { return nil }
            var mapped = try items.map(yield)
            if name == "flat_map" { mapped = mapped.flatMap { $0.arrayValue ?? [$0] } }
            if name == "map!" { receiver = .array(mapped) }
            return .array(mapped)
        case "select", "filter", "select!", "keep_if":
            guard call.block != nil else { return nil }
            let selected = try items.filter { try yield($0).isTruthy }
            if name.hasSuffix("!") || name == "keep_if" { receiver = .array(selected) }
            return .array(selected)
        case "reject", "reject!", "delete_if":
            guard call.block != nil else { return nil }
            let kept = try items.filter { try !yield($0).isTruthy }
            if name != "reject" { receiver = .array(kept) }
            return .array(kept)
        case "find", "detect":
            guard call.block != nil else { return nil }
            return try items.first { try yield($0).isTruthy } ?? .nil
        case "partition":
            guard call.block != nil else { return nil }
            var yes: [Value] = [], no: [Value] = []
            for item in items { if try yield(item).isTruthy { yes.append(item) } else { no.append(item) } }
            return .array([.array(yes), .array(no)])
        case "group_by":
            guard call.block != nil else { return nil }
            var groups: [(key: Value, value: Value)] = []
            for item in items {
                let key = try yield(item)
                if let index = groups.firstIndex(where: { $0.key == key }), case .array(let existing) = groups[index].value {
                    groups[index].value = .array(existing + [item])
                } else {
                    groups.append((key, .array([item])))
                }
            }
            return .hash(groups)
        case "to_a", "entries": return receiver
        case "to_h":
            return .hash(items.compactMap { item in
                guard case .array(let pair) = item, pair.count == 2 else { return nil }
                return (pair[0], pair[1])
            })
        case "zip":
            guard case .array(let other)? = arg else { return nil }
            return .array(items.enumerated().map { .array([$0.element, $0.offset < other.count ? other[$0.offset] : .nil]) })
        case "take": if case .int(let n)? = arg { return .array(Array(items.prefix(n))) }; return nil
        case "drop": if case .int(let n)? = arg { return .array(Array(items.dropFirst(n))) }; return nil
        case "<=>": return compare(receiver, arg ?? .nil)
        default: return nil
        }
    }

    // MARK: Hashes

    private static func hash(
        _ receiver: inout Value, _ pairs: [(key: Value, value: Value)], _ name: String, _ args: [Value], _ call: DSLCall, _ interpreter: Interpreter
    ) throws -> Value? {
        let arg = args.first
        func lookup(_ key: Value?) -> Value? { pairs.first { $0.key == key }?.value }
        switch name {
        case "[]": return lookup(arg) ?? .nil
        case "[]=", "store":
            guard args.count == 2 else { return nil }
            var copy = pairs
            Interpreter.store(&copy, args[0], args[1])
            receiver = .hash(copy)
            return args[1]
        case "fetch":
            if let value = lookup(arg) { return value }
            if args.count > 1 { return args[1] }
            if let block = call.block { return try interpreter.call(block, [arg ?? .nil]) }
            throw call.error("key not found: \(arg?.inspected ?? "nil")")
        case "dig":
            var current: Value = receiver
            for key in args {
                var copy = current
                current = (try? Builtins.call(&copy, "[]", DSLCall(positional: [key], options: [], block: nil, interpreter: interpreter, line: call.line), interpreter: interpreter)) ?? .nil
                if current == .nil { break }
            }
            return current
        case "key?", "has_key?", "include?", "member?": return .bool(lookup(arg) != nil)
        case "value?", "has_value?": return .bool(pairs.contains { $0.value == arg })
        case "keys": return .array(pairs.map(\.key))
        case "values": return .array(pairs.map(\.value))
        case "length", "size", "count": return .int(pairs.count)
        case "empty?": return .bool(pairs.isEmpty)
        case "merge", "merge!", "update":
            var merged = pairs
            for case .hash(let other) in args {
                for pair in other { Interpreter.store(&merged, pair.key, pair.value) }
            }
            if name != "merge" { receiver = .hash(merged) }
            return .hash(merged)
        case "delete":
            receiver = .hash(pairs.filter { $0.key != arg })
            return lookup(arg) ?? .nil
        case "to_h", "to_hash": return receiver
        case "to_a": return .array(pairs.map { .array([$0.key, $0.value]) })
        case "each", "each_pair":
            guard let block = call.block else { return nil }
            for pair in pairs { _ = try interpreter.call(block, [pair.key, pair.value]) }
            return receiver
        case "map", "collect", "flat_map":
            guard let block = call.block else { return nil }
            var result = try pairs.map { try interpreter.call(block, [$0.key, $0.value]) }
            if name == "flat_map" { result = result.flatMap { $0.arrayValue ?? [$0] } }
            return .array(result)
        case "select", "filter", "reject":
            guard let block = call.block else { return nil }
            return .hash(try pairs.filter { try interpreter.call(block, [$0.key, $0.value]).isTruthy == (name != "reject") })
        case "transform_values":
            guard let block = call.block else { return nil }
            return .hash(try pairs.map { ($0.key, try interpreter.call(block, [$0.value])) })
        case "transform_keys":
            guard let block = call.block else { return nil }
            return .hash(try pairs.map { (try interpreter.call(block, [$0.key]), $0.value) })
        case "any?":
            guard let block = call.block else { return .bool(!pairs.isEmpty) }
            return .bool(try pairs.contains { try interpreter.call(block, [$0.key, $0.value]).isTruthy })
        default: return nil
        }
    }

    // MARK: Helpers

    static func compare(_ a: Value, _ b: Value) -> Value {
        switch (a, b) {
        case (.int(let x), .int(let y)): .int(x < y ? -1 : (x > y ? 1 : 0))
        case (.float(let x), .float(let y)): .int(x < y ? -1 : (x > y ? 1 : 0))
        case (.int(let x), .float(let y)): .int(Double(x) < y ? -1 : (Double(x) > y ? 1 : 0))
        case (.float(let x), .int(let y)): .int(x < Double(y) ? -1 : (x > Double(y) ? 1 : 0))
        case (.array(let x), .array(let y)):
            zip(x, y).lazy.map { compare($0, $1) }.first { $0 != .int(0) } ?? .int(x.count < y.count ? -1 : (x.count > y.count ? 1 : 0))
        default:
            if let x = a.stringValue, let y = b.stringValue { .int(x < y ? -1 : (x > y ? 1 : 0)) } else { .nil }
        }
    }

    private static func flatten(_ items: [Value]) -> [Value] {
        items.flatMap { item -> [Value] in
            if case .array(let nested) = item { flatten(nested) } else { [item] }
        }
    }

    private static func unique(_ items: [Value]) -> [Value] {
        var result: [Value] = []
        for item in items where !result.contains(item) { result.append(item) }
        return result
    }
}
