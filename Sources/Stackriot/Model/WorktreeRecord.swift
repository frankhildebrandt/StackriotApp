import Foundation
import SwiftData

@Model
final class WorktreeRecord {
    var id: UUID
    var branchName: String
    var isDefaultBranchWorkspaceRaw: Bool?
    var isPinnedRaw: Bool?
    var cardColorRaw: String?
    var issueContext: String?
    var ticketProviderRaw: String?
    var ticketIdentifier: String?
    var ticketURL: String?
    var path: String
    @Transient var assignedAgentRawValue: String = AIAgentTool.none.rawValue
    var createdAt: Date
    var lastOpenedAt: Date?
    var repository: ManagedRepository?

    // Primary context
    var primaryContextKindRaw: String?
    var primaryContextURL: String?
    var primaryContextTitle: String?
    var primaryContextLabel: String?
    var primaryContextProviderRaw: String?
    var primaryContextPRNumber: Int?
    var primaryContextTicketID: String?
    var primaryContextUpstreamRef: String?
    var primaryContextUpstreamSHA: String?

    // Integration / PR tracking
    var prNumber: Int?
    var prURL: String?
    var lifecycleStateRaw: String?
    var deleteOnMerge: Bool?

    init(
        id: UUID = UUID(),
        branchName: String,
        isDefaultBranchWorkspace: Bool = false,
        isPinned: Bool = false,
        cardColor: WorktreeCardColor = .none,
        issueContext: String? = nil,
        ticketProvider: TicketProviderKind? = nil,
        ticketIdentifier: String? = nil,
        ticketURL: String? = nil,
        path: String,
        assignedAgentRawValue: String = AIAgentTool.none.rawValue,
        createdAt: Date = .now,
        lastOpenedAt: Date? = nil,
        repository: ManagedRepository? = nil,
        primaryContext: WorktreePrimaryContext? = nil,
        prNumber: Int? = nil,
        prURL: String? = nil,
        lifecycleStateRaw: String? = nil,
        deleteOnMerge: Bool? = nil
    ) {
        self.id = id
        self.branchName = branchName
        self.isDefaultBranchWorkspaceRaw = isDefaultBranchWorkspace ? true : nil
        self.isPinnedRaw = isPinned ? true : nil
        self.cardColorRaw = cardColor == .none ? nil : cardColor.rawValue
        self.issueContext = issueContext
        self.ticketProviderRaw = ticketProvider?.rawValue
        self.ticketIdentifier = ticketIdentifier
        self.ticketURL = ticketURL
        self.path = path
        self.assignedAgentRawValue = assignedAgentRawValue
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.repository = repository
        self.prNumber = prNumber
        self.prURL = prURL
        self.lifecycleStateRaw = lifecycleStateRaw
        self.deleteOnMerge = deleteOnMerge
        self.primaryContext = primaryContext
    }

    var assignedAgent: AIAgentTool {
        get { AIAgentTool(rawValue: assignedAgentRawValue) ?? .none }
        set { assignedAgentRawValue = newValue.rawValue }
    }

    var isDefaultBranchWorkspace: Bool {
        get { isDefaultBranchWorkspaceRaw ?? false }
        set { isDefaultBranchWorkspaceRaw = newValue }
    }

    var isPinned: Bool {
        get { isPinnedRaw ?? false }
        set { isPinnedRaw = newValue }
    }

    var cardColor: WorktreeCardColor {
        get { WorktreeCardColor(rawValue: cardColorRaw ?? WorktreeCardColor.none.rawValue) ?? .none }
        set { cardColorRaw = newValue == .none ? nil : newValue.rawValue }
    }

    var ticketProvider: TicketProviderKind? {
        get { ticketProviderRaw.flatMap(TicketProviderKind.init(rawValue:)) }
        set { ticketProviderRaw = newValue?.rawValue }
    }

    var primaryContextProvider: TicketProviderKind? {
        get { primaryContextProviderRaw.flatMap(TicketProviderKind.init(rawValue:)) }
        set { primaryContextProviderRaw = newValue?.rawValue }
    }

    var primaryContextKind: WorktreePrimaryContextKind? {
        get { primaryContextKindRaw.flatMap(WorktreePrimaryContextKind.init(rawValue:)) }
        set { primaryContextKindRaw = newValue?.rawValue }
    }

