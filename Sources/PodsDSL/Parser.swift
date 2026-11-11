/// Recursive-descent parser for the supported Ruby subset.
struct Parser {
    private let tokens: [Token]
    private let file: String
    private var position = 0
    /// Known local variables per scope, used (like Ruby itself) to tell `foo` (variable) from `foo` (call).
    private var locals: [Set<String>] = [[]]
    /// `do ... end` binds to the outermost command call, so it is disabled while parsing command arguments.
    private var allowsDoBlock = true

    init(tokens: [Token], file: String, locals: Set<String> = []) {
        self.tokens = tokens
        self.file = file
        self.locals = [locals]
    }

    static func parse(_ source: String, file: String, line: Int = 1, locals: Set<String> = []) throws(DSLError) -> [Node] {
        var parser = Parser(tokens: try Lexer.tokenize(source, file: file, line: line), file: file, locals: locals)
        return try parser.parseProgram()
    }

    // MARK: - Token helpers

    private var current: Token { tokens[position] }
    private var currentKind: TokenKind { current.kind }

    private func peekKind(_ offset: Int = 1) -> TokenKind {
        let i = position + offset
        return i < tokens.count ? tokens[i].kind : .eof
    }

    @discardableResult
    private mutating func advance() -> Token {
        let token = tokens[position]
        if position < tokens.count - 1 { position += 1 }
        return token
    }

    private func error(_ message: String) -> DSLError {
        DSLError(message, file: file, line: current.line)
    }

    private func isOp(_ op: String) -> Bool { currentKind == .op(op) }
    private func isKeyword(_ keyword: String) -> Bool { currentKind == .keyword(keyword) }

    private mutating func accept(op: String) -> Bool {
        guard isOp(op) else { return false }
        advance(); return true
    }

    private mutating func accept(keyword: String) -> Bool {
        guard isKeyword(keyword) else { return false }
        advance(); return true
    }

    private mutating func expect(op: String) throws(DSLError) {
        guard accept(op: op) else { throw error("Expected '\(op)' but found \(describe(currentKind))") }
    }

    private mutating func expect(keyword: String) throws(DSLError) {
        guard accept(keyword: keyword) else { throw error("Expected '\(keyword)' but found \(describe(currentKind))") }
    }

    private mutating func skipNewlines() {
        while currentKind == .newline { advance() }
    }

    private func describe(_ kind: TokenKind) -> String {
        switch kind {
        case .identifier(let s), .constant(let s): "'\(s)'"
        case .keyword(let s): "keyword '\(s)'"
        case .op(let s): "'\(s)'"
        case .newline: "end of line"
        case .eof: "end of file"
        case .string: "string"
        case .symbol(let s): "symbol :\(s)"
        case .label(let s): "label \(s):"
        default: "token"
        }
    }

    private mutating func declare(_ name: String) { locals[locals.count - 1].insert(name) }
    private func isLocal(_ name: String) -> Bool { locals.contains { $0.contains(name) } }

    // MARK: - Statements

    mutating func parseProgram() throws(DSLError) -> [Node] {
        let body = try parseStatements(until: [])
        guard currentKind == .eof else { throw error("Unexpected \(describe(currentKind))") }
        return body
    }

    /// Parses statements until one of the given keywords (or `}` when `"}"` is passed).
    private mutating func parseStatements(until terminators: Set<String>) throws(DSLError) -> [Node] {
        var statements: [Node] = []
        while true {
            skipNewlines()
            if currentKind == .eof { break }
            if case .keyword(let k) = currentKind, terminators.contains(k) { break }
            if terminators.contains("}"), isOp("}") { break }
            let line = current.line
            statements.append(.located(line: line, try parseStatement()))
            guard currentKind == .newline || currentKind == .eof || isOp("}")
                || terminators.contains(where: { isKeyword($0) }) else {
                throw error("Unexpected \(describe(currentKind))")
            }
        }
        return statements
    }

