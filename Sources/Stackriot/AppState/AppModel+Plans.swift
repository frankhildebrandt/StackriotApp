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

    func writePlan(_ text: String, for worktreeID: UUID) throws {
        let url = AppPaths.planFile(for: worktreeID)
        try FileManager.default.createDirectory(at: AppPaths.plansDirectory, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func savePlan(_ text: String, for worktreeID: UUID) {
        do {
            try writePlan(text, for: worktreeID)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func initialPlan(from issue: GitHubIssueDetails) -> String {
        let labels = issue.labels.isEmpty ? "_none_" : issue.labels.joined(separator: ", ")
        var lines = [
            "# \(issue.title)",
            "",
            "- Issue: #\(issue.number)",
            "- URL: \(issue.url)",
            "- Labels: \(labels)",
            "",
            "## Beschreibung",
            issue.body.nilIfBlank ?? "Keine Beschreibung.",
            "",
            "## Kommentare",
        ]

        if issue.comments.isEmpty {
            lines.append("Keine Kommentare.")
            return lines.joined(separator: "\n")
        }

        for comment in issue.comments.sorted(by: { $0.createdAt < $1.createdAt }) {
            lines.append("")
            lines.append("### \(comment.author) - \(Self.planTimestampFormatter.string(from: comment.createdAt))")
            lines.append(comment.body.nilIfBlank ?? "_Kein Kommentartext._")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Agent Dispatch with Plan

    func launchAgentWithPlan(_ tool: AIAgentTool, for worktree: WorktreeRecord, in modelContext: ModelContext) {
        let planText = loadPlan(for: worktree.id)
        terminalTabs.deselectPlanTab(for: worktree.id)
        launchAgent(tool, for: worktree, in: modelContext, initialPrompt: planText)
    }

    private static let planTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