    var primaryContext: WorktreePrimaryContext? {
        get {
            guard let url = primaryContextURL?.nilIfBlank,
                  let kind = primaryContextKind,
                  let provider = primaryContextProvider
            else {
                return nil
            }
            return WorktreePrimaryContext(
                kind: kind,
                canonicalURL: url,
                title: primaryContextTitle?.nilIfBlank ?? issueContext?.nilIfBlank ?? branchName,
                label: primaryContextLabel?.nilIfBlank ?? kind.defaultLabel(for: provider),
                provider: provider,
                prNumber: primaryContextPRNumber,
                ticketID: primaryContextTicketID?.nilIfBlank,
                upstreamReference: primaryContextUpstreamRef?.nilIfBlank,
                upstreamSHA: primaryContextUpstreamSHA?.nilIfBlank
            )
        }
        set {
            primaryContextKindRaw = newValue?.kind.rawValue
            primaryContextURL = newValue?.canonicalURL
            primaryContextTitle = newValue?.title
            primaryContextLabel = newValue?.label
            primaryContextProviderRaw = newValue?.provider.rawValue
            primaryContextPRNumber = newValue?.prNumber
            primaryContextTicketID = newValue?.ticketID
            primaryContextUpstreamRef = newValue?.upstreamReference
            primaryContextUpstreamSHA = newValue?.upstreamSHA
        }
    }

    var resolvedPrimaryContext: WorktreePrimaryContext? {
        primaryContext ?? legacyPrimaryContext
    }

    var lifecycleState: WorktreeLifecycle {
        get { WorktreeLifecycle(rawValue: lifecycleStateRaw ?? WorktreeLifecycle.active.rawValue) ?? .active }
        set { lifecycleStateRaw = newValue.rawValue }
    }

    var allowsSyncFromDefaultBranch: Bool {
        lifecycleState == .active || lifecycleState == .merged
    }

    var shouldDeleteOnMerge: Bool {
        get { deleteOnMerge ?? false }
        set { deleteOnMerge = newValue }
    }

    var primaryContextTabKind: WorktreePrimaryContextTabKind {
        if isDefaultBranchWorkspace {
            return .readme
        }
        return resolvedPrimaryContext == nil ? .plan : .browser
    }

    var primaryContextTabTitle: String {
        switch primaryContextTabKind {
        case .readme:
            "README"
        case .plan:
            "Plan"
        case .browser:
            resolvedPrimaryContext?.label ?? "Primary Context"
        }
    }

    var primaryContextTabSystemImage: String {
        switch primaryContextTabKind {
        case .readme:
            "book.closed"
        case .plan:
            "doc.text"
        case .browser:
            switch resolvedPrimaryContext?.kind {
            case .pullRequest:
                "arrow.triangle.merge"
            case .ticket:
                if resolvedPrimaryContext?.provider == .jira {
                    "link"
                } else {
                    "number.square"
                }
            case nil:
                "globe"
            }
        }
    }

    @discardableResult
    func migratePrimaryContextFromLegacyFieldsIfNeeded() -> Bool {
        guard primaryContext == nil, let legacyPrimaryContext else { return false }
        primaryContext = legacyPrimaryContext
        return true
    }

    private var legacyPrimaryContext: WorktreePrimaryContext? {
        if let prURL = prURL?.nilIfBlank, let prNumber {
            return WorktreePrimaryContext(
                kind: .pullRequest,
                canonicalURL: prURL,
                title: issueContext?.nilIfBlank ?? "Pull Request #\(prNumber)",
                label: "PR",
                provider: .github,
                prNumber: prNumber,
                ticketID: nil,
                upstreamReference: nil,
                upstreamSHA: nil
            )
        }

        if let ticketURL = ticketURL?.nilIfBlank, let provider = ticketProvider {
            return WorktreePrimaryContext(
                kind: .ticket,
                canonicalURL: ticketURL,
                title: issueContext?.nilIfBlank ?? branchName,
                label: provider.ticketLabel,
                provider: provider,
                prNumber: nil,
                ticketID: ticketIdentifier?.nilIfBlank,
                upstreamReference: nil,
                upstreamSHA: nil
            )
        }

        return nil
    }
}
