import Foundation
import SwiftData

extension AppModel {
    struct AgentPlanResponse: Decodable, Equatable {
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

    func initialPlan(from ticket: TicketDetails) -> String {
        let labels = ticket.labels.isEmpty ? "_none_" : ticket.labels.joined(separator: ", ")
        let ticketLineLabel = ticket.provider == .github ? "Issue" : "Ticket"
        var lines = [
            "# \(ticket.title)",
            "",
            "- Provider: \(ticket.provider.displayName)",
            "- \(ticketLineLabel): \(ticket.reference.displayID)",
            "- URL: \(ticket.url)",
            "- Labels: \(labels)",
            "",
            "## Beschreibung",
            ticket.body.nilIfBlank ?? "Keine Beschreibung.",
            "",
            "## Kommentare",
        ]

        if ticket.comments.isEmpty {
            lines.append("Keine Kommentare.")
            return lines.joined(separator: "\n")
        }

        for comment in ticket.comments.sorted(by: { $0.createdAt < $1.createdAt }) {
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

    func availablePlanningAgents() -> [AIAgentTool] {
        AIAgentTool.allCases.filter { tool in
            tool != .none && tool.supportsPlanning && availableAgents.contains(tool)
        }
    }

    func agentPlanDraft(for worktreeID: UUID) -> AgentPlanDraft? {
        agentPlanDraftsByWorktreeID[worktreeID]
    }

    func dismissPresentedAgentPlanDraft() {
        guard let worktreeID = activeAgentPlanDraftWorktreeID else { return }
        if let draft = agentPlanDraftsByWorktreeID[worktreeID], draft.didImportPlan {
            activeAgentPlanDraftWorktreeID = nil
            return
        }
        cancelAgentPlanDraft(for: worktreeID)
    }

    func startAgentPlanDraft(
        using tool: AIAgentTool,
        for worktree: WorktreeRecord,
        in repository: ManagedRepository,
        currentPlanText: String,
        modelContext _: ModelContext
    ) {
        guard !worktree.isDefaultBranchWorkspace else { return }
        guard tool.supportsPlanning else {
            pendingErrorMessage = "\(tool.displayName) does not support interactive planning in Stackriot yet."
            return
        }
        guard availableAgents.contains(tool) else {
            pendingErrorMessage = "\(tool.displayName) is not available on this machine."
            return
        }

        if let existingDraft = agentPlanDraftsByWorktreeID[worktree.id] {
            if activeRunIDs.contains(existingDraft.runID) {
                activeAgentPlanDraftWorktreeID = worktree.id
                return
            }
            cleanupAgentPlanDraft(for: worktree.id)
        }

        let artifactURLs: (schema: URL, response: URL)
        do {
            artifactURLs = try Self.prepareAgentPlanArtifactURLs(for: tool, worktreeID: worktree.id)
        } catch {
            pendingErrorMessage = "Failed to prepare \(tool.displayName) plan artifacts: \(error.localizedDescription)"
            return
        }

        guard let descriptor = Self.makePlanDraftDescriptor(
            for: tool,
            worktree: worktree,
            repositoryID: repository.id,
            currentPlanText: currentPlanText,
            artifactURLs: artifactURLs
        ) else {
            pendingErrorMessage = "\(tool.displayName) planning is not configured."
            return
        }

        let run = startTransientRun(
            descriptor,
            repository: repository,
            worktree: worktree,
            isTransientPlanRun: true
        )
        agentPlanDraftsByWorktreeID[worktree.id] = AgentPlanDraft(
            tool: tool,
            worktreeID: worktree.id,
            repositoryID: repository.id,
            branchName: worktree.branchName,
            issueContext: worktree.issueContext?.nonEmpty ?? worktree.branchName,
            run: run,
            responseFilePath: artifactURLs.response.path,
            schemaFilePath: artifactURLs.schema.path
        )
        activeAgentPlanDraftWorktreeID = worktree.id
    }

    func sendAgentPlanReply(_ reply: String, for worktreeID: UUID) {
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else { return }
        guard let draft = agentPlanDraftsByWorktreeID[worktreeID] else {
            pendingErrorMessage = "The planning session is no longer available."
            return
        }
        guard draft.tool.supportsPlanResume else {
            pendingErrorMessage = "\(draft.tool.displayName) follow-up planning is not enabled in this Stackriot version."
            return
        }
        guard !activeRunIDs.contains(draft.runID) else {
            pendingErrorMessage = "\(draft.tool.displayName) is still processing the current planning turn."
            return
        }
        guard let sessionID = draft.sessionID?.nonEmpty else {
            pendingErrorMessage = "The \(draft.tool.displayName) planning session cannot be resumed because no session ID was captured."
            return
        }
        guard let repository = repositoryRecord(with: draft.repositoryID),
              let worktree = worktreeRecord(with: worktreeID) else {
            pendingErrorMessage = StackriotError.worktreeUnavailable.localizedDescription
            return
        }
        guard let descriptor = Self.makePlanReplyDescriptor(
            for: draft.tool,
            repositoryID: repository.id,
            worktree: worktree,
            responseFilePath: draft.responseFilePath,
            sessionID: sessionID,
            reply: trimmedReply
        ) else {
            pendingErrorMessage = "\(draft.tool.displayName) could not prepare the follow-up planning command."
            return
        }

        let run = startTransientRun(
            descriptor,
            repository: repository,
            worktree: worktree,
            isTransientPlanRun: true
        )
        agentPlanDraftsByWorktreeID[worktreeID]?.run = run
        agentPlanDraftsByWorktreeID[worktreeID]?.latestQuestions = []
        agentPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = nil
    }

    func cancelAgentPlanDraft(for worktreeID: UUID) {
        guard let draft = agentPlanDraftsByWorktreeID[worktreeID] else {
            if activeAgentPlanDraftWorktreeID == worktreeID {
                activeAgentPlanDraftWorktreeID = nil
            }
            return
        }

        activeAgentPlanDraftWorktreeID = nil

        if activeRunIDs.contains(draft.runID) {
            agentPlanDraftsByWorktreeID[worktreeID]?.requestedSessionTermination = true
            if let session = terminalSessions[draft.runID] {
                session.terminate()
                return
            }
            runningProcesses[draft.runID]?.cancel()
            return
        }

        cleanupAgentPlanDraft(for: worktreeID)
    }

    func importCompletedAgentPlanIfAvailable(forRunID runID: UUID) {
        guard let (worktreeID, draft) = agentPlanDraftEntry(forRunID: runID) else { return }
        guard !draft.didImportPlan else { return }
        syncAgentPlanSessionID(forRunID: runID)

        guard !activeRunIDs.contains(runID) else { return }
        if let response = Self.readAgentPlanResponse(from: draft.responseFilePath) ?? structuredAgentPlanResponse(forRunID: runID, tool: draft.tool) {
            agentPlanDraftsByWorktreeID[worktreeID]?.latestSummary = response.summary?.nonEmpty
            switch response.status {
            case .needsUserInput:
                agentPlanDraftsByWorktreeID[worktreeID]?.latestQuestions = response.questions?
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .compactMap(\.nonEmpty) ?? []
                agentPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = nil
            case .ready:
                guard let proposedPlan = response.planMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
                    agentPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = "\(draft.tool.displayName) reported a completed plan turn but did not return `plan_markdown`."
                    pendingErrorMessage = "Failed to import \(draft.tool.displayName) plan: missing plan_markdown in the final response."
                    return
                }
                importAgentPlan(proposedPlan, for: worktreeID, runID: runID, tool: draft.tool)
            }
            return
        }

        guard let proposedPlan = Self.extractLatestProposedPlanMarkdown(from: draft.run.outputText) else { return }
        importAgentPlan(proposedPlan, for: worktreeID, runID: runID, tool: draft.tool)
    }

    func syncAgentPlanSessionID(forRunID runID: UUID) {
        guard let (worktreeID, draft) = agentPlanDraftEntry(forRunID: runID) else { return }
        guard let parser = structuredOutputParsersByRunID[runID] else { return }

        let sessionID: String?
        switch draft.tool {
        case .codex:
            sessionID = (parser as? CodexExecJSONLParser)?.currentThreadID?.nonEmpty
        case .cursorCLI:
            sessionID = (parser as? CursorAgentPrintJSONParser)?.currentSessionID?.nonEmpty
        default:
            sessionID = nil
        }

        if let sessionID {
            agentPlanDraftsByWorktreeID[worktreeID]?.sessionID = sessionID
        }

        guard draft.tool == .cursorCLI,
              let responseText = (parser as? CursorAgentPrintJSONParser)?.latestResultText?.nonEmpty,
              let responseFilePath = draft.responseFilePath?.nonEmpty
        else {
            return
        }

        do {
            try responseText.write(toFile: responseFilePath, atomically: true, encoding: .utf8)
            agentPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = nil
        } catch {
            agentPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = error.localizedDescription
            pendingErrorMessage = "Failed to persist \(draft.tool.displayName) planning response: \(error.localizedDescription)"
        }
    }

    func agentPlanDraftEntry(forRunID runID: UUID) -> (UUID, AgentPlanDraft)? {
        agentPlanDraftsByWorktreeID.first(where: { $0.value.runID == runID })
    }

    func cleanupAgentPlanDraft(for worktreeID: UUID) {
        guard let draft = agentPlanDraftsByWorktreeID.removeValue(forKey: worktreeID) else {
            if activeAgentPlanDraftWorktreeID == worktreeID {
                activeAgentPlanDraftWorktreeID = nil
            }
            return
        }

        Self.removeAgentPlanArtifacts(for: draft)

        if activeAgentPlanDraftWorktreeID == worktreeID {
            activeAgentPlanDraftWorktreeID = nil
        }

        activeRunIDs.remove(draft.runID)
        delegatedAgentRunIDs.remove(draft.runID)
        runningProcesses.removeValue(forKey: draft.runID)
        structuredOutputParsersByRunID.removeValue(forKey: draft.runID)
        forceClosingTerminalRunIDs.remove(draft.runID)
        terminalSessions[draft.runID] = nil
        refreshRunningAgentWorktrees()
    }

    private func structuredAgentPlanResponse(forRunID runID: UUID, tool: AIAgentTool) -> AgentPlanResponse? {
        guard let parser = structuredOutputParsersByRunID[runID] else { return nil }
        switch tool {
        case .cursorCLI:
            return (parser as? CursorAgentPrintJSONParser)?.latestResultText.flatMap(Self.parseAgentPlanResponse(from:))
        default:
            return nil
        }
    }

    private func importAgentPlan(_ proposedPlan: String, for worktreeID: UUID, runID: UUID, tool: AIAgentTool) {
        do {
            try writePlan(proposedPlan, for: worktreeID)
            planContentVersionsByWorktreeID[worktreeID, default: 0] += 1
            agentPlanDraftsByWorktreeID[worktreeID]?.didImportPlan = true
            agentPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = nil
            agentPlanDraftsByWorktreeID[worktreeID]?.latestQuestions = []
            agentPlanDraftsByWorktreeID[worktreeID]?.requestedSessionTermination = true
            if activeAgentPlanDraftWorktreeID == worktreeID {
                activeAgentPlanDraftWorktreeID = nil
            }

            if let session = terminalSessions[runID] {
                session.terminate()
            } else {
                cleanupAgentPlanDraft(for: worktreeID)
            }
        } catch {
            agentPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = error.localizedDescription
            pendingErrorMessage = "Failed to import \(tool.displayName) plan: \(error.localizedDescription)"
        }
    }

    private static let planTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

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

    private nonisolated static func makePlanDraftDescriptor(
        for tool: AIAgentTool,
        worktree: WorktreeRecord,
        repositoryID: UUID,
        currentPlanText: String,
        artifactURLs: (schema: URL, response: URL)
    ) -> CommandExecutionDescriptor? {
        let prompt = agentPlanPrompt(for: tool, worktree: worktree, currentPlanText: currentPlanText)
        switch tool {
        case .codex:
            return CommandExecutionDescriptor(
                title: "\(tool.displayName) Plan",
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
                    prompt,
                ],
                displayCommandLine: "codex exec --full-auto --json --color never --output-schema \(artifactURLs.schema.path.shellEscaped) --output-last-message \(artifactURLs.response.path.shellEscaped) <prompt>",
                currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                repositoryID: repositoryID,
                worktreeID: worktree.id,
                runtimeRequirement: nil,
                stdinText: nil,
                environment: [:],
                usesTerminalSession: false,
                outputInterpreter: .codexExecJSONL
            )
        case .cursorCLI:
            return CommandExecutionDescriptor(
                title: "\(tool.displayName) Plan",
                actionKind: .aiAgent,
                showsAgentIndicator: false,
                executable: "cursor-agent",
                arguments: [
                    "--print",
                    "--output-format", "json",
                    "--trust",
                    "--plan",
                    prompt,
                ],
                displayCommandLine: "cursor-agent --print --output-format json --trust --plan <prompt>",
                currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                repositoryID: repositoryID,
                worktreeID: worktree.id,
                runtimeRequirement: nil,
                stdinText: nil,
                environment: [:],
                usesTerminalSession: false,
                outputInterpreter: .cursorAgentPrintJSON
            )
        default:
            return nil
        }
    }

