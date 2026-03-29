import Foundation
struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

final class RunningProcess: @unchecked Sendable {
    fileprivate let process: Process
    private let stdinPipe: Pipe
    fileprivate var wasCancelled = false

    init(process: Process, stdinPipe: Pipe) {
        self.process = process
        self.stdinPipe = stdinPipe
    }

    func cancel() {
        wasCancelled = true
        if process.isRunning {
            process.terminate()
        }
    }

    func send(_ input: String) {
        guard process.isRunning, let data = input.data(using: .utf8) else { return }
        stdinPipe.fileHandleForWriting.write(data)
    }
}

enum CommandRunner {
    @discardableResult
    static func start(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        onOutput: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32, Bool) -> Void
    ) throws -> RunningProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdinPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let runningProcess = RunningProcess(process: process, stdinPipe: stdinPipe)
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let string = String(data: data, encoding: .utf8) else {
                return
            }

            onOutput(string)
        }

        process.terminationHandler = { proc in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let remainder = outputPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainder.isEmpty, let string = String(data: remainder, encoding: .utf8) {
                onOutput(string)
            }

            onTermination(proc.terminationStatus, runningProcess.wasCancelled)
        }

        try process.run()
        return runningProcess
    }

    static func runCollected(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:]
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
