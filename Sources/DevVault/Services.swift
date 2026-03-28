import AppKit
import Darwin
import Foundation

enum DevVaultError: LocalizedError {
    case invalidRemoteURL
    case unsupportedRepositoryPath
    case executableNotFound(String)
    case branchNameRequired
    case worktreeUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRemoteURL:
            "The repository URL is invalid."
        case .unsupportedRepositoryPath:
            "The repository path is missing or invalid."
        case let .executableNotFound(name):
            "\(name) is not installed or cannot be launched."
        case .branchNameRequired:
            "A branch name is required."
        case .worktreeUnavailable:
            "A worktree is required for this action."
        case let .commandFailed(message):
            message
        }
    }
}

enum AppPaths {
    static var applicationSupportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return url.appendingPathComponent("DevVault", isDirectory: true)
    }

    static var bareRepositoriesRoot: URL {
        applicationSupportDirectory.appendingPathComponent("Repositories", isDirectory: true)
    }

    static var worktreesRoot: URL {
        applicationSupportDirectory.appendingPathComponent("Worktrees", isDirectory: true)
    }

    static func ensureBaseDirectories() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bareRepositoriesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
    }

    static func suggestedRepositoryName(from remoteURL: URL) -> String {
        let lastComponent = remoteURL.deletingPathExtension().lastPathComponent
        return lastComponent.isEmpty ? "repository" : lastComponent
    }

    static func sanitizedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let string = String(scalars)
        let normalized = string.replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "item" : normalized.lowercased()
    }

    static func uniqueDirectory(in root: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let base = sanitizedPathComponent(preferredName)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }
}

struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

final class RunningProcess: @unchecked Sendable {
    fileprivate let process: Process
    fileprivate var wasCancelled = false

    init(process: Process) {
        self.process = process
    }

    func cancel() {
        wasCancelled = true
        if process.isRunning {
            process.terminate()
        }
    }
}

enum CommandRunner {
    @discardableResult
    static func start(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        onOutput: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32, Bool) -> Void
    ) throws -> RunningProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = ProcessInfo.processInfo.environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let runningProcess = RunningProcess(process: process)
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
        currentDirectoryURL: URL? = nil
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.environment = ProcessInfo.processInfo.environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
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

struct RepositoryManager {
    func cloneBareRepository(
        remoteURL: URL,
        preferredName: String?
    ) async throws -> ClonedRepositoryInfo {
        try AppPaths.ensureBaseDirectories()

        let displayName = (preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { name in
            name.isEmpty ? nil : name
        } ?? AppPaths.suggestedRepositoryName(from: remoteURL)

        let destination = AppPaths.uniqueDirectory(in: AppPaths.bareRepositoriesRoot, preferredName: displayName)
        let cloneResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["clone", "--bare", remoteURL.absoluteString, destination.path]
        )

        guard cloneResult.exitCode == 0 else {
            throw DevVaultError.commandFailed(cloneResult.stderr.isEmpty ? cloneResult.stdout : cloneResult.stderr)
        }

        let branchResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", destination.path, "symbolic-ref", "--short", "HEAD"]
        )

        let defaultBranch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranch = defaultBranch.isEmpty ? "main" : defaultBranch

        return ClonedRepositoryInfo(
            displayName: displayName,
            remoteURL: remoteURL,
            bareRepositoryPath: destination,
            defaultBranch: resolvedBranch
        )
    }

    func refreshStatus(for repositoryPath: URL) -> RepositoryHealth {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: repositoryPath.path) else {
            return .missing
        }

        let head = repositoryPath.appendingPathComponent("HEAD")
        return fileManager.fileExists(atPath: head.path) ? .ready : .broken
    }
}

struct WorktreeManager {
    func createWorktree(
        bareRepositoryPath: URL,
        repositoryName: String,
        branchName: String,
        sourceBranch: String
    ) async throws -> CreatedWorktreeInfo {
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else {
            throw DevVaultError.branchNameRequired
        }

        try AppPaths.ensureBaseDirectories()
        let worktreeRoot = AppPaths.worktreesRoot.appendingPathComponent(
            AppPaths.sanitizedPathComponent(repositoryName),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)

        let destination = AppPaths.uniqueDirectory(in: worktreeRoot, preferredName: trimmedBranch)
        let branchExists = try await branchExistsInRepository(trimmedBranch, bareRepositoryPath: bareRepositoryPath)

        let arguments: [String]
        if branchExists {
            arguments = ["--git-dir", bareRepositoryPath.path, "worktree", "add", destination.path, trimmedBranch]
        } else {
            arguments = ["--git-dir", bareRepositoryPath.path, "worktree", "add", "-b", trimmedBranch, destination.path, sourceBranch]
        }

        let result = try await CommandRunner.runCollected(executable: "git", arguments: arguments)
        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return CreatedWorktreeInfo(branchName: trimmedBranch, path: destination)
    }

    func removeWorktree(bareRepositoryPath: URL, worktreePath: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "worktree", "remove", "--force", worktreePath.path]
        )

        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func branchExistsInRepository(_ branchName: String, bareRepositoryPath: URL) async throws -> Bool {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"]
        )
        return result.exitCode == 0
    }
}

struct IDEManager {
    func open(_ ide: SupportedIDE, path: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "open",
            arguments: ["-a", ide.applicationName, path.path]
        )

        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}

@MainActor
final class AIAgentManager {
    private(set) var activeSessions: [UUID: AgentSessionState] = [:]
    var onSessionsChanged: (([UUID: AgentSessionState]) -> Void)?