    private nonisolated static func makePlanReplyDescriptor(
        for tool: AIAgentTool,
        repositoryID: UUID,
        worktree: WorktreeRecord,
        responseFilePath: String?,
        sessionID: String,
        reply: String
    ) -> CommandExecutionDescriptor? {
        let prompt = agentPlanFollowUpPrompt(for: tool, reply: reply)
        switch tool {
        case .codex:
            guard let responseFilePath = responseFilePath?.nonEmpty else { return nil }
            return CommandExecutionDescriptor(
                title: "\(tool.displayName) Plan",
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
                    prompt,
                ],
                displayCommandLine: "codex exec resume --full-auto --json --output-last-message \(responseFilePath.shellEscaped) \(sessionID.shellEscaped) <reply>",
                currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                repositoryID: repositoryID,
                worktreeID: worktree.id,
                runtimeRequirement: nil,
                stdinText: nil,
                environment: [:],
                usesTerminalSession: false,
                outputInterpreter: .codexExecJSONL
            )
        case .cursorCLI:
            return CommandExecutionDescriptor(
                title: "\(tool.displayName) Plan",
                actionKind: .aiAgent,
                showsAgentIndicator: false,
                executable: "cursor-agent",
                arguments: [
                    "--resume", sessionID,
                    "--print",
                    "--output-format", "json",
                    "--trust",
                    "--plan",
                    prompt,
                ],
                displayCommandLine: "cursor-agent --resume \(sessionID.shellEscaped) --print --output-format json --trust --plan <reply>",
                currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                repositoryID: repositoryID,
                worktreeID: worktree.id,
                runtimeRequirement: nil,
                stdinText: nil,
                environment: [:],
                usesTerminalSession: false,
                outputInterpreter: .cursorAgentPrintJSON
            )
        default:
            return nil
        }
    }

