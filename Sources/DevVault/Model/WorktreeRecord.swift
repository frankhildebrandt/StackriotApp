import Foundation
import SwiftData

@Model
final class WorktreeRecord {
    var id: UUID
    var branchName: String
    var isDefaultBranchWorkspace: Bool
    var issueContext: String?
    var path: String
    @Transient var assignedAgentRawValue: String = AIAgentTool.none.rawValue
    var createdAt: Date
    var lastOpenedAt: Date?
    var repository: ManagedRepository?

    init(
        id: UUID = UUID(),
        branchName: String,
        isDefaultBranchWorkspace: Bool = false,
        issueContext: String? = nil,
        path: String,
        assignedAgentRawValue: String = AIAgentTool.none.rawValue,
        createdAt: Date = .now,
        lastOpenedAt: Date? = nil,
        repository: ManagedRepository? = nil
    ) {
        self.id = id
        self.branchName = branchName
        self.isDefaultBranchWorkspace = isDefaultBranchWorkspace
        self.issueContext = issueContext
        self.path = path
        self.assignedAgentRawValue = assignedAgentRawValue
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.repository = repository
    }

    var assignedAgent: AIAgentTool {
        get { AIAgentTool(rawValue: assignedAgentRawValue) ?? .none }
        set { assignedAgentRawValue = newValue.rawValue }
    }
}
