import Foundation
import SwiftData

@Model
final class RunRecord {
    var id: UUID
    var actionKindRawValue: String
    var title: String
    var commandLine: String
    var startedAt: Date
    var endedAt: Date?
    var exitCode: Int?
    var outputText: String
    var outputInterpreterRawValue: String?
    var aiSummaryTitle: String?
    var aiSummaryText: String?
    var statusRawValue: String
    var worktreeID: UUID?
    var repositoryID: UUID?
    var runConfigurationID: String?
    var repository: ManagedRepository?
    var worktree: WorktreeRecord?
    @Transient var isTransientPlanRun = false

    init(
        id: UUID = UUID(),
        actionKind: ActionKind,
        title: String,
        commandLine: String,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        exitCode: Int? = nil,
        outputText: String = "",
        outputInterpreter: RunOutputInterpreterKind? = nil,
        aiSummaryTitle: String? = nil,
        aiSummaryText: String? = nil,
        status: RunStatusKind = .pending,
        worktreeID: UUID? = nil,
        repositoryID: UUID? = nil,
        runConfigurationID: String? = nil,
        repository: ManagedRepository? = nil,
        worktree: WorktreeRecord? = nil
    ) {
        self.id = id
        self.actionKindRawValue = actionKind.rawValue
        self.title = title
        self.commandLine = commandLine
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.outputText = outputText
        self.outputInterpreterRawValue = outputInterpreter?.rawValue
        self.aiSummaryTitle = aiSummaryTitle
        self.aiSummaryText = aiSummaryText
        self.statusRawValue = status.rawValue
        self.worktreeID = worktreeID ?? worktree?.id
        self.repositoryID = repositoryID ?? repository?.id
        self.runConfigurationID = runConfigurationID
        self.repository = repository
        self.worktree = worktree
    }

    var actionKind: ActionKind {
        get { ActionKind(rawValue: actionKindRawValue) ?? .makeTarget }
        set { actionKindRawValue = newValue.rawValue }
    }

    var status: RunStatusKind {
        get { RunStatusKind(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }

    var outputInterpreter: RunOutputInterpreterKind? {
        get { outputInterpreterRawValue.flatMap(RunOutputInterpreterKind.init(rawValue:)) }
        set { outputInterpreterRawValue = newValue?.rawValue }
    }

    var isFixableBuildFailure: Bool {
        status == .failed && runConfigurationID?.nonEmpty != nil && worktreeID != nil
    }
}
