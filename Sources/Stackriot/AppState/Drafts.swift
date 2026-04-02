import Foundation

struct CloneRepositoryDraft {
    var remoteURLString = ""
    var displayName = ""
}

enum WorktreeCreationMode: String, CaseIterable, Identifiable {
    case ideaTree
    case fullWorktree

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ideaTree:
            "IdeaTree"
        case .fullWorktree:
            "Worktree"
        }
    }

    var formDescription: String {
        switch self {
        case .ideaTree:
            "Speichert zuerst nur Intent, Ticket-Kontext und Zielpfad. Die Arbeitskopie wird erst bei Bedarf materialisiert."
        case .fullWorktree:
            "Legt sofort einen echten Git-Worktree im Dateisystem an und speichert denselben Kontext direkt am Worktree."
        }
    }

    var sheetTitle: String {
        switch self {
        case .ideaTree:
            "Create IdeaTree"
        case .fullWorktree:
            "Create Worktree"
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .ideaTree:
            "Create IdeaTree"
        case .fullWorktree:
            "Create Worktree"
        }
    }

    var progressTitle: String {
        switch self {
        case .ideaTree:
            "IdeaTree wird erstellt…"
        case .fullWorktree:
            "Worktree wird erstellt…"
        }
    }
}

struct WorktreeDraft {
    var creationMode: WorktreeCreationMode = .ideaTree
    var branchName = ""
    var issueContext = ""
    var sourceBranch = ""
    var destinationRootPath: String?
    var ticketSearchText = ""
    var selectedTicket: TicketSearchResult?
    var selectedIssueDetails: TicketDetails?
    var isTicketLoading = false
    var ticketSearchResults: [TicketSearchResult] = []
    var ticketProvider: TicketProviderKind?
    var ticketProviderStatuses: [TicketProviderStatus] = []
    var hasConfirmedTicket = false
    var isGeneratingSuggestedName = false

    init(sourceBranch: String = "", creationMode: WorktreeCreationMode = .ideaTree) {
        self.creationMode = creationMode
        self.sourceBranch = sourceBranch
    }

    var normalizedBranchName: String {
        WorktreeManager.normalizedWorktreeName(from: branchName)
    }

    var destinationRootURL: URL? {
        guard let destinationRootPath = destinationRootPath?.nilIfBlank else { return nil }
        return URL(fileURLWithPath: destinationRootPath, isDirectory: true)
    }

    var availableTicketProviders: [TicketProviderKind] {
        ticketProviderStatuses.filter(\.isAvailable).map(\.provider)
    }

    var selectedTicketProviderStatus: TicketProviderStatus? {
        guard let ticketProvider else { return ticketProviderStatuses.first }
        return ticketProviderStatuses.first(where: { $0.provider == ticketProvider }) ?? ticketProviderStatuses.first
    }

    var ticketProviderStatus: TicketProviderStatus? {
        get { selectedTicketProviderStatus }
        set { ticketProviderStatuses = newValue.map { [$0] } ?? [] }
    }
}


struct PullRequestCheckoutDraft {
    var repositoryID: UUID?
    var searchText = ""
    var searchResults: [PullRequestSearchResult] = []
    var selectedPullRequest: PullRequestDetails?
    var destinationRootPath: String?
    var isLoading = false

    init(repositoryID: UUID? = nil) {
        self.repositoryID = repositoryID
    }

    var normalizedBranchName: String {
        guard let selectedPullRequest else { return "" }
        return WorktreeManager.normalizedPullRequestBranchName(
            number: selectedPullRequest.number,
            title: selectedPullRequest.title
        )
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

struct QuickIntentSession: Identifiable {
    let id: UUID
    var source: QuickIntentCaptureSource
    var sourceLabel: String
    var text: String
    var branchName: String
    var summaryTitle: String
    var useCurrentWorktreeAsParent: Bool
    var accessibilityAvailable: Bool
    var accessibilityHint: String?
    var isSummarizing = false
    var isPerformingAction = false

    init(
        id: UUID = UUID(),
        source: QuickIntentCaptureSource,
        sourceLabel: String,
        text: String,
        branchName: String = "",
        summaryTitle: String = "",
        useCurrentWorktreeAsParent: Bool = false,
        accessibilityAvailable: Bool = true,
        accessibilityHint: String? = nil
    ) {
        self.id = id
        self.source = source
        self.sourceLabel = sourceLabel
        self.text = text
        self.branchName = branchName
        self.summaryTitle = summaryTitle
        self.useCurrentWorktreeAsParent = useCurrentWorktreeAsParent
        self.accessibilityAvailable = accessibilityAvailable
        self.accessibilityHint = accessibilityHint
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
    enum Presentation {
        case foreground
        case background
    }

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
    var presentation: Presentation = .foreground

    var id: UUID { worktreeID }
    var runID: UUID { run.id }
}

enum PendingCopilotDraftPurpose {
    case execution
    case planning

    var title: String {
        switch self {
        case .execution:
            "Execute with GitHub Copilot"
        case .planning:
            "Create Plan with GitHub Copilot"
        }
    }

    var backgroundTitle: String {
        switch self {
        case .execution:
            "Send to Background with GitHub Copilot"
        case .planning:
            "Create Plan with GitHub Copilot"
        }
    }
}

struct PendingAgentExecutionDraft: Identifiable {
    let purpose: PendingCopilotDraftPurpose
    let tool: AIAgentTool
    let worktreeID: UUID
    let repositoryID: UUID
    let promptSourceTitle: String
    let promptText: String
    let activatesTerminalTab: Bool
    var availableCopilotModels: [CopilotModelOption]
    var selectedCopilotModelID: String
    var isLoadingCopilotModels = false
    var modelDiscoveryErrorMessage: String?

    var id: UUID { worktreeID }
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