    private mutating func parseStatement() throws(DSLError) -> Node {
        var node = try parseExpressionStatement()
        // Statement modifiers: `foo if bar`, `foo unless bar`, `foo while bar`.
        while true {
            if accept(keyword: "if") {
                node = .conditional(branches: [(try parseExpressionStatement(), [node])], elseBody: nil)
            } else if accept(keyword: "unless") {
                node = .conditional(branches: [(.not(try parseExpressionStatement()), [node])], elseBody: nil)
            } else if accept(keyword: "while") {
                node = .whileLoop(condition: try parseExpressionStatement(), body: [node], negated: false)
            } else if accept(keyword: "rescue") {
                node = .begin(body: [node], rescue: [try parseExpressionStatement()], ensure: nil)
            } else {
                return node
            }
        }
    }

    /// `not`, `and`, `or` have the lowest precedence.
    private mutating func parseExpressionStatement() throws(DSLError) -> Node {
        var left = try parseNotExpression()
        while true {
            if accept(keyword: "and") {
                skipNewlines(); left = .and(left, try parseNotExpression())
            } else if accept(keyword: "or") {
                skipNewlines(); left = .or(left, try parseNotExpression())
            } else {
                return left
            }
        }
    }

    private mutating func parseNotExpression() throws(DSLError) -> Node {
        if accept(keyword: "not") { return .not(try parseNotExpression()) }
        if accept(keyword: "return") {
            if currentKind == .newline || currentKind == .eof || isKeyword("end") || isKeyword("if") || isKeyword("unless") {
                return .returnValue(nil)
            }
            return .returnValue(try parseExpression())
        }
        return try parseExpression()
    }

    // MARK: - Expressions

    mutating func parseExpression() throws(DSLError) -> Node {
        let left = try parseTernary()
        if isOp("=") && isAssignable(left) {
            advance(); skipNewlines()
            if case .variable(let name) = left { declare(name) }
            if let name = bareCallName(left) { declare(name) }
            let value = try parseAssignedValue()
            return .assign(target: normalizeTarget(left), value: value)
        }
        for op in ["||=", "&&=", "+=", "-=", "*=", "/=", "<<="] where isOp(op) && isAssignable(left) {
            advance(); skipNewlines()
            if let name = bareCallName(left) { declare(name) }
            if case .variable(let name) = left { declare(name) }
            return .opAssign(target: normalizeTarget(left), op: String(op.dropLast()), value: try parseAssignedValue())
        }
        return left
    }

    /// The right-hand side of an assignment; `a = 1, 2` builds an array.
    private mutating func parseAssignedValue() throws(DSLError) -> Node {
        let first = try parseExpression()
        guard isOp(",") else { return first }
        var items = [first]
        while accept(op: ",") {
            skipNewlines(); items.append(try parseExpression())
        }
        return .array(items)
    }

    private func isAssignable(_ node: Node) -> Bool {
        switch node {
        case .variable, .instanceVariable, .index, .constant: true
        case .call(_, _, let args, nil, _): args.isEmpty
        default: false
        }
    }

    private func normalizeTarget(_ node: Node) -> Node {
        if let name = bareCallName(node) { return .variable(name) }
        return node
    }

    /// The name of a receiver-less call without arguments or block (`foo`), which may become a variable.
    private func bareCallName(_ node: Node) -> String? {
        if case .call(nil, let name, let arguments, nil, _) = node, arguments.isEmpty { name } else { nil }
    }

    private mutating func parseTernary() throws(DSLError) -> Node {
        let condition = try parseRange()
        guard isOp("?") else { return condition }
        advance(); skipNewlines()
        let whenTrue = try parseTernary()
        skipNewlines()
        if case .label = currentKind {
            throw error("Write ternaries with spaces around ':'")
        }
        try expect(op: ":"); skipNewlines()
        let whenFalse = try parseTernary()
        return .ternary(condition, whenTrue, whenFalse)
    }

    private mutating func parseRange() throws(DSLError) -> Node {
        let left = try parseBinary(precedence: 0)
        if isOp("..") || isOp("...") {
            let exclusive = isOp("...")
            advance()
            return .range(left, try parseBinary(precedence: 0), exclusive: exclusive)
        }
        return left
    }

    private static let binaryPrecedence: [[String]] = [
        ["||"],
        ["&&"],
        ["==", "!=", "=~", "!~", "===", "<=>"],
        ["<", ">", "<=", ">="],
        ["|", "^"],
        ["&"],
        ["<<"],
        ["+", "-"],
        ["*", "/", "%"],
        ["**"],
    ]

