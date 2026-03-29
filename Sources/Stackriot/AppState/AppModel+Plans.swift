import Foundation
import SwiftData

extension AppModel {

    // MARK: - Plan Tab Selection

    func selectPlanTab(for worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectedWorktreeIDsByRepository[repository.id] = worktree.id
        terminalTabs.selectPlanTab(for: worktree.id)
    }

    func isPlanTabSelected(for worktree: WorktreeRecord) -> Bool {
        terminalTabs.isPlanTabSelected(for: worktree.id)
    }

    // MARK: - Plan File I/O

    func loadPlan(for worktreeID: UUID) -> String {
        let url = AppPaths.planFile(for: worktreeID)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func savePlan(_ text: String, for worktreeID: UUID) {
        let url = AppPaths.planFile(for: worktreeID)
        try? FileManager.default.createDirectory(at: AppPaths.plansDirectory, withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Agent Dispatch with Plan

    func launchAgentWithPlan(_ tool: AIAgentTool, for worktree: WorktreeRecord, in modelContext: ModelContext) {
        let planText = loadPlan(for: worktree.id)
        terminalTabs.deselectPlanTab(for: worktree.id)
        launchAgent(tool, for: worktree, in: modelContext, initialPrompt: planText)
    }
}
