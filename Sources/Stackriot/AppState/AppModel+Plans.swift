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

    func planContentVersion(for worktreeID: UUID) -> Int {
        planContentVersionsByWorktreeID[worktreeID] ?? 0
    }

    func codexPlanDraft(for worktreeID: UUID) -> CodexPlanDraft? {
        codexPlanDraftsByWorktreeID[worktreeID]
    }

    func dismissPresentedCodexPlanDraft() {
        guard let worktreeID = activeCodexPlanDraftWorktreeID else { return }
        if let draft = codexPlanDraftsByWorktreeID[worktreeID], draft.didImportPlan {
            activeCodexPlanDraftWorktreeID = nil
            return
        }
        cancelCodexPlanDraft(for: worktreeID)
    }

    func startCodexPlanDraft(
        for worktree: WorktreeRecord,
        in repository: ManagedRepository,
        currentPlanText: String,
        modelContext _: ModelContext
    ) {
        guard !worktree.isDefaultBranchWorkspace else { return }
        guard availableAgents.contains(.codex) else {
            pendingErrorMessage = "Codex is not available on this machine."
            return
        }

        if let existingDraft = codexPlanDraftsByWorktreeID[worktree.id] {
            if activeRunIDs.contains(existingDraft.runID) {
                activeCodexPlanDraftWorktreeID = worktree.id
                return
            }
            cleanupCodexPlanDraft(for: worktree.id)
        }

        let descriptor = CommandExecutionDescriptor(
            title: "Codex Plan",
            actionKind: .aiAgent,
            showsAgentIndicator: false,
            executable: "codex",
            arguments: [],
            displayCommandLine: "codex",
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            runtimeRequirement: nil,
            stdinText: Self.codexPlanPrompt(for: worktree, currentPlanText: currentPlanText) + "\n",
            environment: [:],
            usesTerminalSession: true,
            outputInterpreter: nil
        )
        let run = startTransientRun(
            descriptor,
            repository: repository,
            worktree: worktree,
            isTransientPlanRun: true
        )
        codexPlanDraftsByWorktreeID[worktree.id] = CodexPlanDraft(
            worktreeID: worktree.id,
            repositoryID: repository.id,
            branchName: worktree.branchName,
            issueContext: worktree.issueContext?.nonEmpty ?? worktree.branchName,
            run: run
        )
        activeCodexPlanDraftWorktreeID = worktree.id
    }

    func sendCodexPlanReply(_ reply: String, for worktreeID: UUID) {
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let draft = codexPlanDraftsByWorktreeID[worktreeID], let session = terminalSessions[draft.runID] else {
            pendingErrorMessage = "The Codex planning session is no longer running."
            return
        }
        guard !trimmedReply.isEmpty else { return }
        session.send(text: trimmedReply + "\n")
    }

    func cancelCodexPlanDraft(for worktreeID: UUID) {
        guard let draft = codexPlanDraftsByWorktreeID[worktreeID] else {
            if activeCodexPlanDraftWorktreeID == worktreeID {
                activeCodexPlanDraftWorktreeID = nil
            }
            return
        }

        activeCodexPlanDraftWorktreeID = nil

        if activeRunIDs.contains(draft.runID) {
            codexPlanDraftsByWorktreeID[worktreeID]?.requestedSessionTermination = true
            if let session = terminalSessions[draft.runID] {
                session.terminate()
                return
            }
        }

        cleanupCodexPlanDraft(for: worktreeID)
    }

    func importCompletedCodexPlanIfAvailable(forRunID runID: UUID) {
        guard let (worktreeID, draft) = codexPlanDraftEntry(forRunID: runID) else { return }
        guard !draft.didImportPlan else { return }
        guard let proposedPlan = Self.extractLatestProposedPlanMarkdown(from: draft.run.outputText) else { return }

        do {
            try writePlan(proposedPlan, for: worktreeID)
            planContentVersionsByWorktreeID[worktreeID, default: 0] += 1
            codexPlanDraftsByWorktreeID[worktreeID]?.didImportPlan = true
            codexPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = nil
            codexPlanDraftsByWorktreeID[worktreeID]?.requestedSessionTermination = true
            if activeCodexPlanDraftWorktreeID == worktreeID {
                activeCodexPlanDraftWorktreeID = nil
            }

            if let session = terminalSessions[runID] {
                session.terminate()
            } else {
                cleanupCodexPlanDraft(for: worktreeID)
            }
        } catch {
            codexPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = error.localizedDescription
            pendingErrorMessage = "Failed to import Codex plan: \(error.localizedDescription)"
        }
    }

    private static let planTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func codexPlanDraftEntry(forRunID runID: UUID) -> (UUID, CodexPlanDraft)? {
        codexPlanDraftsByWorktreeID.first(where: { $0.value.runID == runID })
    }

    func cleanupCodexPlanDraft(for worktreeID: UUID) {
        guard let draft = codexPlanDraftsByWorktreeID.removeValue(forKey: worktreeID) else {
            if activeCodexPlanDraftWorktreeID == worktreeID {
                activeCodexPlanDraftWorktreeID = nil
            }
            return
        }

        if activeCodexPlanDraftWorktreeID == worktreeID {
            activeCodexPlanDraftWorktreeID = nil
        }

        activeRunIDs.remove(draft.runID)
        delegatedAgentRunIDs.remove(draft.runID)
        runningProcesses.removeValue(forKey: draft.runID)
        codexExecOutputParsers.removeValue(forKey: draft.runID)
        forceClosingTerminalRunIDs.remove(draft.runID)
        terminalSessions[draft.runID] = nil
        refreshRunningAgentWorktrees()
    }

    nonisolated static func extractLatestProposedPlanMarkdown(from output: String) -> String? {
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        let openingTag = "<proposed_plan>"
        let closingTag = "</proposed_plan>"
        var searchStart = normalized.startIndex
        var latestMatch: Substring?

        while let openingRange = normalized.range(of: openingTag, range: searchStart..<normalized.endIndex) {
            let contentStart = openingRange.upperBound
            guard let closingRange = normalized.range(of: closingTag, range: contentStart..<normalized.endIndex) else {
                break
            }
            latestMatch = normalized[contentStart..<closingRange.lowerBound]
            searchStart = closingRange.upperBound
        }

        return latestMatch
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(\.nonEmpty)
    }

    private nonisolated static func codexPlanPrompt(for worktree: WorktreeRecord, currentPlanText: String) -> String {
        let issueContext = worktree.issueContext?.nonEmpty ?? worktree.branchName
        var lines = [
            "Help me create or refine an implementation plan for this worktree.",
            "",
            "Worktree branch: \(worktree.branchName)",
            "User description: \(issueContext)",
            "",
            "Ask follow-up questions in this session whenever you need more context.",
            "When you are ready to deliver the final answer, include exactly one <proposed_plan>...</proposed_plan> block that contains only the proposed Markdown plan."
        ]

        if let existingPlan = currentPlanText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            lines.append("")
            lines.append("Current plan draft to refine:")
            lines.append("```md")
            lines.append(existingPlan)
            lines.append("```")
        }

        return lines.joined(separator: "\n")
    }
}
