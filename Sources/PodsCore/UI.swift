import Synchronization

/// Thread-safe console reporter used across the installation pipeline.
public final class UI: Sendable {
    public enum Verbosity: Int, Sendable, Comparable {
        case silent, normal, verbose
        public static func < (lhs: Verbosity, rhs: Verbosity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Style: Sendable {
        case plain, title, success, warning, error, detail
    }

    private struct State {
        var indentation = 0
        var warnings: [String] = []
        var lines: [String] = []
    }

    public let verbosity: Verbosity
    public let usesColor: Bool
    /// When `true`, output is captured in memory (used by tests) instead of printed.
    public let captures: Bool
    private let state = Mutex(State())

    public init(verbosity: Verbosity = .normal, usesColor: Bool = false, captures: Bool = false) {
        self.verbosity = verbosity
        self.usesColor = usesColor
        self.captures = captures
    }

    /// A reporter that records everything and prints nothing.
    public static func capturing() -> UI { UI(verbosity: .verbose, captures: true) }

    public func message(_ text: String, style: Style = .plain) {
        guard verbosity >= .normal || style == .error else { return }
        emit(text, style: style)
    }

    public func verbose(_ text: String) {
        guard verbosity >= .verbose else { return }
        emit(text, style: .detail)
    }

    public func warn(_ text: String) {
        state.withLock { $0.warnings.append(text) }
        message("[!] " + text, style: .warning)
    }

    /// Runs `body` with an increased indentation level for nested output.
    public func section<T>(_ title: String, _ body: () async throws -> T) async rethrows -> T {
        message(title, style: .title)
        state.withLock { $0.indentation += 1 }
        defer { state.withLock { $0.indentation -= 1 } }
        return try await body()
    }

    public var warnings: [String] { state.withLock { $0.warnings } }
    public var capturedLines: [String] { state.withLock { $0.lines } }

    private func emit(_ text: String, style: Style) {
        let line = state.withLock { state in
            let line = String(repeating: "  ", count: state.indentation) + text
            if captures { state.lines.append(line) }
            return line
        }
        guard !captures else { return }
        print(usesColor ? colorize(line, style) : line)
    }

    private func colorize(_ text: String, _ style: Style) -> String {
        let code: String? = switch style {
        case .plain: nil
        case .title: "1"
        case .success: "32"
        case .warning: "33"
        case .error: "31"
        case .detail: "2"
        }
        guard let code else { return text }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }
}

/// An error that should be shown to the user without a stack of implementation details.
public struct PodsError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