    private mutating func parseBinary(precedence: Int) throws(DSLError) -> Node {
        guard precedence < Self.binaryPrecedence.count else { return try parseUnary() }
        var left = try parseBinary(precedence: precedence + 1)
        while case .op(let op) = currentKind, Self.binaryPrecedence[precedence].contains(op) {
            advance(); skipNewlines()
            let right = try parseBinary(precedence: precedence + 1)
            left = switch op {
            case "||": .or(left, right)
            case "&&": .and(left, right)
            case "!=": .not(.binary(op: "==", left, right))
            case "!~": .not(.binary(op: "=~", left, right))
            default: .binary(op: op, left, right)
            }
        }
        return left
    }

    private mutating func parseUnary() throws(DSLError) -> Node {
        if accept(op: "!") { return .not(try parseUnary()) }
        if isOp("-"), case .integer(let n) = peekKind() {
            advance(); advance(); return try parsePostfix(.literal(.int(-n)))
        }
        if isOp("-"), case .float(let n) = peekKind() {
            advance(); advance(); return try parsePostfix(.literal(.float(-n)))
        }
        if accept(op: "-") { return .binary(op: "-", .literal(.int(0)), try parseUnary()) }
        return try parsePostfix(try parsePrimary())
    }

    // MARK: - Postfix (method calls, indexing)

    private mutating func parsePostfix(_ base: Node) throws(DSLError) -> Node {
        var node = base
        while true {
            // Allow leading-dot method chains on the next line.
            if currentKind == .newline, peekKind() == .op(".") || peekKind() == .op("&.") {
                skipNewlines()
            }
            if isOp(".") || isOp("&.") {
                let safe = isOp("&.")
                advance(); skipNewlines()
                let name: String
                switch currentKind {
                case .identifier(let n), .constant(let n): name = n; advance()
                case .label(let n):
                    // `foo.bar: baz` cannot happen; treat as name followed by a symbol-ish ':'.
                    name = n; advance()
                case .op("("):
                    name = "call" // `proc.(args)`
                default: throw error("Expected method name after '.'")
                }
                node = try parseCallRest(receiver: node, name: name, safe: safe)
            } else if isOp("::") {
                advance()
                guard case .constant(let name) = currentKind else {
                    if case .identifier(let name) = currentKind {
                        advance(); node = try parseCallRest(receiver: node, name: name, safe: false); continue
                    }
                    throw error("Expected constant after '::'")
                }
                advance()
                if case .constant(let path) = node {
                    node = .constant(path: path + [name])
                } else {
                    node = .call(receiver: node, name: name, arguments: [], block: nil, safeNavigation: false)
                }
            } else if isOp("["), !current.spaceBefore {
                advance(); skipNewlines()
                var indices: [Node] = []
                while !isOp("]") {
                    indices.append(try parseExpression()); skipNewlines()
                    if !accept(op: ",") { break }
                    skipNewlines()
                }
                skipNewlines()
                try expect(op: "]")
                node = .index(node, indices)
            } else {
                return node
            }
        }
    }

    /// After `receiver.name`: parses `(args)`, command args and a block.
    private mutating func parseCallRest(receiver: Node?, name: String, safe: Bool) throws(DSLError) -> Node {
        var arguments: [Argument] = []
        if isOp("("), !current.spaceBefore {
            arguments = try parseParenthesizedArguments()
        } else if canStartCommandArgument {
            arguments = try parseCommandArguments()
        }
        let block = try parseBlockIfPresent()
        return .call(receiver: receiver, name: name, arguments: arguments, block: block, safeNavigation: safe)
    }

    /// Whether the current token can begin an argument of a parenthesis-less call.
    private var canStartCommandArgument: Bool {
        guard current.spaceBefore else { return false }
        switch currentKind {
        case .string, .symbol, .integer, .float, .identifier, .constant, .instanceVariable, .label, .words:
            return true
        case .keyword(let k):
            return ["nil", "true", "false", "self", "not", "__FILE__", "__dir__"].contains(k)
        case .op(let op):
            // `foo [1]`, `foo -1`, `foo *args`, `foo ->{}` and `foo !x` are arguments; `foo - 1` is subtraction.
            let next = position + 1 < tokens.count ? tokens[position + 1] : current
            switch op {
            case "[", "(", "->", "::": return true
            case "-", "*", "&", "!": return !next.spaceBefore
            default: return false
            }
        default:
            return false
        }
    }

