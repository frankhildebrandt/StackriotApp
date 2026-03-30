import Foundation
import SwiftData

@Model
final class AgentRawLogRecord {
    var id: UUID
    var runID: UUID?
    var repositoryID: UUID?
    var worktreeID: UUID?
    var projectID: UUID?
    var projectName: String?
    var repositoryName: String?
    var worktreeBranchName: String?
    var agentToolRawValue: String
    var title: String
    var promptText: String?
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double?
    var logFilePath: String
    var fileSize: Int64
    var statusRawValue: String

    init(
        id: UUID = UUID(),
        runID: UUID? = nil,
        repositoryID: UUID? = nil,
        worktreeID: UUID? = nil,
        projectID: UUID? = nil,
        projectName: String? = nil,
        repositoryName: String? = nil,
        worktreeBranchName: String? = nil,
        agentTool: AIAgentTool,
        title: String,
        promptText: String? = nil,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        durationSeconds: Double? = nil,
        logFilePath: String,
        fileSize: Int64 = 0,
        status: RunStatusKind = .running
    ) {
        self.id = id
        self.runID = runID
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
        self.projectID = projectID
        self.projectName = projectName
        self.repositoryName = repositoryName
        self.worktreeBranchName = worktreeBranchName
        self.agentToolRawValue = agentTool.rawValue
        self.title = title
        self.promptText = promptText
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.logFilePath = logFilePath
        self.fileSize = fileSize
        self.statusRawValue = status.rawValue
    }

    var agentTool: AIAgentTool {
        get { AIAgentTool(rawValue: agentToolRawValue) ?? .none }
        set { agentToolRawValue = newValue.rawValue }
    }

    var status: RunStatusKind {
        get { RunStatusKind(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }

    var logFileURL: URL {
        URL(fileURLWithPath: logFilePath)
    }

    var displayProjectName: String {
        projectName?.nonEmpty ?? "Ohne Projekt"
    }

    var displayRepositoryName: String {
        repositoryName?.nonEmpty ?? "Ohne Repository"
    }

    var displayWorktreeName: String {
        worktreeBranchName?.nonEmpty ?? "Ohne Worktree"
    }
}
