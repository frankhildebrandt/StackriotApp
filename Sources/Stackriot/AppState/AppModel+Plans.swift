import Foundation
import SwiftData

extension AppModel {
    struct CodexPlanResponse: Decodable, Equatable {
        enum Status: String, Decodable {
            case needsUserInput = "needs_user_input"
            case ready = "ready"
        }

        var status: Status
        var summary: String?
        var questions: [String]?
        var planMarkdown: String?

        enum CodingKeys: String, CodingKey {
            case status
            case summary
            case questions
            case planMarkdown = "plan_markdown"
        }
    }

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

        let artifactURLs: (schema: URL, response: URL)
        do {
            artifactURLs = try Self.prepareCodexPlanArtifactURLs(for: worktree.id)
        } catch {
            pendingErrorMessage = "Failed to prepare Codex plan artifacts: \(error.localizedDescription)"
            return
        }

        let descriptor = CommandExecutionDescriptor(
            title: "Codex Plan",
            actionKind: .aiAgent,
            showsAgentIndicator: false,
            executable: "codex",
            arguments: [
                "exec",
                "--full-auto",
                "--json",
                "--color", "never",
                "--output-schema", artifactURLs.schema.path,
                "--output-last-message", artifactURLs.response.path,
                Self.codexPlanPrompt(for: worktree, currentPlanText: currentPlanText),
            ],
            displayCommandLine: "codex exec --full-auto --json --color never --output-schema \(artifactURLs.schema.path.shellEscaped) --output-last-message \(artifactURLs.response.path.shellEscaped) <prompt>",
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            runtimeRequirement: nil,
            stdinText: nil,
            environment: [:],
            usesTerminalSession: false,
            outputInterpreter: .codexExecJSONL
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
            run: run,
            responseFilePath: artifactURLs.response.path,
            schemaFilePath: artifactURLs.schema.path
        )
        activeCodexPlanDraftWorktreeID = worktree.id
    }

    func sendCodexPlanReply(_ reply: String, for worktreeID: UUID) {
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else { return }
        guard let draft = codexPlanDraftsByWorktreeID[worktreeID] else {
            pendingErrorMessage = "The Codex planning session is no longer available."
            return
        }
        guard !activeRunIDs.contains(draft.runID) else {
            pendingErrorMessage = "Codex is still processing the current planning turn."
            return
        }
        guard let sessionID = draft.sessionID?.nonEmpty else {
            pendingErrorMessage = "The Codex planning session cannot be resumed because no session ID was captured."
            return
        }
        guard let repository = repositoryRecord(with: draft.repositoryID),
              let worktree = worktreeRecord(with: worktreeID) else {
            pendingErrorMessage = StackriotError.worktreeUnavailable.localizedDescription
            return
        }
        guard let responseFilePath = draft.responseFilePath?.nonEmpty else {
            pendingErrorMessage = "Missing Codex response file for this planning session."
            return
        }

        let descriptor = CommandExecutionDescriptor(
            title: "Codex Plan",
            actionKind: .aiAgent,
            showsAgentIndicator: false,
            executable: "codex",
            arguments: [
                "exec",
                "resume",
                "--full-auto",
                "--json",
                "--output-last-message", responseFilePath,
                sessionID,
                Self.codexPlanFollowUpPrompt(reply: trimmedReply),
            ],
            displayCommandLine: "codex exec resume --full-auto --json --output-last-message \(responseFilePath.shellEscaped) \(sessionID) <reply>",
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            runtimeRequirement: nil,
            stdinText: nil,
            environment: [:],
            usesTerminalSession: false,
            outputInterpreter: .codexExecJSONL
        )
        let run = startTransientRun(
            descriptor,
            repository: repository,
            worktree: worktree,
            isTransientPlanRun: true
        )
        codexPlanDraftsByWorktreeID[worktreeID]?.run = run
        codexPlanDraftsByWorktreeID[worktreeID]?.latestQuestions = []
        codexPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = nil
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
            runningProcesses[draft.runID]?.cancel()
            return
        }

        cleanupCodexPlanDraft(for: worktreeID)
    }

    func importCompletedCodexPlanIfAvailable(forRunID runID: UUID) {
        guard let (worktreeID, draft) = codexPlanDraftEntry(forRunID: runID) else { return }
        guard !draft.didImportPlan else { return }
        syncCodexPlanSessionID(forRunID: runID)

        guard !activeRunIDs.contains(runID) else { return }
        if let response = Self.readCodexPlanResponse(from: draft.responseFilePath) {
            codexPlanDraftsByWorktreeID[worktreeID]?.latestSummary = response.summary?.nonEmpty
            switch response.status {
            case .needsUserInput:
                codexPlanDraftsByWorktreeID[worktreeID]?.latestQuestions = response.questions?
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .compactMap(\.nonEmpty) ?? []
                codexPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = nil
            case .ready:
                guard let proposedPlan = response.planMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
                    codexPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = "Codex reported a completed plan turn but did not return `plan_markdown`."
                    pendingErrorMessage = "Failed to import Codex plan: missing plan_markdown in the final response."
                    return
                }
                importCodexPlan(proposedPlan, for: worktreeID, runID: runID)
            }
            return
        }

        guard let proposedPlan = Self.extractLatestProposedPlanMarkdown(from: draft.run.outputText) else { return }
        importCodexPlan(proposedPlan, for: worktreeID, runID: runID)
    }

    private func importCodexPlan(_ proposedPlan: String, for worktreeID: UUID, runID: UUID) {
        do {
            try writePlan(proposedPlan, for: worktreeID)
            planContentVersionsByWorktreeID[worktreeID, default: 0] += 1
            codexPlanDraftsByWorktreeID[worktreeID]?.didImportPlan = true
            codexPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = nil
            codexPlanDraftsByWorktreeID[worktreeID]?.latestQuestions = []
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

    func syncCodexPlanSessionID(forRunID runID: UUID) {
        guard let (worktreeID, _) = codexPlanDraftEntry(forRunID: runID),
              let parser = structuredOutputParsersByRunID[runID] as? CodexExecJSONLParser,
              let sessionID = parser.currentThreadID?.nonEmpty else {
            return
        }
        codexPlanDraftsByWorktreeID[worktreeID]?.sessionID = sessionID
    }

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

        Self.removeCodexPlanArtifacts(for: draft)

        if activeCodexPlanDraftWorktreeID == worktreeID {
            activeCodexPlanDraftWorktreeID = nil
        }

        activeRunIDs.remove(draft.runID)
        delegatedAgentRunIDs.remove(draft.runID)
        runningProcesses.removeValue(forKey: draft.runID)
        structuredOutputParsersByRunID.removeValue(forKey: draft.runID)
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
            "Inspect the codebase before deciding on the plan.",
            "If you need more context from the user, do not produce the plan yet. Return only a structured response with status `needs_user_input`, a short summary, and 1-4 concrete questions.",
            "If you have enough information, return only a structured response with status `ready`, a short summary, and `plan_markdown` containing the final Markdown plan that should replace the plan page.",
            "Never wrap the final response in Markdown fences."
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

    private nonisolated static func codexPlanFollowUpPrompt(reply: String) -> String {
        [
            "The user answered the follow-up questions below.",
            "Continue working in the same repository context.",
            "If you still need more information, return only a structured response with status `needs_user_input`, a short summary, and 1-4 concrete questions.",
            "If you are ready, return only a structured response with status `ready`, a short summary, and `plan_markdown` containing the final Markdown plan that should replace the plan page.",
            "Never wrap the final response in Markdown fences.",
            "",
            "User reply:",
            reply,
        ].joined(separator: "\n")
    }

    nonisolated static func parseCodexPlanResponse(from text: String) -> CodexPlanResponse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let response = try? JSONDecoder().decode(CodexPlanResponse.self, from: data) else {
            return nil
        }
        return validatedCodexPlanResponse(response)
    }

    private nonisolated static func validatedCodexPlanResponse(_ response: CodexPlanResponse) -> CodexPlanResponse? {
        guard response.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil else {
            return nil
        }

        switch response.status {
        case .needsUserInput:
            guard let questions = response.questions?
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .compactMap(\.nonEmpty),
                (1...4).contains(questions.count) else {
                return nil
            }
        case .ready:
            guard response.planMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil else {
                return nil
            }
        }

        return response
    }

    private nonisolated static func readCodexPlanResponse(from path: String?) -> CodexPlanResponse? {
        guard let path = path?.nonEmpty else { return nil }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parseCodexPlanResponse(from: text)
    }

    private nonisolated static func prepareCodexPlanArtifactURLs(for worktreeID: UUID) throws -> (schema: URL, response: URL) {
        let fileManager = FileManager.default
        let directory = AppPaths.codexPlanArtifactsDirectory(for: worktreeID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let schemaURL = directory.appendingPathComponent("response-schema.json", isDirectory: false)
        let responseURL = directory.appendingPathComponent("last-response.json", isDirectory: false)
        try codexPlanResponseSchemaJSON().write(to: schemaURL, atomically: true, encoding: .utf8)
        if fileManager.fileExists(atPath: responseURL.path) {
            try? fileManager.removeItem(at: responseURL)
        }

        return (schemaURL, responseURL)
    }

    private nonisolated static func removeCodexPlanArtifacts(for draft: CodexPlanDraft) {
        let directory = AppPaths.codexPlanArtifactsDirectory(for: draft.worktreeID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private nonisolated static func codexPlanResponseSchemaJSON() -> String {
        """
        {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "status": {
              "type": "string",
              "enum": ["needs_user_input", "ready"]
            },
            "summary": {
              "type": ["string", "null"]
            },
            "questions": {
              "type": ["array", "null"],
              "items": {
                "type": "string"
              },
              "minItems": 1,
              "maxItems": 4
            },
            "plan_markdown": {
              "type": ["string", "null"]
            }
          },
          "required": ["status", "summary", "questions", "plan_markdown"]
        }
        """
    }
}