    private mutating func parseParenthesizedArguments() throws(DSLError) -> [Argument] {
        let saved = allowsDoBlock
        allowsDoBlock = true
        defer { allowsDoBlock = saved }
        try expect(op: "(")
        skipNewlines()
        var arguments: [Argument] = []
        while !isOp(")") {
            arguments.append(try parseArgument())
            skipNewlines()
            if !accept(op: ",") { break }
            skipNewlines()
        }
        skipNewlines()
        try expect(op: ")")
        return arguments
    }

    private mutating func parseCommandArguments() throws(DSLError) -> [Argument] {
        let saved = allowsDoBlock
        allowsDoBlock = false
        defer { allowsDoBlock = saved }
        var arguments = [try parseArgument()]
        while accept(op: ",") {
            skipNewlines()
            arguments.append(try parseArgument())
        }
        return arguments
    }

    private mutating func parseArgument() throws(DSLError) -> Argument {
        if case .label(let key) = currentKind {
            advance(); skipNewlines()
            return .pair(key: .literal(.symbol(key)), value: try parseArgumentValue())
        }
        if isOp("*"), !(position + 1 < tokens.count && tokens[position + 1].spaceBefore) {
            advance(); return .splat(try parseTernary())
        }
        if isOp("**") { advance(); return .splat(try parseTernary()) }
        if isOp("&") { advance(); return .blockPass(try parseTernary()) }
        let value = try parseArgumentValue()
        if accept(op: "=>") {
            skipNewlines()
            return .pair(key: value, value: try parseArgumentValue())
        }
        return .positional(value)
    }

    /// Arguments are full expressions except that `a, b` separates arguments.
    private mutating func parseArgumentValue() throws(DSLError) -> Node {
        if isKeyword("not") { advance(); return .not(try parseArgumentValue()) }
        return try parseExpression()
    }

    private mutating func parseBlockIfPresent() throws(DSLError) -> BlockNode? {
        let saved = allowsDoBlock
        defer { allowsDoBlock = saved }
        if saved, accept(keyword: "do") {
            allowsDoBlock = true
            let params = try parseBlockParameters()
            locals.append(Set(params))
            defer { locals.removeLast() }
            let body = try parseBodyWithRescue(until: ["end"])
            try expect(keyword: "end")
            return BlockNode(parameters: params, body: body)
        }
        if isOp("{") {
            advance()
            allowsDoBlock = true
            let params = try parseBlockParameters()
            locals.append(Set(params))
            defer { locals.removeLast() }
            let body = try parseStatements(until: ["}"])
            skipNewlines()
            try expect(op: "}")
            return BlockNode(parameters: params, body: body)
        }
        return nil
    }

    private mutating func parseBlockParameters() throws(DSLError) -> [String] {
        skipNewlines()
        guard accept(op: "|") else { return [] }
        var names: [String] = []
        while !isOp("|") {
            _ = accept(op: "*"); _ = accept(op: "&"); _ = accept(op: "(")
            guard case .identifier(let name) = currentKind else { throw error("Expected block parameter name") }
            advance(); names.append(name)
            _ = accept(op: ")")
            if !accept(op: ",") { break }
        }
        try expect(op: "|")
        return names
    }

    // MARK: - Primary

