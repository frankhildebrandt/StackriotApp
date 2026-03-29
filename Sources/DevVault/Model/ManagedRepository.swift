import Foundation
import SwiftData

@Model
final class ManagedRepository {
    var id: UUID
    var displayName: String
    var remoteURL: String?
    var bareRepositoryPath: String
    var defaultBranch: String
    var createdAt: Date
    var updatedAt: Date
    var lastFetchedAt: Date?
    var statusRawValue: String
    var lastErrorMessage: String?
    @Relationship(deleteRule: .cascade, inverse: \RepositoryRemote.repository)
    var remotes: [RepositoryRemote]
    @Relationship(deleteRule: .cascade, inverse: \WorktreeRecord.repository)
    var worktrees: [WorktreeRecord]
    @Relationship(deleteRule: .cascade, inverse: \ActionTemplateRecord.repository)
    var actionTemplates: [ActionTemplateRecord]
    @Relationship(deleteRule: .cascade, inverse: \RunRecord.repository)
    var runs: [RunRecord]

    init(
        id: UUID = UUID(),
        displayName: String,
        remoteURL: String? = nil,
        bareRepositoryPath: String,
        defaultBranch: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastFetchedAt: Date? = nil,
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
        self.lastFetchedAt = lastFetchedAt
        self.statusRawValue = status.rawValue
        self.lastErrorMessage = lastErrorMessage
        self.remotes = []
        self.worktrees = []
        self.actionTemplates = []
        self.runs = []
    }

    var status: RepositoryHealth {
        get { RepositoryHealth(rawValue: statusRawValue) ?? .broken }
        set { statusRawValue = newValue.rawValue }
    }

    var primaryRemote: RepositoryRemote? {
        remotes.sorted {
            if $0.name == "origin" { return true }
            if $1.name == "origin" { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.first
    }
}
