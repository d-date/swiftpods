public import Foundation

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

    /// Runs a command and returns its output regardless of exit status.
    public func execute(_ command: [String], in directory: URL? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        if let directory { process.currentDirectoryURL = directory }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Drain the pipes concurrently so that large outputs can't dead-lock the child.
        async let stdoutData = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = Self.readToEnd(stderrPipe.fileHandleForReading)

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                // The child never started: close our write ends so the readers see EOF.
                process.terminationHandler = nil
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
        return Output(
            status: status,
            stdout: String(decoding: await stdoutData, as: UTF8.self),
            stderr: String(decoding: await stderrData, as: UTF8.self)
        )
    }

    @concurrent
    private static func readToEnd(_ handle: FileHandle) async -> Data {
        (try? handle.readToEnd()) ?? Data()
    }
}
