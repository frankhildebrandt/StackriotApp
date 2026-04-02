import Foundation

struct WorktreeStatusRefreshSnapshot: Sendable {
    let repositoryID: UUID
    let generation: Int
    let githubRepositoryTarget: String?
    let materializedWorktreeIDs: Set<UUID>
    let statusItems: [WorktreeStatusRefreshItem]
    let pullRequestItems: [PullRequestStatusRefreshItem]
}

struct WorktreeStatusRefreshItem: Sendable {
    let worktreeID: UUID
    let worktreePath: String
    let compareBranch: String
}

struct PullRequestStatusRefreshItem: Sendable {
    let worktreeID: UUID
    let prNumber: Int
    let storedHeadSHA: String?
    let worktreePath: String?
}

struct WorktreeStatusRefreshResult: Sendable {
    let repositoryID: UUID
    let generation: Int
    let materializedWorktreeIDs: Set<UUID>
    let statuses: [UUID: WorktreeStatus]
    let pullRequestStatuses: [UUID: PullRequestUpstreamStatus]
}