    private nonisolated static func agentPlanPrompt(for tool: AIAgentTool, worktree: WorktreeRecord, currentPlanText: String) -> String {
        let issueContext = worktree.issueContext?.nonEmpty ?? worktree.branchName
        var lines = [
            "Help me create or refine an implementation plan for this worktree.",
            "",
            "Planning agent: \(tool.displayName)",
            "Worktree branch: \(worktree.branchName)",
            "User description: \(issueContext)",
            "",
            "Inspect the codebase before deciding on the plan.",
            "If you need more context from the user, do not produce the plan yet. Return only a JSON object with status `needs_user_input`, a short summary, and 1-4 concrete questions.",
            "If you have enough information, return only a JSON object with status `ready`, a short summary, and `plan_markdown` containing the final Markdown plan that should replace the plan page.",
            "Never wrap the final response in Markdown fences.",
        ]

        if tool == .cursorCLI {
            lines.append("When using \(tool.displayName), ensure the `result` payload is valid JSON matching that schema exactly.")
        }

        if let existingPlan = currentPlanText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            lines.append("")
            lines.append("Current plan draft to refine:")
            lines.append("```md")
            lines.append(existingPlan)
            lines.append("```")
        }

        return lines.joined(separator: "\n")
    }

    private nonisolated static func agentPlanFollowUpPrompt(for tool: AIAgentTool, reply: String) -> String {
        [
            "The user answered the follow-up questions below.",
            "Continue working in the same repository context.",
            "Planning agent: \(tool.displayName)",
            "If you still need more information, return only a JSON object with status `needs_user_input`, a short summary, and 1-4 concrete questions.",
            "If you are ready, return only a JSON object with status `ready`, a short summary, and `plan_markdown` containing the final Markdown plan that should replace the plan page.",
            "Never wrap the final response in Markdown fences.",
            "",
            "User reply:",
            reply,
        ].joined(separator: "\n")
    }

    nonisolated static func parseAgentPlanResponse(from text: String) -> AgentPlanResponse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let response = try? JSONDecoder().decode(AgentPlanResponse.self, from: data) else {
            return nil
        }
        return validatedAgentPlanResponse(response)
    }

    private nonisolated static func validatedAgentPlanResponse(_ response: AgentPlanResponse) -> AgentPlanResponse? {
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

    private nonisolated static func readAgentPlanResponse(from path: String?) -> AgentPlanResponse? {
        guard let path = path?.nonEmpty else { return nil }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parseAgentPlanResponse(from: text)
    }

    private nonisolated static func prepareAgentPlanArtifactURLs(for tool: AIAgentTool, worktreeID: UUID) throws -> (schema: URL, response: URL) {
        let fileManager = FileManager.default
        let directory = AppPaths.agentPlanArtifactsDirectory(for: tool, worktreeID: worktreeID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let schemaURL = directory.appendingPathComponent("response-schema.json", isDirectory: false)
        let responseURL = directory.appendingPathComponent("last-response.json", isDirectory: false)
        try agentPlanResponseSchemaJSON().write(to: schemaURL, atomically: true, encoding: .utf8)
        if fileManager.fileExists(atPath: responseURL.path) {
            try fileManager.removeItem(at: responseURL)
        }

        return (schemaURL, responseURL)
    }

    private nonisolated static func removeAgentPlanArtifacts(for draft: AgentPlanDraft) {
        let directory = AppPaths.agentPlanArtifactsDirectory(for: draft.tool, worktreeID: draft.worktreeID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private nonisolated static func agentPlanResponseSchemaJSON() -> String {
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

    // MARK: - Compatibility wrappers

    func codexPlanDraft(for worktreeID: UUID) -> AgentPlanDraft? {
        guard let draft = agentPlanDraftsByWorktreeID[worktreeID], draft.tool == .codex else { return nil }
        return draft
    }

    func dismissPresentedCodexPlanDraft() {
        dismissPresentedAgentPlanDraft()
    }

    func startCodexPlanDraft(
        for worktree: WorktreeRecord,
        in repository: ManagedRepository,
        currentPlanText: String,
        modelContext: ModelContext
    ) {
        startAgentPlanDraft(using: .codex, for: worktree, in: repository, currentPlanText: currentPlanText, modelContext: modelContext)
    }

    func sendCodexPlanReply(_ reply: String, for worktreeID: UUID) {
        sendAgentPlanReply(reply, for: worktreeID)
    }

    func cancelCodexPlanDraft(for worktreeID: UUID) {
        cancelAgentPlanDraft(for: worktreeID)
    }

    func importCompletedCodexPlanIfAvailable(forRunID runID: UUID) {
        importCompletedAgentPlanIfAvailable(forRunID: runID)
    }

    func syncCodexPlanSessionID(forRunID runID: UUID) {
        syncAgentPlanSessionID(forRunID: runID)
    }

    nonisolated static func parseCodexPlanResponse(from text: String) -> AgentPlanResponse? {
        parseAgentPlanResponse(from: text)
    }
}
