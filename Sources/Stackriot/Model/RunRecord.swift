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
    var statusRawValue: String
    var worktreeID: UUID?
    var repository: ManagedRepository?
    var worktree: WorktreeRecord?

    init(
        id: UUID = UUID(),
        actionKind: ActionKind,
        title: String,
        commandLine: String,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        exitCode: Int? = nil,
        outputText: String = "",
        status: RunStatusKind = .pending,
        worktreeID: UUID? = nil,
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
        self.statusRawValue = status.rawValue
        self.worktreeID = worktreeID ?? worktree?.id
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
}
