import Foundation
import SwiftData

@Model
final class ManagedRepository {
    var id: UUID
    var displayName: String
    var remoteURL: String?
    var bareRepositoryPath: String
    var defaultBranch: String
    var defaultRemoteName: String?
    var createdAt: Date
    var updatedAt: Date
    var lastFetchedAt: Date?
    var statusRawValue: String
    var lastErrorMessage: String?
    var namespace: RepositoryNamespace?
    var project: RepositoryProject?
    var documentationProject: RepositoryProject?
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
        defaultRemoteName: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastFetchedAt: Date? = nil,
        status: RepositoryHealth = .ready,
        lastErrorMessage: String? = nil,
        namespace: RepositoryNamespace? = nil,
        project: RepositoryProject? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.remoteURL = remoteURL
        self.bareRepositoryPath = bareRepositoryPath
        self.defaultBranch = defaultBranch
        self.defaultRemoteName = defaultRemoteName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastFetchedAt = lastFetchedAt
        self.statusRawValue = status.rawValue
        self.lastErrorMessage = lastErrorMessage
        self.namespace = namespace
        self.project = project
        self.documentationProject = nil
        self.remotes = []
        self.worktrees = []
        self.actionTemplates = []
        self.runs = []
    }

    var status: RepositoryHealth {
        get { RepositoryHealth(rawValue: statusRawValue) ?? .broken }
        set { statusRawValue = newValue.rawValue }
    }

    var defaultRemote: RepositoryRemote? {
        if let defaultRemoteName {
            return remotes.first(where: { $0.name == defaultRemoteName })
        }

        return remotes.sorted {
            if $0.name == "origin" { return true }
            if $1.name == "origin" { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.first
    }

    var primaryRemote: RepositoryRemote? {
        defaultRemote
    }

    var isDocumentationRepository: Bool {
        documentationProject != nil
    }

    func childWorktrees(of parent: WorktreeRecord) -> [WorktreeRecord] {
        worktrees.filter { $0.parentWorktreeID == parent.id }
    }

    func parentWorktree(of child: WorktreeRecord) -> WorktreeRecord? {
        guard let parentID = child.parentWorktreeID else { return nil }
        return worktrees.first(where: { $0.id == parentID })
    }
}