    func checkAvailability() async -> Set<AIAgentTool> {
        var available: Set<AIAgentTool> = []

        await withTaskGroup(of: AIAgentTool?.self) { group in
            for tool in AIAgentTool.allCases where tool != .none {
                guard let executable = tool.executableName else { continue }
                group.addTask {
                    do {
                        let result = try await CommandRunner.runCollected(executable: "which", arguments: [executable])
                        return result.exitCode == 0 ? tool : nil
                    } catch {
                        return nil
                    }
                }
            }

            for await maybeTool in group {
                if let tool = maybeTool {
                    available.insert(tool)
                }
            }
        }

        return available
    }

    @discardableResult
    func launchAgent(_ tool: AIAgentTool, for worktree: WorktreeRecord) throws -> AgentSessionState {
        guard tool != .none else {
            throw DevVaultError.commandFailed("No AI agent is assigned for this worktree.")
        }

        let pidFile = "/tmp/dv_agent_\(worktree.id.uuidString).pid"
        try? FileManager.default.removeItem(atPath: pidFile)

        let command = "echo $$ > \(pidFile.shellEscaped); \(tool.launchCommand(in: worktree.path))"
        let appleScript = """
        tell application \"Terminal\"
            activate
            do script \"\(command.appleScriptEscaped)\"
        end tell
        """

        guard let script = NSAppleScript(source: appleScript) else {
            throw DevVaultError.commandFailed("Could not prepare AppleScript for Terminal launch.")
        }

        var scriptError: NSDictionary?
        script.executeAndReturnError(&scriptError)
        if let scriptError {
            let message = scriptError[NSAppleScript.errorMessage] as? String ?? "Terminal launch failed."
            throw DevVaultError.commandFailed(message)
        }

        let pid = try waitForPID(at: pidFile)
        let state = AgentSessionState(
            worktreeID: worktree.id,
            tool: tool,
            pid: pid,
            startedAt: .now,
            phase: .running
        )
        activeSessions[worktree.id] = state
        onSessionsChanged?(activeSessions)

        startPolling(pid: pid, worktreeID: worktree.id)
        return state
    }

    func isAgentRunning(for worktreeID: UUID) -> Bool {
        if let session = activeSessions[worktreeID], case .running = session.phase {
            return true
        }

        return false
    }

    func isAgentRunning(forAnyWorktreeIn repository: ManagedRepository) -> Bool {
        repository.worktrees.contains { isAgentRunning(for: $0.id) }
    }

    private func waitForPID(at path: String) throws -> pid_t {
        for _ in 0..<20 {
            if
                let raw = try? String(contentsOfFile: path),
                let pidValue = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                pidValue > 0
            {
                try? FileManager.default.removeItem(atPath: path)
                return pidValue
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        throw DevVaultError.commandFailed("Agent launch timed out while waiting for PID.")
    }

    private func startPolling(pid: pid_t, worktreeID: UUID) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(2))

                await MainActor.run {
                    guard let self else { return }
                    let processIsAlive = kill(pid, 0) == 0 || errno == EPERM
                    if !processIsAlive {
                        self.activeSessions.removeValue(forKey: worktreeID)
                        self.onSessionsChanged?(self.activeSessions)
                    }
                }

                let shouldContinue = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.activeSessions[worktreeID] != nil
                }

                if !shouldContinue {
                    return
                }
            }
        }
    }
}

struct NodeToolingService {
    func discoverScripts(in worktreeURL: URL) -> [String] {
        let packageURL = worktreeURL.appendingPathComponent("package.json")
        guard
            let data = try? Data(contentsOf: packageURL),
            let package = try? JSONDecoder().decode(PackageManifest.self, from: data)
        else {
            return []
        }

        return package.scripts.keys.sorted()
    }

    func installDescriptor(
        for worktree: WorktreeRecord,
        mode: DependencyInstallMode,
        repositoryID: UUID
    ) -> CommandExecutionDescriptor {
        let worktreeURL = URL(fileURLWithPath: worktree.path)
        let executable: String
        let arguments: [String]

        if FileManager.default.fileExists(atPath: worktreeURL.appendingPathComponent("pnpm-lock.yaml").path) {
            executable = "pnpm"
            arguments = [mode == .install ? "install" : "update"]
        } else if FileManager.default.fileExists(atPath: worktreeURL.appendingPathComponent("yarn.lock").path) {
            executable = "yarn"
            arguments = [mode == .install ? "install" : "upgrade"]
        } else {
            executable = "npm"
            arguments = [mode == .install ? "install" : "update"]
        }

        return CommandExecutionDescriptor(
            title: "\(mode.displayName) dependencies",
            actionKind: .installDependencies,
            executable: executable,
            arguments: arguments,
            currentDirectoryURL: worktreeURL,
            repositoryID: repositoryID,
            worktreeID: worktree.id
        )
    }

    private struct PackageManifest: Decodable {
        let scripts: [String: String]
    }
}

struct MakeToolingService {
    func discoverTargets(in worktreeURL: URL) -> [String] {
        let candidateFiles = ["Makefile", "makefile", "GNUmakefile"]
        for fileName in candidateFiles {
            let fileURL = worktreeURL.appendingPathComponent(fileName)
            guard let contents = try? String(contentsOf: fileURL) else {
                continue
            }

            return Self.parseTargets(from: contents)
        }

        return []
    }

    static func parseTargets(from contents: String) -> [String] {
        let lines = contents.split(separator: "\n")
        let targets = lines.compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard
                !text.hasPrefix("."),
                !text.hasPrefix("#"),
                let colonIndex = text.firstIndex(of: ":")
            else {
                return nil
            }

            let target = String(text[..<colonIndex])
            guard
                !target.contains("="),
                !target.contains("%"),
                !target.contains(" "),
                target != "default"
            else {
                return nil
            }

            return target
        }

        return Array(Set(targets)).sorted()
    }
}
