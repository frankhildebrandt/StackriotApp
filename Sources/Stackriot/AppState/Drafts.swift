import Foundation

struct CloneRepositoryDraft {
    var remoteURLString = ""
    var displayName = ""
}

struct WorktreeDraft {
    var branchName = ""
    var issueContext = ""
    var sourceBranch = ""
    var ticketSearchText = ""
    var selectedTicket: GitHubIssueSearchResult?
    var selectedIssueDetails: GitHubIssueDetails?
    var isTicketLoading = false
    var ticketSearchResults: [GitHubIssueSearchResult] = []
    var ticketProvider: TicketProviderKind?
    var ticketProviderStatus: TicketProviderStatus?
    var hasConfirmedTicket = false
    var isGeneratingSuggestedName = false

    init(sourceBranch: String = "") {
        self.sourceBranch = sourceBranch
    }

    var normalizedBranchName: String {
        WorktreeManager.normalizedWorktreeName(from: branchName)
    }
}

struct PublishBranchDraft {
    var repositoryID: UUID?
    var worktreeID: UUID?
    var remoteName = ""
}

struct IntegrationDraft {
    enum Method: String, CaseIterable, Hashable {
        case localMerge
        case githubPR

        var displayName: String {
            switch self {
            case .localMerge: "Lokal mergen"
            case .githubPR: "GitHub PR"
            }
        }
    }

    var method: Method = .localMerge
    var deleteAfterIntegration: Bool = true
    var prTitle: String = ""
    var prBody: String = ""

    init(
        method: Method = .localMerge,
        deleteAfterIntegration: Bool = true,
        prTitle: String = "",
        prBody: String = ""
    ) {
        self.method = method
        self.deleteAfterIntegration = deleteAfterIntegration
        self.prTitle = prTitle
        self.prBody = prBody
    }
}

enum NameEditorMode {
    case create
    case rename
}

struct NamespaceEditorDraft: Identifiable {
    var id = UUID()
    var mode: NameEditorMode = .create
    var namespaceID: UUID?
    var name = ""
}

struct ProjectEditorDraft: Identifiable {
    var id = UUID()
    var mode: NameEditorMode = .create
    var namespaceID: UUID?
    var projectID: UUID?
    var name = ""
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
