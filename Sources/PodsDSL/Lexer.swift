import PodsCore

/// A piece of a (possibly interpolated) string literal.
enum StringPart: Equatable {
    case text(String)
    /// Ruby source inside `#{ ... }` and the line it starts on.
    case code(String, line: Int)
}

enum TokenKind: Equatable {
    case identifier(String)
    case constant(String)
    case instanceVariable(String)
    case symbol(String)
    /// `key:` inside a hash or argument list.
    case label(String)
    case string([StringPart])
    /// `%w[...]` / `%i[...]`.
    case words([String], symbols: Bool)
    case integer(Int)
    case float(Double)
    case keyword(String)
    case op(String)
    case newline
    case eof
}

struct Token: Equatable {
    let kind: TokenKind
    let line: Int
    /// Whether whitespace precedes the token. Used to disambiguate command calls (`foo [1]`, `foo -1`).
    let spaceBefore: Bool
}

/// Errors raised while lexing, parsing or evaluating a manifest.
public struct DSLError: Error, CustomStringConvertible, Sendable, Equatable {
    public let message: String
    public let file: String
    public let line: Int

    public init(_ message: String, file: String, line: Int) {
        self.message = message
        self.file = file
        self.line = line
    }

    public var description: String { "\(file):\(line): \(message)" }
}

struct Lexer {
    static let keywords: Set<String> = [
        "do", "end", "if", "elsif", "else", "unless", "then", "def", "true", "false", "nil",
        "and", "or", "not", "return", "self", "case", "when", "begin", "rescue", "ensure", "while", "until",
        "__FILE__", "__dir__",
    ]

    private let chars: [Character]
    private let file: String
    private var index = 0
    private var line: Int
    private var tokens: [Token] = []
    private var pendingHeredocs: [(terminator: String, squiggly: Bool, interpolates: Bool, tokenIndex: Int)] = []
    /// Nesting of `(`, `[`, `{` used to suppress newlines inside brackets.
    private var bracketDepth = 0

    init(_ source: String, file: String, line: Int = 1) {
        self.chars = Array(source)
        self.file = file
        self.line = line
    }

    static func tokenize(_ source: String, file: String, line: Int = 1) throws(DSLError) -> [Token] {
        var lexer = Lexer(source, file: file, line: line)
        return try lexer.run()
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let i = index + offset
        return i < chars.count ? chars[i] : nil
    }

    private func error(_ message: String) -> DSLError { DSLError(message, file: file, line: line) }

    private var previousSignificant: TokenKind? { tokens.last?.kind }

    /// Whether the previous token ends an operand; decides between e.g. `/` division vs. regexp, `[` index vs. array.
    private var previousEndsValue: Bool {
        switch previousSignificant {
        case .identifier, .constant, .instanceVariable, .symbol, .string, .words, .integer, .float: true
        case .keyword(let k): ["end", "self", "true", "false", "nil"].contains(k)
        case .op(let o): [")", "]", "}"].contains(o)
        default: false
        }
    }

    private mutating func add(_ kind: TokenKind, space: Bool) {
        tokens.append(Token(kind: kind, line: line, spaceBefore: space))
    }

    mutating func run() throws(DSLError) -> [Token] {
        var space = true
        while let c = peek() {
            // Line-leading `=begin` ... `=end` block comments.
            if c == "=", isAtLineStart, matches("=begin") {
                while index < chars.count, !(isAtLineStart && matches("=end")) {
                    if chars[index] == "\n" { line += 1 }
                    index += 1
                }
                while let c = peek(), c != "\n" { index += 1 }
                continue
            }
            if c == " " || c == "\t" || c == "\r" {
                index += 1; space = true; continue
            }
            if c == "\\", peek(1) == "\n" {
                index += 2; line += 1; space = true; continue
            }
            if c == "#" {
                while let c = peek(), c != "\n" { index += 1 }
                continue
            }
            if c == "\n" {
                index += 1
                if bracketDepth == 0 { add(.newline, space: space) }
                line += 1
                try consumeHeredocBodies()
                space = true
                continue
            }
            try lexToken(c, space: space)
            space = false
        }
        if !pendingHeredocs.isEmpty { throw error("Unterminated heredoc") }
        add(.newline, space: true)
        add(.eof, space: true)
        return tokens
    }

