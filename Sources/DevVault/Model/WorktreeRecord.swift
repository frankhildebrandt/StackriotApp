import Foundation
import SwiftData

@Model
final class WorktreeRecord {
    var id: UUID
    var branchName: String
    var isDefaultBranchWorkspaceRaw: Bool?
    var issueContext: String?
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
        issueContext: String? = nil,
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
        self.isDefaultBranchWorkspaceRaw = isDefaultBranchWorkspace
        self.issueContext = issueContext
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

    var lifecycleState: WorktreeLifecycle {
        get { WorktreeLifecycle(rawValue: lifecycleStateRaw ?? WorktreeLifecycle.active.rawValue) ?? .active }
        set { lifecycleStateRaw = newValue.rawValue }
    }

    var shouldDeleteOnMerge: Bool {
        get { deleteOnMerge ?? false }
        set { deleteOnMerge = newValue }
    }
}