    private mutating func parsePrimary() throws(DSLError) -> Node {
        let token = current
        switch token.kind {
        case .integer(let n): advance(); return .literal(.int(n))
        case .float(let n): advance(); return .literal(.float(n))
        case .symbol(let s): advance(); return .literal(.symbol(s))
        case .words(let words, let symbols):
            advance()
            return .array(words.map { .literal(symbols ? .symbol($0) : .string($0)) })
        case .string(let parts):
            advance()
            var node = try stringNode(parts)
            // Adjacent string literals are concatenated: `"a" "b"`.
            while case .string(let more) = currentKind {
                advance()
                node = .binary(op: "+", node, try stringNode(more))
            }
            return node
        case .label(let key):
            // A bare hash as the first command argument has been handled in parseArgument; here it's `{ key: v }`.
            throw DSLError("Unexpected label '\(key):'", file: file, line: token.line)
        case .instanceVariable(let name):
            advance(); return .instanceVariable(name)
        case .constant(let name):
            advance()
            if isOp("("), !current.spaceBefore {
                // `Integer("1")`-style conversion functions.
                return try parseCallRest(receiver: nil, name: name, safe: false)
            }
            return .constant(path: [name])
        case .identifier(let name):
            advance()
            if isLocal(name), !(isOp("(") && !current.spaceBefore) {
                return .variable(name)
            }
            return try parseCallRest(receiver: nil, name: name, safe: false)
        case .keyword(let keyword):
            return try parseKeyword(keyword)
        case .op("("):
            advance(); skipNewlines()
            if accept(op: ")") { return .literal(.nil) }
            var statements: [Node] = []
            while true {
                statements.append(try parseStatement())
                skipNewlines()
                if accept(op: ")") { break }
            }
            return statements.count == 1 ? statements[0] : .begin(body: statements, rescue: nil, ensure: nil)
        case .op("["):
            advance(); skipNewlines()
            var items: [Node] = []
            while !isOp("]") {
                if isOp("*") { advance(); items.append(.call(receiver: try parseTernary(), name: "to_a", arguments: [], block: nil, safeNavigation: false)) }
                else { items.append(try parseExpression()) }
                skipNewlines()
                if !accept(op: ",") { break }
                skipNewlines()
            }
            skipNewlines()
            try expect(op: "]")
            return .array(items)
        case .op("{"):
            return try parseHashLiteral()
        case .op("->"):
            advance()
            var params: [String] = []
            if accept(op: "(") {
                while case .identifier(let name) = currentKind {
                    advance(); params.append(name)
                    if !accept(op: ",") { break }
                }
                try expect(op: ")")
            }
            locals.append(Set(params))
            defer { locals.removeLast() }
            let body: [Node]
            if accept(keyword: "do") {
                body = try parseStatements(until: ["end"]); try expect(keyword: "end")
            } else {
                try expect(op: "{")
                body = try parseStatements(until: ["}"]); skipNewlines(); try expect(op: "}")
            }
            return .lambda(BlockNode(parameters: params, body: body))
        case .op("::"):
            advance()
            guard case .constant(let name) = currentKind else { throw error("Expected constant after '::'") }
            advance()
            return .constant(path: [name])
        default:
            throw DSLError("Unexpected \(describe(token.kind))", file: file, line: token.line)
        }
    }

    private mutating func parseHashLiteral() throws(DSLError) -> Node {
        try expect(op: "{")
        skipNewlines()
        var pairs: [(key: Node, value: Node)] = []
        while !isOp("}") {
            if case .label(let key) = currentKind {
                advance(); skipNewlines()
                pairs.append((.literal(.symbol(key)), try parseExpression()))
            } else if case .string(let parts) = currentKind, peekKind() == .op(":") {
                // `"key": value`
                advance(); advance(); skipNewlines()
                pairs.append((.literal(.symbol(parts.plainText)), try parseExpression()))
            } else {
                let key = try parseExpression()
                skipNewlines()
                try expect(op: "=>")
                skipNewlines()
                pairs.append((key, try parseExpression()))
            }
            skipNewlines()
            if !accept(op: ",") { break }
            skipNewlines()
        }
        skipNewlines()
        try expect(op: "}")
        return .hash(pairs)
    }