    private var isAtLineStart: Bool { index == 0 || chars[index - 1] == "\n" }

    private func matches(_ word: String) -> Bool {
        let w = Array(word)
        guard index + w.count <= chars.count else { return false }
        return Array(chars[index..<index + w.count]) == w
    }

    private mutating func lexToken(_ c: Character, space: Bool) throws(DSLError) {
        if c.isNumber {
            lexNumber(space: space)
        } else if c == "@" {
            index += 1
            add(.instanceVariable(readIdentifier()), space: space)
        } else if c == "$" {
            index += 1
            add(.identifier("$" + readIdentifier()), space: space)
        } else if c.isLetter || c == "_" {
            lexWord(space: space)
        } else if c == "\"" || c == "'" || c == "`" {
            index += 1
            add(.string(try readQuoted(terminator: c, interpolates: c != "'")), space: space)
        } else if c == ":" {
            try lexColon(space: space)
        } else if c == "%", !previousEndsValue || (space && peek(1).map { "wWiIqQ([{<".contains($0) } == true && peek(2) != " "),
                  let next = peek(1), "wWiIqQ([{<|!".contains(next) {
            try lexPercentLiteral(space: space)
        } else if c == "<", peek(1) == "<", let heredoc = heredocStart() {
            index += heredoc.length
            pendingHeredocs.append((heredoc.terminator, heredoc.squiggly, heredoc.interpolates, tokens.count))
            add(.string([]), space: space) // body filled in after the line ends
        } else if c == "/", !previousEndsValue || (space && peek(1) != " ") {
            // Regexp literal; kept as a string, the interpreter treats it as a pattern.
            index += 1
            var body = ""
            while let c = peek(), c != "/" {
                if c == "\\", let n = peek(1) { body.append(c); body.append(n); index += 2; continue }
                if c == "\n" { throw error("Unterminated regexp") }
                body.append(c); index += 1
            }
            index += 1
            while let c = peek(), c.isLetter { index += 1 } // flags
            add(.string([.text(body)]), space: space)
        } else {
            try lexOperator(space: space)
        }
    }

    private mutating func lexNumber(space: Bool) {
        var text = ""
        var isFloat = false
        while let c = peek() {
            if c.isNumber || c == "_" {
                if c != "_" { text.append(c) }
                index += 1
            } else if c == ".", !isFloat, let n = peek(1), n.isNumber {
                isFloat = true; text.append(c); index += 1
            } else {
                break
            }
        }
        add(isFloat ? .float(Double(text) ?? 0) : .integer(Int(text) ?? 0), space: space)
    }

    private mutating func readIdentifier() -> String {
        var text = ""
        while let c = peek(), c.isLetter || c.isNumber || c == "_" {
            text.append(c); index += 1
        }
        return text
    }

    private mutating func lexWord(space: Bool) {
        var word = readIdentifier()
        // Method names may end with `?` or `!` (but not `!=`, `?:` ternaries are written with spaces).
        if let c = peek(), c == "?" || c == "!", peek(1) != "=" {
            if c == "!" || (peek(1).map { !$0.isLetter && !$0.isNumber && $0 != ":" && $0 != "'" && $0 != "\"" } ?? true) {
                word.append(c); index += 1
            }
        }
        // `key: value` labels (but not `Foo::Bar`).
        if peek() == ":", peek(1) != ":", !(previousSignificant == .op("?")) {
            let previousIsDot = previousSignificant == .op(".")
            if !previousIsDot, peek(1).map({ $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\"" || $0 == "'" || $0 == "[" || $0 == "{" }) ?? true {
                index += 1
                add(.label(word), space: space)
                return
            }
        }
        if previousSignificant == .op(".") || previousSignificant == .op("&.") {
            add(.identifier(word), space: space) // method names may shadow keywords (`s.end`)
        } else if Self.keywords.contains(word) {
            add(.keyword(word), space: space)
        } else if word.first!.isUppercase {
            add(.constant(word), space: space)
        } else {
            add(.identifier(word), space: space)
        }
    }

