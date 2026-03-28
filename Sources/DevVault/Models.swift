import Foundation
import SwiftData

@Model
final class ManagedRepository {
    var id: UUID
    var displayName: String
    var remoteURL: String
    var bareRepositoryPath: String
    var defaultBranch: String
    var createdAt: Date
    var updatedAt: Date
    var statusRawValue: String
    var lastErrorMessage: String?
    @Relationship(deleteRule: .cascade, inverse: \WorktreeRecord.repository)
    var worktrees: [WorktreeRecord]
    @Relationship(deleteRule: .cascade, inverse: \ActionTemplateRecord.repository)
    var actionTemplates: [ActionTemplateRecord]
    @Relationship(deleteRule: .cascade, inverse: \RunRecord.repository)
    var runs: [RunRecord]

    init(
        id: UUID = UUID(),
        displayName: String,
        remoteURL: String,
        bareRepositoryPath: String,
        defaultBranch: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        status: RepositoryHealth = .ready,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.remoteURL = remoteURL
        self.bareRepositoryPath = bareRepositoryPath
        self.defaultBranch = defaultBranch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.statusRawValue = status.rawValue
        self.lastErrorMessage = lastErrorMessage
        self.worktrees = []
        self.actionTemplates = []
        self.runs = []
    }

    var status: RepositoryHealth {
        get { RepositoryHealth(rawValue: statusRawValue) ?? .broken }
        set { statusRawValue = newValue.rawValue }
    }
}

@Model
final class WorktreeRecord {
    var id: UUID
    var branchName: String
    var issueContext: String?
    var path: String
    var createdAt: Date
    var lastOpenedAt: Date?
    var repository: ManagedRepository?

    init(
        id: UUID = UUID(),
        branchName: String,
        issueContext: String? = nil,
        path: String,
        createdAt: Date = .now,
        lastOpenedAt: Date? = nil,
        repository: ManagedRepository? = nil
    ) {
        self.id = id
        self.branchName = branchName
        self.issueContext = issueContext
        self.path = path
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.repository = repository
    }
}

@Model
final class ActionTemplateRecord {
    var id: UUID
    var kindRawValue: String
    var title: String
    var payload: String?
    var createdAt: Date
    var repository: ManagedRepository?

    init(
        id: UUID = UUID(),
        kind: ActionKind,
        title: String,
        payload: String? = nil,
        createdAt: Date = .now,
        repository: ManagedRepository? = nil
    ) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.title = title
        self.payload = payload
        self.createdAt = createdAt
        self.repository = repository
    }

    var kind: ActionKind {
        get { ActionKind(rawValue: kindRawValue) ?? .openIDE }
        set { kindRawValue = newValue.rawValue }
    }
}

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
