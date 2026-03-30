import Foundation

struct CloneRepositoryDraft {
    var remoteURLString = ""
    var displayName = ""
}

struct WorktreeDraft {
    var branchName = ""
    var issueContext = ""
    var sourceBranch = ""
    var destinationRootPath: String?
    var ticketSearchText = ""
    var selectedTicket: GitHubIssueSearchResult?
    var selectedIssueDetails: GitHubIssueDetails?
    var isTicketLoading = false
    var ticketSearchResults: [GitHubIssueSearchResult] = []
    var ticketProvider: TicketProviderKind?
    var ticketProviderStatus: TicketProviderStatus?
    var hasConfirmedTicket = false
    var isGeneratingSuggestedName = false
    var isTicketSectionExpanded = false

    init(sourceBranch: String = "") {
        self.sourceBranch = sourceBranch
    }

    var normalizedBranchName: String {
        WorktreeManager.normalizedWorktreeName(from: branchName)
    }

    var destinationRootURL: URL? {
        guard let destinationRootPath = destinationRootPath?.nilIfBlank else { return nil }
        return URL(fileURLWithPath: destinationRootPath, isDirectory: true)
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

struct AgentPlanDraft: Identifiable {
    let tool: AIAgentTool
    let worktreeID: UUID
    let repositoryID: UUID
    let branchName: String
    let issueContext: String
    var run: RunRecord
    var sessionID: String?
    var latestSummary: String?
    var latestQuestions: [String] = []
    var responseFilePath: String?
    var schemaFilePath: String?
    var didImportPlan = false
    var importErrorMessage: String?
    var requestedSessionTermination = false

    var id: UUID { worktreeID }
    var runID: UUID { run.id }
}

struct RunFixRequest {
    let tool: AIAgentTool
    let sourceRunID: UUID
    let runConfigurationID: String
    let worktreeID: UUID
    let runTitle: String
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