    private mutating func lexColon(space: Bool) throws(DSLError) {
        if peek(1) == ":" {
            index += 2
            add(.op("::"), space: space)
        } else if let n = peek(1), n == "\"" || n == "'" {
            index += 2
            let parts = try readQuoted(terminator: n, interpolates: n == "\"")
            add(.symbol(parts.plainText), space: space)
        } else if let n = peek(1), n.isLetter || n == "_" {
            index += 1
            var name = readIdentifier()
            if let c = peek(), c == "?" || c == "!" || c == "=" , peek(1) != "=", peek(1) != ">" {
                name.append(c); index += 1
            }
            add(.symbol(name), space: space)
        } else {
            index += 1
            add(.op(":"), space: space)
        }
    }

    private mutating func lexOperator(space: Bool) throws(DSLError) {
        let three = ["**=", "<=>", "===", "...", "||=", "&&=", "<<="]
        let two = ["=>", "==", "!=", ">=", "<=", "&&", "||", "+=", "-=", "*=", "/=", "<<", "..", "=~", "!~", "->", "&.", "**"]
        for op in three where matches(op) {
            index += 3; add(.op(op), space: space); return
        }
        for op in two where matches(op) {
            index += 2; add(.op(op), space: space); return
        }
        let c = chars[index]
        guard "+-*/%=<>!&|^~?.,;()[]{}".contains(c) else { throw error("Unexpected character '\(c)'") }
        index += 1
        switch c {
        case "(", "[", "{":
            // `{` opens a block or hash; newlines inside blocks are significant.
            if c != "{" { bracketDepth += 1 }
        case ")", "]":
            bracketDepth = max(0, bracketDepth - 1)
        case ";":
            add(.newline, space: space); return
        default:
            break
        }
        add(.op(String(c)), space: space)
    }

    private func heredocStart() -> (terminator: String, squiggly: Bool, interpolates: Bool, length: Int)? {
        var i = index + 2
        var squiggly = false
        if i < chars.count, chars[i] == "~" || chars[i] == "-" { squiggly = chars[i] == "~"; i += 1 }
        var quote: Character?
        if i < chars.count, chars[i] == "'" || chars[i] == "\"" { quote = chars[i]; i += 1 }
        var name = ""
        while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { name.append(chars[i]); i += 1 }
        guard !name.isEmpty, name.allSatisfy({ !$0.isLetter || $0.isUppercase }) || quote != nil || squiggly else { return nil }
        if let quote {
            guard i < chars.count, chars[i] == quote else { return nil }
            i += 1
        }
        // `a << B` (append a constant) is not a heredoc unless a dash/tilde/quote is used.
        if !squiggly, quote == nil, chars[index + 2] != "-", previousEndsValue { return nil }
        return (name, squiggly, quote != "'", i - index)
    }

    private mutating func consumeHeredocBodies() throws(DSLError) {
        let pending = pendingHeredocs
        pendingHeredocs.removeAll()
        for heredoc in pending {
            var lines: [String] = []
            var found = false
            while index < chars.count {
                var current = ""
                while let c = peek(), c != "\n" { current.append(c); index += 1 }
                if index < chars.count { index += 1 }
                line += 1
                if current.trimmingWhitespace() == heredoc.terminator { found = true; break }
                lines.append(current)
            }
            guard found else { throw error("Unterminated heredoc '\(heredoc.terminator)'") }
            if heredoc.squiggly {
                let indent = lines.filter { !$0.trimmingWhitespace().isEmpty }
                    .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
                lines = lines.map { String($0.dropFirst(min(indent, $0.prefix(while: { $0 == " " || $0 == "\t" }).count))) }
            }
            let body = lines.map { $0 + "\n" }.joined()
            let startLine = tokens[heredoc.tokenIndex].line + 1
            let parts: [StringPart] = heredoc.interpolates
                ? try Self.interpolate(body, file: file, line: startLine)
                : [.text(body)]
            let old = tokens[heredoc.tokenIndex]
            tokens[heredoc.tokenIndex] = Token(kind: .string(parts), line: old.line, spaceBefore: old.spaceBefore)
        }
    }

