import AppKit
import Darwin
import Foundation
import SwiftData
@MainActor
final class AIAgentManager {
    private(set) var activeSessions: [UUID: AgentSessionState] = [:]
    var onSessionsChanged: (([UUID: AgentSessionState]) -> Void)?
    private let localToolManager: LocalToolManager

    init(localToolManager: LocalToolManager = LocalToolManager()) {
        self.localToolManager = localToolManager
    }

    func checkAvailability() async -> Set<AIAgentTool> {
        await localToolManager.availableAgentTools()
    }

    @discardableResult
    func launchAgent(_ tool: AIAgentTool, for worktree: WorktreeRecord) throws -> AgentSessionState {
        guard tool != .none else {
            throw StackriotError.commandFailed("No AI agent is assigned for this worktree.")
        }

        let pidFile = "/tmp/stackriot_agent_\(worktree.id.uuidString).pid"
        try? FileManager.default.removeItem(atPath: pidFile)

        let command = "echo $$ > \(pidFile.shellEscaped); \(tool.launchCommand(in: worktree.path))"
        let appleScript = """
        tell application \"Terminal\"
            activate
            if (count of windows) is 0 then
                do script \"\(command.appleScriptEscaped)\"
            else
                do script \"\(command.appleScriptEscaped)\" in front window
            end if
        end tell
        """

        guard let script = NSAppleScript(source: appleScript) else {
            throw StackriotError.commandFailed("Could not prepare AppleScript for Terminal launch.")
        }

        var scriptError: NSDictionary?
        script.executeAndReturnError(&scriptError)
        if let scriptError {
            let message = scriptError[NSAppleScript.errorMessage] as? String ?? "Terminal launch failed."
            throw StackriotError.commandFailed(message)
        }

        let pid = try waitForPID(at: pidFile)
        let sessionID = UUID()
        let state = AgentSessionState(
            id: sessionID,
            worktreeID: worktree.id,
            tool: tool,
            pid: pid,
            startedAt: .now,
            phase: .running
        )
        activeSessions[sessionID] = state
        onSessionsChanged?(activeSessions)

        startPolling(pid: pid, sessionID: sessionID)
        return state
    }

    func isAgentRunning(for worktreeID: UUID) -> Bool {
        activeSessions.values.contains { session in
            session.worktreeID == worktreeID && {
                if case .running = session.phase {
                    return true
                }
                return false
            }()
        }
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

        throw StackriotError.commandFailed("Agent launch timed out while waiting for PID.")
    }

    private func startPolling(pid: pid_t, sessionID: UUID) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(2))

                await MainActor.run {
                    guard let self else { return }
                    let processIsAlive = kill(pid, 0) == 0 || errno == EPERM
                    if !processIsAlive {
                        self.activeSessions.removeValue(forKey: sessionID)
                        self.onSessionsChanged?(self.activeSessions)
                    }
                }

                let shouldContinue = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return self.activeSessions[sessionID] != nil
                }

                if !shouldContinue {
                    return
                }
            }
        }
    }
}