    private mutating func parseKeyword(_ keyword: String) throws(DSLError) -> Node {
        let line = current.line
        advance()
        switch keyword {
        case "nil": return .literal(.nil)
        case "true": return .literal(.bool(true))
        case "false": return .literal(.bool(false))
        case "self": return .selfReference
        case "__FILE__": return .literal(.string(file))
        case "__dir__":
            return .call(receiver: nil, name: "__dir__", arguments: [], block: nil, safeNavigation: false)
        case "if", "unless":
            var branches: [(condition: Node, body: [Node])] = []
            var condition = try parseExpressionStatement()
            if keyword == "unless" { condition = .not(condition) }
            _ = accept(keyword: "then")
            branches.append((condition, try parseStatements(until: ["elsif", "else", "end"])))
            var elseBody: [Node]?
            while true {
                if accept(keyword: "elsif") {
                    let condition = try parseExpressionStatement()
                    _ = accept(keyword: "then")
                    branches.append((condition, try parseStatements(until: ["elsif", "else", "end"])))
                } else if accept(keyword: "else") {
                    elseBody = try parseStatements(until: ["end"])
                } else {
                    break
                }
            }
            try expect(keyword: "end")
            return .conditional(branches: branches, elseBody: elseBody)
        case "while", "until":
            let condition = try parseExpressionStatement()
            _ = accept(keyword: "do")
            let body = try parseStatements(until: ["end"])
            try expect(keyword: "end")
            return .whileLoop(condition: condition, body: body, negated: keyword == "until")
        case "case":
            let subject: Node? = currentKind == .newline ? nil : try parseExpressionStatement()
            skipNewlines()
            var whens: [(values: [Node], body: [Node])] = []
            var elseBody: [Node]?
            while accept(keyword: "when") {
                var values = [try parseTernary()]
                while accept(op: ",") { skipNewlines(); values.append(try parseTernary()) }
                _ = accept(keyword: "then")
                whens.append((values, try parseStatements(until: ["when", "else", "end"])))
            }
            if accept(keyword: "else") { elseBody = try parseStatements(until: ["end"]) }
            try expect(keyword: "end")
            return .caseWhen(subject: subject, whens: whens, elseBody: elseBody)
        case "def":
            var name: String
            switch currentKind {
            case .identifier(let n), .constant(let n): name = n
            case .keyword("self"):
                advance(); try expect(op: ".")
                guard case .identifier(let n) = currentKind else { throw error("Expected method name") }
                name = n
            default: throw error("Expected method name after 'def'")
            }
            advance()
            if accept(op: "=") { name += "=" }
            var params: [String] = []
            let parenthesized = accept(op: "(")
            while case .identifier(let p) = currentKind {
                advance(); params.append(p)
                if accept(op: "=") { _ = try parseTernary() } // default values are not supported; ignored
                if !accept(op: ",") { break }
            }
            if parenthesized { try expect(op: ")") }
            locals.append(Set(params))
            defer { locals.removeLast() }
            let body = try parseBodyWithRescue(until: ["end"])
            try expect(keyword: "end")
            return .def(name: name, parameters: params, body: body)
        case "begin":
            let body = try parseBodyWithRescue(until: ["end"])
            try expect(keyword: "end")
            return body.count == 1 ? body[0] : .begin(body: body, rescue: nil, ensure: nil)
        default:
            throw DSLError("Unsupported keyword '\(keyword)'", file: file, line: line)
        }
    }

    /// Parses a body that may contain `rescue` / `ensure` clauses.
    private mutating func parseBodyWithRescue(until terminators: Set<String>) throws(DSLError) -> [Node] {
        let body = try parseStatements(until: terminators.union(["rescue", "ensure"]))
        var rescueBody: [Node]?
        var ensureBody: [Node]?
        if accept(keyword: "rescue") {
            while currentKind != .newline, currentKind != .eof { advance() } // exception classes are ignored
            rescueBody = try parseStatements(until: terminators.union(["ensure"]))
        }
        if accept(keyword: "ensure") {
            ensureBody = try parseStatements(until: terminators)
        }
        if rescueBody == nil, ensureBody == nil { return body }
        return [.begin(body: body, rescue: rescueBody, ensure: ensureBody)]
    }

    private func stringNode(_ parts: [StringPart]) throws(DSLError) -> Node {
        if parts.allSatisfy({ if case .text = $0 { true } else { false } }) {
            return .literal(.string(parts.plainText))
        }
        var result: [InterpolatedPart] = []
        for part in parts {
            switch part {
            case .text(let text): result.append(.text(text))
            case .code(let code, let line):
                result.append(.code(try Parser.parse(code, file: file, line: line, locals: locals.reduce([], { $0.union($1) }))))
            }
        }
        return .string(result)
    }
}