    /// Splits text with `#{}` into parts. Escapes have already been processed by the caller (or are absent).
    static func interpolate(_ text: String, file: String, line: Int) throws(DSLError) -> [StringPart] {
        var lexer = Lexer(text, file: file, line: line)
        var parts: [StringPart] = []
        var current = ""
        while let c = lexer.peek() {
            if c == "#", lexer.peek(1) == "{" {
                if !current.isEmpty { parts.append(.text(current)); current = "" }
                lexer.index += 2
                parts.append(.code(try lexer.readInterpolation(), line: lexer.line))
            } else {
                if c == "\n" { lexer.line += 1 }
                current.append(c); lexer.index += 1
            }
        }
        if !current.isEmpty || parts.isEmpty { parts.append(.text(current)) }
        return parts
    }

    private mutating func readInterpolation() throws(DSLError) -> String {
        var depth = 1
        var code = ""
        while let c = peek() {
            index += 1
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth == 0 { return code } }
            code.append(c)
        }
        throw error("Unterminated string interpolation")
    }

    private mutating func readQuoted(terminator: Character, interpolates: Bool, opener: Character? = nil) throws(DSLError) -> [StringPart] {
        var parts: [StringPart] = []
        var current = ""
        var depth = 0
        let startLine = line
        while true {
            guard let c = peek() else { throw DSLError("Unterminated string", file: file, line: startLine) }
            index += 1
            if let opener, c == opener { depth += 1; current.append(c); continue }
            if c == terminator {
                if depth == 0 { break }
                depth -= 1; current.append(c); continue
            }
            if c == "\n" { line += 1 }
            if c == "\\", let n = peek() {
                index += 1
                if interpolates {
                    switch n {
                    case "n": current.append("\n")
                    case "t": current.append("\t")
                    case "e": current.append("\u{1B}")
                    case "0": current.append("\0")
                    case "\n": line += 1
                    default: current.append(n)
                    }
                } else if n == terminator || n == "\\" {
                    current.append(n)
                } else {
                    current.append(c); current.append(n)
                }
                continue
            }
            if interpolates, c == "#", peek() == "{" {
                if !current.isEmpty { parts.append(.text(current)); current = "" }
                index += 1
                let codeLine = line
                parts.append(.code(try readInterpolation(), line: codeLine))
                continue
            }
            current.append(c)
        }
        if !current.isEmpty || parts.isEmpty { parts.append(.text(current)) }
        return parts
    }

    private mutating func lexPercentLiteral(space: Bool) throws(DSLError) {
        index += 1
        var kind: Character = "Q"
        if let c = peek(), c.isLetter { kind = c; index += 1 }
        guard let open = peek() else { throw error("Unterminated % literal") }
        index += 1
        let close: Character = switch open {
        case "(": ")"
        case "[": "]"
        case "{": "}"
        case "<": ">"
        default: open
        }
        let nestedOpener: Character? = open == close ? nil : open
        let parts = try readQuoted(terminator: close, interpolates: kind == "Q" || kind == "W" || kind == "I", opener: nestedOpener)
        switch kind {
        case "w", "W", "i", "I":
            let words = parts.plainText.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
            add(.words(words, symbols: kind == "i" || kind == "I"), space: space)
        default:
            add(.string(parts), space: space)
        }
    }
}

extension [StringPart] {
    /// The literal text, ignoring interpolations (used for symbols and `%w`).
    var plainText: String {
        map { part in
            switch part {
            case .text(let text): text
            case .code(let code, _): "#{\(code)}"
            }
        }.joined()
    }
}
