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
}
