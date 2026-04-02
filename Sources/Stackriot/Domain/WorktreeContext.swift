import Foundation

enum WorktreePrimaryContextKind: String, Codable, Sendable {
    case pullRequest
    case ticket

    func defaultLabel(for provider: TicketProviderKind) -> String {
        switch self {
        case .pullRequest:
            "PR"
        case .ticket:
            provider.ticketLabel
        }
    }

    func returnButtonTitle(for provider: TicketProviderKind) -> String {
        switch self {
        case .pullRequest:
            "Return to PR"
        case .ticket:
            provider == .github ? "Return to Issue" : "Return to Ticket"
        }
    }
}

enum WorktreePrimaryContextTabKind: String, Codable, Sendable {
    case readme
    case plan
    case browser
}

/// Which primary pane is shown when the terminal column is in “primary context” mode (not a run tab).
enum WorktreePrimaryPaneKind: String, Codable, Sendable, Hashable {
    case intent
    case implementationPlan
    case browser
    case devContainerLogs
}

struct WorktreePrimaryContext: Sendable, Equatable {
    let kind: WorktreePrimaryContextKind
    let canonicalURL: String
    let title: String
    let label: String
    let provider: TicketProviderKind
    let prNumber: Int?
    let ticketID: String?
    let upstreamReference: String?
    let upstreamSHA: String?

    var returnButtonTitle: String {
        kind.returnButtonTitle(for: provider)
    }
}

struct PullRequestSearchResult: Identifiable, Sendable, Equatable {
    let number: Int
    let title: String
    let url: String
    let headRefName: String
    let headRefOID: String
    let baseRefName: String
    let status: String
    let isDraft: Bool
    let isCrossRepository: Bool
    let headRepositoryOwner: String?

    var id: Int { number }
}

struct PullRequestDetails: Sendable, Equatable {
    let number: Int
    let title: String
    let url: String
    let headRefName: String
    let headRefOID: String
    let baseRefName: String
    let status: GitHubCLIService.PRStatus
    let isDraft: Bool
    let isCrossRepository: Bool
    let headRepositoryOwner: String?
}

struct PullRequestUpstreamStatus: Sendable, Equatable {
    let state: GitHubCLIService.PRStatus
    let remoteHeadSHA: String
    let localHeadSHA: String?
    let storedHeadSHA: String?
    let errorMessage: String?

    var hasRemoteUpdate: Bool {
        guard let localHeadSHA else { return true }
        return localHeadSHA != remoteHeadSHA
    }
}

struct WorktreeDiscoverySnapshot: Sendable, Equatable {
    let worktreeID: UUID
    let workspacePath: String?
    var configuration: DevContainerConfiguration?
    var availableDevTools: [SupportedDevTool]?
    var lastUpdatedAt: Date

    var hasDevContainerConfiguration: Bool {
        configuration != nil
    }
}

struct RepositorySidebarSnapshot: Sendable, Equatable {
    let repositoryID: UUID
    let isRefreshing: Bool
    let isAgentRunning: Bool
    let activeDevContainerCount: Int
}
