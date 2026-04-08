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

    func selectPrimaryContextTab(for worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectedWorktreeIDsByRepository[repository.id] = worktree.id
        terminalTabs.selectPlanTab(for: worktree.id)
    }

    func isPrimaryContextTabSelected(for worktree: WorktreeRecord) -> Bool {
        terminalTabs.isPlanTabSelected(for: worktree.id)
    }

    func selectPlanTab(for worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectPrimaryContextTab(for: worktree, in: repository)
    }

    func isPlanTabSelected(for worktree: WorktreeRecord) -> Bool {
        isPrimaryContextTabSelected(for: worktree)
    }

    func primaryPane(for worktree: WorktreeRecord) -> WorktreePrimaryPaneKind {
        terminalTabs.primaryPane(for: worktree.id)
    }

    func selectPrimaryPane(_ pane: WorktreePrimaryPaneKind, for worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectedWorktreeIDsByRepository[repository.id] = worktree.id
        terminalTabs.selectPrimaryPane(pane, for: worktree.id)
    }

    // MARK: - Intent & implementation plan file I/O

    /// Legacy `Plans/{uuid}.md` is migrated once into `intentFile` when the intent file is missing (see `ensureLegacyPlanMigrationIfNeeded`).
    func loadIntent(for worktreeID: UUID) -> String {
        if let cached = intentContentsByWorktreeID[worktreeID] {
            return cached
        }
        ensureLegacyPlanMigrationIfNeeded(for: worktreeID)
        let url = AppPaths.intentFile(for: worktreeID)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        intentContentsByWorktreeID[worktreeID] = text
        return text
    }

    func writeIntent(_ text: String, for worktreeID: UUID) throws {
        ensureLegacyPlanMigrationIfNeeded(for: worktreeID)
        let url = AppPaths.intentFile(for: worktreeID)
        try FileManager.default.createDirectory(at: AppPaths.plansDirectory, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func saveIntent(_ text: String, for worktreeID: UUID) {
        do {
            try writeIntent(text, for: worktreeID)
            intentContentsByWorktreeID[worktreeID] = text
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func loadImplementationPlan(for worktreeID: UUID) -> String {
        if let cached = implementationPlanContentsByWorktreeID[worktreeID] {
            return cached
        }
        ensureLegacyPlanMigrationIfNeeded(for: worktreeID)
        let url = AppPaths.implementationPlanFile(for: worktreeID)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        implementationPlanContentsByWorktreeID[worktreeID] = text
        implementationPlanPresenceByWorktreeID[worktreeID] =
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return text
    }

    func writeImplementationPlan(_ text: String, for worktreeID: UUID) throws {
        ensureLegacyPlanMigrationIfNeeded(for: worktreeID)
        let url = AppPaths.implementationPlanFile(for: worktreeID)
        try FileManager.default.createDirectory(at: AppPaths.plansDirectory, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func saveImplementationPlan(_ text: String, for worktreeID: UUID) {
        do {
            try writeImplementationPlan(text, for: worktreeID)
            implementationPlanContentsByWorktreeID[worktreeID] = text
            implementationPlanPresenceByWorktreeID[worktreeID] =
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func hasImplementationPlanContent(for worktreeID: UUID) -> Bool {
        if let cached = implementationPlanPresenceByWorktreeID[worktreeID] {
            return cached
        }
        return loadImplementationPlan(for: worktreeID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func cachedIntent(for worktreeID: UUID) -> String? {
        intentContentsByWorktreeID[worktreeID]
    }

    func cachedImplementationPlan(for worktreeID: UUID) -> String? {
        implementationPlanContentsByWorktreeID[worktreeID]
    }

    func preloadIntent(for worktreeID: UUID) async -> String {
        if let cached = intentContentsByWorktreeID[worktreeID] {
            return cached
        }
        ensureLegacyPlanMigrationIfNeeded(for: worktreeID)
        let url = AppPaths.intentFile(for: worktreeID)
        let text = await Task.detached(priority: .utility) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
        intentContentsByWorktreeID[worktreeID] = text
        return text
    }

    func preloadImplementationPlan(for worktreeID: UUID) async -> String {
        if let cached = implementationPlanContentsByWorktreeID[worktreeID] {
            return cached
        }
        ensureLegacyPlanMigrationIfNeeded(for: worktreeID)
        let url = AppPaths.implementationPlanFile(for: worktreeID)
        let text = await Task.detached(priority: .utility) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
        implementationPlanContentsByWorktreeID[worktreeID] = text
        implementationPlanPresenceByWorktreeID[worktreeID] =
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return text
    }

    func intentContentVersion(for worktreeID: UUID) -> Int {
        intentContentVersionsByWorktreeID[worktreeID] ?? 0
    }

    func implementationPlanContentVersion(for worktreeID: UUID) -> Int {
        implementationPlanContentVersionsByWorktreeID[worktreeID] ?? 0
    }

    func bumpIntentContentVersion(for worktreeID: UUID) {
        intentContentVersionsByWorktreeID[worktreeID, default: 0] += 1
    }

    /// Copies legacy `Plans/{uuid}.md` into `intentFile` once, then renames the legacy file to `.md.pre-split-backup` so data is not lost.
    private func ensureLegacyPlanMigrationIfNeeded(for worktreeID: UUID) {
        let legacy = AppPaths.planFile(for: worktreeID)
        let intentURL = AppPaths.intentFile(for: worktreeID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        guard !fm.fileExists(atPath: intentURL.path) else { return }
        guard let data = try? Data(contentsOf: legacy),
              let text = String(data: data, encoding: .utf8) else { return }
        do {
            try fm.createDirectory(at: AppPaths.plansDirectory, withIntermediateDirectories: true)
            try text.write(to: intentURL, atomically: true, encoding: .utf8)
            let backup = legacy.deletingPathExtension().appendingPathExtension("md.pre-split-backup")
            if fm.fileExists(atPath: backup.path) {
                try fm.removeItem(at: backup)
            }
            try fm.moveItem(at: legacy, to: backup)
            bumpIntentContentVersion(for: worktreeID)
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

    func launchAgentWithPlan(
        _ tool: AIAgentTool,
        for worktree: WorktreeRecord,
        in modelContext: ModelContext,
        options: AgentLaunchOptions = AgentLaunchOptions(),
        promptOverride: String? = nil
    ) async {
        guard let repository = worktree.repository else {
            pendingErrorMessage = StackriotError.worktreeUnavailable.localizedDescription
            return
        }
        guard await materializeIdeaTreeIfNeeded(worktree, in: repository, modelContext: modelContext) != nil else { return }
        let promptText = promptOverride ?? planExecutionPrompt(for: worktree).text
        _ = await launchAgent(tool, for: worktree, in: modelContext, initialPrompt: promptText, options: options)
    }

    func prepareAgentExecutionWithPlan(
        _ tool: AIAgentTool,
        for worktree: WorktreeRecord,
        in repository: ManagedRepository,
        options: AgentLaunchOptions = AgentLaunchOptions()
    ) async {
        guard availableAgents.contains(tool) else {
            pendingErrorMessage = "\(tool.displayName) is not available on this machine."
            return
        }
        if worktree.isIdeaTree {
            guard let modelContext = storedModelContext else {
                pendingErrorMessage = "The model context is unavailable."
                return
            }
            guard await materializeIdeaTreeIfNeeded(worktree, in: repository, modelContext: modelContext) != nil else { return }
        }

        let prompt = planExecutionPrompt(for: worktree)
        let trimmedPrompt = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            pendingErrorMessage = "\(prompt.sourceTitle) is empty."
            return
        }

        if let draft = makePendingAgentExecutionDraft(
            purpose: .execution,
            tool: tool,
            worktree: worktree,
            repository: repository,
            promptSourceTitle: prompt.sourceTitle,
            promptText: prompt.text,
            activatesTerminalTab: options.activatesTerminalTab
        ) {
            pendingAgentExecutionDraft = draft
            return
        }

        if let modelContext = storedModelContext {
            await launchAgentWithPlan(tool, for: worktree, in: modelContext, options: options, promptOverride: prompt.text)
        } else {
            pendingErrorMessage = "The model context is unavailable."
        }
    }

    func prepareCopilotExecutionWithPlan(
        for worktree: WorktreeRecord,
        in repository: ManagedRepository,
        options: AgentLaunchOptions = AgentLaunchOptions()
    ) async {
        await prepareAgentExecutionWithPlan(.githubCopilot, for: worktree, in: repository, options: options)
    }

    func prepareAgentPlanningWithIntent(
        _ tool: AIAgentTool,
        for worktree: WorktreeRecord,
        in repository: ManagedRepository,
        currentIntentText: String,
        modelContext: ModelContext
    ) async {
        guard availableAgents.contains(tool) else {
            pendingErrorMessage = "\(tool.displayName) is not available on this machine."
            return
        }
        guard !worktree.isDefaultBranchWorkspace else { return }
        guard await materializeIdeaTreeIfNeeded(worktree, in: repository, modelContext: modelContext) != nil else { return }

        let trimmedIntent = currentIntentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let draft = makePendingAgentExecutionDraft(
            purpose: .planning,
            tool: tool,
            worktree: worktree,
            repository: repository,
            promptSourceTitle: "Intent",
            promptText: trimmedIntent,
            activatesTerminalTab: true
        ) {
            pendingAgentExecutionDraft = draft
            return
        }

        await startAgentPlanDraft(
            using: tool,
            for: worktree,
            in: repository,
            currentIntentText: trimmedIntent,
            modelContext: modelContext
        )
    }

    func prepareCopilotPlanningWithIntent(
        for worktree: WorktreeRecord,
        in repository: ManagedRepository,
        currentIntentText: String,
        modelContext: ModelContext
    ) async {
        await prepareAgentPlanningWithIntent(
            .githubCopilot,
            for: worktree,
            in: repository,
            currentIntentText: currentIntentText,
            modelContext: modelContext
        )
    }

    func dismissPendingAgentExecutionDraft() {
        pendingAgentExecutionDraft = nil
    }

    func dismissPendingCopilotExecutionDraft() {
        dismissPendingAgentExecutionDraft()
    }

    func executePendingAgentExecution(in modelContext: ModelContext) {
        guard let draft = pendingAgentExecutionDraft else { return }
        guard let worktree = worktreeRecord(with: draft.worktreeID) else {
            pendingAgentExecutionDraft = nil
            pendingErrorMessage = StackriotError.worktreeUnavailable.localizedDescription
            return
        }

        let selectedRepoAgentID = draft.selectedCopilotRepoAgentID.flatMap { selectedID in
            draft.availableCopilotRepoAgents.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        let configOptionsByID = Dictionary(uniqueKeysWithValues: draft.availableConfigOptions.map { ($0.id, $0) })
        let selectedConfigValues: [String: String] = draft.selectedConfigValues.reduce(into: [:]) { partialResult, entry in
            guard let option = configOptionsByID[entry.key] else { return }
            partialResult[entry.key] = AppPreferences.validatedACPConfigValue(entry.value, for: option)
        }
        if let modelOption = configOptionsByID["model"], draft.tool == .githubCopilot {
            let selectedModelID = AppPreferences.validatedACPConfigValue(
                selectedConfigValues["model"],
                for: modelOption
            )
            AppPreferences.setDefaultCopilotModelID(selectedModelID)
        }
        for option in draft.availableConfigOptions {
            if let selectedValue = selectedConfigValues[option.id] {
                AppPreferences.setDefaultACPConfigValue(selectedValue, for: draft.tool, configOption: option)
            }
        }

        let options = AgentLaunchOptions(
            copilotAgentOverride: selectedRepoAgentID,
            acpModeOverride: effectiveModeOverride(for: draft),
            acpConfigOverrides: selectedConfigValues,
            activatesTerminalTab: draft.activatesTerminalTab
        )

        pendingAgentExecutionDraft = nil
        Task {
            switch draft.purpose {
            case .execution:
                await launchAgentWithPlan(
                    draft.tool,
                    for: worktree,
                    in: modelContext,
                    options: options,
                    promptOverride: draft.promptText
                )
            case .planning:
                guard let repository = repositoryRecord(with: draft.repositoryID) else {
                    pendingErrorMessage = StackriotError.worktreeUnavailable.localizedDescription
                    return
                }
                await startAgentPlanDraft(
                    using: draft.tool,
                    for: worktree,
                    in: repository,
                    currentIntentText: draft.promptText,
                    modelContext: modelContext,
                    options: options
                )
            }
        }
    }

    func executePendingCopilotExecution(in modelContext: ModelContext) {
        executePendingAgentExecution(in: modelContext)
    }

    private func availableCopilotRepoAgents(for worktree: WorktreeRecord) throws -> [CopilotRepoAgent] {
        guard let worktreeURL = worktree.materializedURL else { return [] }
        return try CopilotRepoAgent.discover(in: worktreeURL)
    }

    private func makePendingAgentExecutionDraft(
        purpose: PendingAgentExecutionPurpose,
        tool: AIAgentTool,
        worktree: WorktreeRecord,
        repository: ManagedRepository,
        promptSourceTitle: String,
        promptText: String,
        activatesTerminalTab: Bool
    ) -> PendingAgentExecutionDraft? {
        let availableModes = launchableModes(for: tool, purpose: purpose)
        let availableConfigOptions = launchableConfigOptions(for: tool)
        let repoAgents: [CopilotRepoAgent]
        do {
            repoAgents = tool == .githubCopilot ? try availableCopilotRepoAgents(for: worktree) : []
        } catch {
            pendingErrorMessage = "Failed to read \(tool.displayName) repo configuration: \(error.localizedDescription)"
            return nil
        }

        guard availableModes.isEmpty == false || availableConfigOptions.isEmpty == false || repoAgents.isEmpty == false || tool == .githubCopilot else {
            return nil
        }

        let selectedModeID = purpose == .execution ? defaultModeSelection(for: tool, availableModes: availableModes) : nil
        let selectedConfigValues = defaultConfigSelections(for: tool, configOptions: availableConfigOptions)

        return PendingAgentExecutionDraft(
            purpose: purpose,
            tool: tool,
            worktreeID: worktree.id,
            repositoryID: repository.id,
            promptSourceTitle: promptSourceTitle,
            promptText: promptText,
            activatesTerminalTab: activatesTerminalTab,
            availableModes: availableModes,
            selectedModeID: selectedModeID,
            availableConfigOptions: availableConfigOptions,
            selectedConfigValues: selectedConfigValues,
            availableCopilotRepoAgents: repoAgents,
            selectedCopilotRepoAgentID: nil
        )
    }

    private func defaultModeSelection(for tool: AIAgentTool, availableModes: [ACPDiscoveredMode]) -> String? {
        guard let snapshot = acpAgentSnapshotsByTool[tool] else { return nil }
        let currentModeID = snapshot.currentModeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let currentModeID, availableModes.contains(where: { $0.id == currentModeID }) {
            return currentModeID
        }
        return availableModes.first?.id
    }

    private func defaultConfigSelections(
        for tool: AIAgentTool,
        configOptions: [ACPDiscoveredConfigOption]
    ) -> [String: String] {
        configOptions.reduce(into: [:]) { partialResult, option in
            let fallbackValue: String?
            if tool == .githubCopilot, option.id == "model" {
                fallbackValue = AppPreferences.defaultCopilotModelID
            } else {
                fallbackValue = nil
            }
            partialResult[option.id] = AppPreferences.defaultACPConfigValue(
                for: tool,
                configOption: option,
                fallbackValue: fallbackValue
            )
        }
    }

    private func launchableModes(
        for tool: AIAgentTool,
        purpose: PendingAgentExecutionPurpose
    ) -> [ACPDiscoveredMode] {
        guard purpose == .execution else { return [] }
        let modes = acpAgentSnapshotsByTool[tool]?.modes ?? []
        return modes.filter { mode in
            switch tool {
            case .githubCopilot:
                let id = mode.id.lowercased()
                return id.hasSuffix("#agent") || id.hasSuffix("#autopilot")
                    || id == "agent" || id == "autopilot"
            case .openCode:
                return true
            default:
                return false
            }
        }
    }

    private func launchableConfigOptions(for tool: AIAgentTool) -> [ACPDiscoveredConfigOption] {
        let snapshot = acpAgentSnapshotsByTool[tool]
        var configOptions = snapshot?.configOptions ?? []

        if let synthesizedModelOption = synthesizedModelConfigOption(for: tool, snapshot: snapshot) {
            configOptions.removeAll { $0.semanticCategory == .model || $0.id == "model" }
            configOptions.insert(synthesizedModelOption, at: 0)
        }

        return configOptions.filter { option in
            switch tool {
            case .githubCopilot:
                option.id == "model" || option.id == "reasoning_effort" || option.semanticCategory == .thoughtLevel
            case .openCode:
                option.id == "model" || option.semanticCategory == .model
            default:
                false
            }
        }
    }

    private func synthesizedModelConfigOption(
        for tool: AIAgentTool,
        snapshot: ACPAgentSnapshot?
    ) -> ACPDiscoveredConfigOption? {
        switch tool {
        case .githubCopilot:
            let discoveredModels = snapshot?.models.map {
                ACPDiscoveredConfigValue(value: $0.id, displayName: $0.displayName, description: $0.description)
            } ?? AppPreferences.copilotModelOptions.map {
                ACPDiscoveredConfigValue(value: $0.id, displayName: $0.displayName, description: nil)
            }
            let autoOption = ACPDiscoveredConfigValue(value: CopilotModelOption.auto.id, displayName: CopilotModelOption.auto.displayName, description: nil)
            let deduplicated = ([autoOption] + discoveredModels).reduce(into: [ACPDiscoveredConfigValue]()) { partialResult, option in
                if partialResult.contains(where: { $0.value == option.value }) == false {
                    partialResult.append(option)
                }
            }
            guard deduplicated.isEmpty == false else { return nil }
            return ACPDiscoveredConfigOption(
                id: "model",
                displayName: "Model",
                description: "Preferred default model for prompt-mode runs.",
                rawCategory: ACPDiscoveredConfigSemanticCategory.model.rawValue,
                currentValue: snapshot?.currentModelID ?? CopilotModelOption.auto.id,
                groups: [ACPDiscoveredConfigValueGroup(groupID: nil, displayName: nil, options: deduplicated)]
            )
        case .openCode:
            let discoveredModels = snapshot?.models.map {
                ACPDiscoveredConfigValue(value: $0.id, displayName: $0.displayName, description: $0.description)
            } ?? []
            guard discoveredModels.isEmpty == false else { return nil }
            return ACPDiscoveredConfigOption(
                id: "model",
                displayName: "Model",
                description: "ACP-discovered OpenCode model catalog.",
                rawCategory: ACPDiscoveredConfigSemanticCategory.model.rawValue,
                currentValue: snapshot?.currentModelID ?? discoveredModels[0].value,
                groups: [ACPDiscoveredConfigValueGroup(groupID: nil, displayName: nil, options: discoveredModels)]
            )
        default:
            return nil
        }
    }

    private func effectiveModeOverride(for draft: PendingAgentExecutionDraft) -> String? {
        guard let selectedModeID = draft.selectedModeID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        guard draft.availableModes.contains(where: { $0.id == selectedModeID }) else {
            return nil
        }
        return selectedModeID
    }

    func availablePlanningAgents() -> [AIAgentTool] {
        AIAgentTool.allCases.filter { tool in
            tool != .none && tool.supportsPlanning && availableAgents.contains(tool)
        }
    }

    private func planExecutionPrompt(for worktree: WorktreeRecord) -> (sourceTitle: String, text: String) {
        switch terminalTabs.primaryPane(for: worktree.id) {
        case .implementationPlan:
            ("Implementation Plan", loadImplementationPlan(for: worktree.id))
        case .intent, .browser, .devContainerLogs:
            ("Intent", loadIntent(for: worktree.id))
        }
    }

    func agentPlanDraft(for worktreeID: UUID) -> AgentPlanDraft? {
        agentPlanDraftsByWorktreeID[worktreeID]
    }

    func presentAgentPlanDraft(for worktreeID: UUID) {
        guard agentPlanDraftsByWorktreeID[worktreeID] != nil else { return }
        if let activeWorktreeID = activeAgentPlanDraftWorktreeID, activeWorktreeID != worktreeID {
            agentPlanDraftsByWorktreeID[activeWorktreeID]?.presentation = .background
        }
        agentPlanDraftsByWorktreeID[worktreeID]?.presentation = .foreground
        activeAgentPlanDraftWorktreeID = worktreeID
    }

    func sendAgentPlanDraftToBackground(for worktreeID: UUID) {
        guard agentPlanDraftsByWorktreeID[worktreeID] != nil else { return }
        agentPlanDraftsByWorktreeID[worktreeID]?.presentation = .background
        if activeAgentPlanDraftWorktreeID == worktreeID {
            activeAgentPlanDraftWorktreeID = nil
        }
    }

    func dismissPresentedAgentPlanDraft() {
        guard let worktreeID = activeAgentPlanDraftWorktreeID else { return }
        if let draft = agentPlanDraftsByWorktreeID[worktreeID], draft.didImportPlan {
            cleanupAgentPlanDraft(for: worktreeID)
            return
        }
        sendAgentPlanDraftToBackground(for: worktreeID)
    }

    func startAgentPlanDraft(
        using tool: AIAgentTool,
        for worktree: WorktreeRecord,
        in repository: ManagedRepository,
        currentIntentText: String,
        modelContext: ModelContext,
        presentation: AgentPlanDraft.Presentation = .foreground,
        options: AgentLaunchOptions = AgentLaunchOptions()
    ) async {
        guard !worktree.isDefaultBranchWorkspace else { return }
        guard tool.supportsPlanning else {
            pendingErrorMessage = "\(tool.displayName) does not support interactive planning in Stackriot yet."
            return
        }
        guard availableAgents.contains(tool) else {
            pendingErrorMessage = "\(tool.displayName) is not available on this machine."
            return
        }
        guard await materializeIdeaTreeIfNeeded(worktree, in: repository, modelContext: modelContext) != nil else { return }

        if let existingDraft = agentPlanDraftsByWorktreeID[worktree.id] {
            if activeRunIDs.contains(existingDraft.runID) {
                if presentation == .foreground {
                    presentAgentPlanDraft(for: worktree.id)
                }
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

        let existingImplementation = loadImplementationPlan(for: worktree.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        guard let descriptor = Self.makePlanDraftDescriptor(
            for: tool,
            worktree: worktree,
            repositoryID: repository.id,
            currentIntentText: currentIntentText,
            existingImplementationPlan: existingImplementation,
            artifactURLs: artifactURLs,
            options: options
        ) else {
            pendingErrorMessage = "\(tool.displayName) planning is not configured."
            return
        }

        guard let run = startTransientRun(
            descriptor,
            repository: repository,
            worktree: worktree,
            isTransientPlanRun: true
        ) else {
            return
        }
        agentPlanDraftsByWorktreeID[worktree.id] = AgentPlanDraft(
            tool: tool,
            worktreeID: worktree.id,
            repositoryID: repository.id,
            branchName: worktree.branchName,
            issueContext: worktree.issueContext?.nonEmpty ?? worktree.branchName,
            run: run,
            responseFilePath: artifactURLs.response.path,
            schemaFilePath: artifactURLs.schema.path,
            presentation: presentation
        )
        if presentation == .foreground {
            presentAgentPlanDraft(for: worktree.id)
        }
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

        guard let run = startTransientRun(
            descriptor,
            repository: repository,
            worktree: worktree,
            isTransientPlanRun: true
        ) else {
            return
        }
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
                let needsInputMessage = draft.tool.supportsPlanResume
                    ? nil
                    : "\(draft.tool.displayName) requested follow-up input, but Stackriot cannot resume this planning session yet."
                agentPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = needsInputMessage
                if draft.presentation == .background {
                    notifyBackgroundPlanNeedsInput(response, for: draft)
                }
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
        case .claudeCode:
            sessionID = (parser as? ClaudePrintStreamJSONParser)?.currentSessionID?.nonEmpty
        case .githubCopilot:
            sessionID = (parser as? CopilotPromptJSONLParser)?.currentSessionID?.nonEmpty
        case .cursorCLI:
            sessionID = (parser as? CursorAgentPrintJSONParser)?.currentSessionID?.nonEmpty
        case .openCode:
            sessionID = (parser as? OpenCodePromptJSONLParser)?.currentSessionID?.nonEmpty
        default:
            sessionID = nil
        }

        if let sessionID {
            agentPlanDraftsByWorktreeID[worktreeID]?.sessionID = sessionID
        }

        guard let responseFilePath = draft.responseFilePath?.nonEmpty else {
            return
        }

        let responseText: String?
        switch draft.tool {
        case .cursorCLI:
            responseText = (parser as? CursorAgentPrintJSONParser)?.latestResultText?.nonEmpty
        case .claudeCode:
            responseText = (parser as? ClaudePrintStreamJSONParser)?.latestAssistantMessageText?.nonEmpty
        case .githubCopilot:
            responseText = (parser as? CopilotPromptJSONLParser)?.latestAssistantMessageText?.nonEmpty
        case .openCode:
            responseText = (parser as? OpenCodePromptJSONLParser)?.latestAssistantMessageText?.nonEmpty
        default:
            responseText = nil
        }

        guard let responseText else { return }

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
        case .claudeCode:
            return (parser as? ClaudePrintStreamJSONParser)?.latestAssistantMessageText.flatMap(Self.parseAgentPlanResponse(from:))
        case .githubCopilot:
            return (parser as? CopilotPromptJSONLParser)?.latestAssistantMessageText.flatMap(Self.parseAgentPlanResponse(from:))
        case .cursorCLI:
            return (parser as? CursorAgentPrintJSONParser)?.latestResultText.flatMap(Self.parseAgentPlanResponse(from:))
        case .openCode:
            return (parser as? OpenCodePromptJSONLParser)?.latestAssistantMessageText.flatMap(Self.parseAgentPlanResponse(from:))
        default:
            return nil
        }
    }

    private func importAgentPlan(_ proposedPlan: String, for worktreeID: UUID, runID: UUID, tool: AIAgentTool) {
        do {
            try writeImplementationPlan(proposedPlan, for: worktreeID)
            implementationPlanContentsByWorktreeID[worktreeID] = proposedPlan
            implementationPlanPresenceByWorktreeID[worktreeID] =
                proposedPlan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            implementationPlanContentVersionsByWorktreeID[worktreeID, default: 0] += 1
            terminalTabs.selectPrimaryPane(.implementationPlan, for: worktreeID)
            agentPlanDraftsByWorktreeID[worktreeID]?.didImportPlan = true
            agentPlanDraftsByWorktreeID[worktreeID]?.importErrorMessage = nil
            agentPlanDraftsByWorktreeID[worktreeID]?.latestQuestions = []
            agentPlanDraftsByWorktreeID[worktreeID]?.requestedSessionTermination = true
            if activeAgentPlanDraftWorktreeID == worktreeID {
                activeAgentPlanDraftWorktreeID = nil
            }
            if let draft = agentPlanDraftsByWorktreeID[worktreeID], draft.presentation == .background {
                notifyBackgroundPlanImport(for: draft)
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

    private func notifyBackgroundPlanImport(for draft: AgentPlanDraft) {
        notifyOperationSuccess(
            title: "\(draft.tool.displayName) plan imported",
            subtitle: draft.branchName,
            body: "The latest planning run finished in the background and updated the Implementation Plan.",
            userInfo: [
                "worktreeID": draft.worktreeID.uuidString,
                "repositoryID": draft.repositoryID.uuidString,
                "agentTool": draft.tool.rawValue,
            ]
        )
    }

    private func notifyBackgroundPlanNeedsInput(_ response: AgentPlanResponse, for draft: AgentPlanDraft) {
        let summary = response.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "The planning run stopped for additional input."
        let body: String
        if draft.tool.supportsPlanResume {
            body = "\(summary) Reopen the planning run from the worktree context to answer the follow-up questions."
        } else {
            body = "\(summary) Reopen the planning run to review the requested input, then start a fresh planning run after updating the intent."
        }
        notifyOperationFailure(
            title: "\(draft.tool.displayName) planning needs input",
            subtitle: draft.branchName,
            body: body,
            userInfo: [
                "worktreeID": draft.worktreeID.uuidString,
                "repositoryID": draft.repositoryID.uuidString,
                "agentTool": draft.tool.rawValue,
            ]
        )
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
        currentIntentText: String,
        existingImplementationPlan: String?,
        artifactURLs: (schema: URL, response: URL),
        options: AgentLaunchOptions
    ) -> CommandExecutionDescriptor? {
        let prompt = agentPlanPrompt(
            for: tool,
            worktree: worktree,
            currentIntentText: currentIntentText,
            existingImplementationPlan: existingImplementationPlan
        )
        guard let executable = tool.executableName,
              let components = tool.planDraftCommandComponents(
                  for: prompt,
                  artifactURLs: artifactURLs,
                  options: options
              )
        else {
            return nil
        }
        return makeAgentPlanDescriptor(
            title: "\(tool.displayName) Plan",
            tool: tool,
            executable: executable,
            components: components,
            worktree: worktree,
            repositoryID: repositoryID,
            initialPrompt: prompt
        )
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
        guard let executable = tool.executableName,
              let components = tool.planReplyCommandComponents(
                  for: prompt,
                  sessionID: sessionID,
                  responseFilePath: responseFilePath
              )
        else {
            return nil
        }
        return makeAgentPlanDescriptor(
            title: "\(tool.displayName) Plan",
            tool: tool,
            executable: executable,
            components: components,
            worktree: worktree,
            repositoryID: repositoryID,
            initialPrompt: prompt
        )
    }

    private nonisolated static func makeAgentPlanDescriptor(
        title: String,
        tool: AIAgentTool,
        executable: String,
        components: AgentPromptCommandComponents,
        worktree: WorktreeRecord,
        repositoryID: UUID,
        initialPrompt: String
    ) -> CommandExecutionDescriptor {
        CommandExecutionDescriptor(
            title: title,
            actionKind: .aiAgent,
            showsAgentIndicator: false,
            executable: executable,
            arguments: components.arguments,
            displayCommandLine: components.displayCommandLine,
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repositoryID,
            worktreeID: worktree.id,
            runtimeRequirement: nil,
            stdinText: nil,
            environment: [:],
            usesTerminalSession: false,
            outputInterpreter: tool.promptOutputInterpreter,
            agentTool: tool,
            initialPrompt: initialPrompt
        )
    }

    private nonisolated static func agentPlanPrompt(
        for tool: AIAgentTool,
        worktree: WorktreeRecord,
        currentIntentText: String,
        existingImplementationPlan: String?
    ) -> String {
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
            "If you have enough information, return only a JSON object with status `ready`, a short summary, and `plan_markdown` containing the final Markdown plan that should be written to the implementation plan file (not the intent draft).",
            "Never wrap the final response in Markdown fences.",
        ]

        if tool == .cursorCLI {
            lines.append("When using \(tool.displayName), ensure the `result` payload is valid JSON matching that schema exactly.")
        }

        if let intentDraft = currentIntentText.nonEmpty {
            lines.append("")
            lines.append("Current intent / draft description (primary input):")
            lines.append("```md")
            lines.append(intentDraft)
            lines.append("```")
        }

        if let existingImplementationPlan {
            lines.append("")
            lines.append("Existing implementation plan from a prior run (optional context; may be revised or replaced):")
            lines.append("```md")
            lines.append(existingImplementationPlan)
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
            "If you are ready, return only a JSON object with status `ready`, a short summary, and `plan_markdown` containing the final Markdown implementation plan.",
            "Never wrap the final response in Markdown fences.",
            "",
            "User reply:",
            reply,
        ].joined(separator: "\n")
    }

    nonisolated static func parseAgentPlanResponse(from text: String) -> AgentPlanResponse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let response = decodeAgentPlanResponse(from: trimmed) {
            return response
        }
        guard let embeddedObject = extractLastJSONObject(from: trimmed) else {
            return nil
        }
        return decodeAgentPlanResponse(from: embeddedObject)
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

    private nonisolated static func decodeAgentPlanResponse(from text: String) -> AgentPlanResponse? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let response = try? JSONDecoder().decode(AgentPlanResponse.self, from: data) else {
            return nil
        }
        return validatedAgentPlanResponse(response)
    }

    private nonisolated static func extractLastJSONObject(from text: String) -> String? {
        var startIndex: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaping = false
        var lastObject: String?

        for index in text.indices {
            let character = text[index]

            if isEscaping {
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            guard !isInsideString else { continue }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
                continue
            }

            guard character == "}", depth > 0 else { continue }
            depth -= 1
            if depth == 0, let startIndex {
                lastObject = String(text[startIndex...index])
            }
        }

        return lastObject?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
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
        currentIntentText: String,
        modelContext: ModelContext
    ) {
        Task {
            await startAgentPlanDraft(using: .codex, for: worktree, in: repository, currentIntentText: currentIntentText, modelContext: modelContext)
        }
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
