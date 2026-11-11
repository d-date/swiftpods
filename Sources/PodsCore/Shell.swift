public import Foundation
import Subprocess
import System

/// Runs external commands (git, curl, unzip, ...) asynchronously.
public struct Shell: Sendable {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    public struct Failure: Error, CustomStringConvertible {
        public let command: [String]
        public let output: Output

        public var description: String {
            let detail = output.stderr.isEmpty ? output.stdout : output.stderr
            return "Command `\(command.joined(separator: " "))` failed (\(output.status)):\n\(detail.trimmingWhitespace())"
        }
    }

    /// Upper bound for collected stdout/stderr. `xcodebuild` logs reach tens of megabytes.
    private static let outputLimit = 256 * 1024 * 1024

    public var environment: [String: String]?

    public init(environment: [String: String]? = nil) {
        self.environment = environment
    }

    /// Runs `command` (resolved through `PATH`) and returns its output, throwing on non-zero exit.
    @discardableResult
    public func run(_ command: String, _ arguments: [String], in directory: URL? = nil) async throws -> Output {
        let output = try await execute([command] + arguments, in: directory)
        guard output.status == 0 else { throw Failure(command: [command] + arguments, output: output) }
        return output
    }

    /// Runs a command (the first element, resolved through `PATH`) and returns its output
    /// regardless of exit status.
    public func execute(_ command: [String], in directory: URL? = nil) async throws -> Output {
        guard let executable = command.first else { throw Failure(command: command, output: Output(status: -1, stdout: "", stderr: "empty command")) }
        var updates: [Environment.Key: String?] = [:]
        for (key, value) in environment ?? [:] { updates[Environment.Key(stringLiteral: key)] = value }

        // Subprocess drains stdout and stderr concurrently, so large outputs can't dead-lock the child.
        let result = try await Subprocess.run(
            // Like a shell: names containing "/" are paths, other names are looked up in PATH.
            executable.contains("/") ? .path(FilePath(executable)) : .name(executable),
            arguments: Arguments(Array(command.dropFirst())),
            environment: .inherit.updating(updates),
            workingDirectory: directory.map { FilePath($0.path(percentEncoded: false)) },
            output: .string(limit: Self.outputLimit),
            error: .string(limit: Self.outputLimit)
        )
        let status: Int32 = switch result.terminationStatus {
        case .exited(let code): code
        // Mirror the shell convention for signals (128 + signal number).
        case .signaled(let signal): 128 + signal
        }
        return Output(status: status, stdout: result.standardOutput ?? "", stderr: result.standardError ?? "")
    }
}
