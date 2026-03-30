import Foundation
import SwiftData

extension AppModel {
    func installedAgentTools() -> [AIAgentTool] {
        AIAgentTool.allCases.filter { tool in
            tool != .none && availableAgents.contains(tool)
        }
    }

    func availableRunConfigurations(for worktree: WorktreeRecord) -> [RunConfiguration] {
        services.runConfigurationDiscovery.discoverRunConfigurations(in: URL(fileURLWithPath: worktree.path))
    }

    func availableDevTools(for worktree: WorktreeRecord) -> [SupportedDevTool] {
        services.devToolDiscovery.availableTools(in: URL(fileURLWithPath: worktree.path))
    }

    func openDevTool(_ tool: SupportedDevTool, for worktree: WorktreeRecord, in modelContext: ModelContext) async {
        do {
            try await services.ideManager.open(tool, worktreeURL: URL(fileURLWithPath: worktree.path))
            worktree.lastOpenedAt = .now
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func openIDE(_ tool: SupportedDevTool, for worktree: WorktreeRecord, in modelContext: ModelContext) async {
        await openDevTool(tool, for: worktree, in: modelContext)
    }

    func openTerminal(for worktree: WorktreeRecord, in modelContext: ModelContext) {
        guard let repository = worktree.repository else { return }

        let shell = ProcessInfo.processInfo.environment["SHELL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let loginShell = (shell?.isEmpty == false ? shell! : "/bin/zsh")

        let descriptor = CommandExecutionDescriptor(
            title: "Terminal",
            actionKind: .aiAgent,
            executable: loginShell,
            arguments: ["-il"],
            displayCommandLine: loginShell,
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            runtimeRequirement: nil,
            stdinText: nil
        )
        startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
    }

    func launchRunConfiguration(
        _ configuration: RunConfiguration,
        in worktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) async {
        let availableTools = Set(availableDevTools(for: worktree))
        if let descriptor = services.runConfigurationDiscovery.makeExecutionDescriptor(
            for: configuration,
            worktree: worktree,
            repositoryID: repository.id,
            availableTools: availableTools
        ) {
            startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
            return
        }

        if let preferredDevTool = configuration.preferredDevTool, availableTools.contains(preferredDevTool) {
            await openDevTool(preferredDevTool, for: worktree, in: modelContext)
            return
        }

        pendingErrorMessage = StackriotError.runConfigurationUnavailable(configuration.name).localizedDescription
    }


    func runGitCommit(message: String, in worktree: WorktreeRecord, repository: ManagedRepository, modelContext: ModelContext) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let shellCommand = "git add -A && git commit -m \(trimmedMessage.shellEscaped)"
        let descriptor = CommandExecutionDescriptor(
            title: "git commit",
            actionKind: .gitOperation,
            executable: "/bin/sh",
            arguments: ["-lc", shellCommand],
            displayCommandLine: "git add -A && git commit -m \"\(trimmedMessage)\"",
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            runtimeRequirement: nil,
            stdinText: nil
        )
        startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
    }

    func runGitPush(in worktree: WorktreeRecord, repository: ManagedRepository, modelContext: ModelContext) async {
        do {
            let hasUpstream = try await services.repositoryManager.hasUpstreamBranch(
                worktreePath: URL(fileURLWithPath: worktree.path)
            )

            if !hasUpstream {
                presentPublishSheet(for: repository, worktree: worktree)
                return
            }

            let descriptor = CommandExecutionDescriptor(
                title: "git push",
                actionKind: .gitOperation,
                executable: "git",
                arguments: ["push"],
                displayCommandLine: nil,
                currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                repositoryID: repository.id,
                worktreeID: worktree.id,
                runtimeRequirement: nil,
                stdinText: nil
            )
            startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func runGitPull(in worktree: WorktreeRecord, repository: ManagedRepository, modelContext: ModelContext) async {
        let descriptor = CommandExecutionDescriptor(
            title: "git pull",
            actionKind: .gitOperation,
            executable: "git",
            arguments: ["pull"],
            displayCommandLine: nil,
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            runtimeRequirement: nil,
            stdinText: nil
        )
        startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
    }

    func checkAgentAvailability() async {
        availableAgents = await services.agentManager.checkAvailability()
    }

    func launchFixWithAI(for run: RunRecord, using tool: AIAgentTool, in modelContext: ModelContext) {
        guard run.isFixableBuildFailure,
              let runConfigurationID = run.runConfigurationID?.nonEmpty,
              let worktreeID = run.worktreeID,
              let worktree = worktreeRecord(with: worktreeID),
              let repository = worktree.repository
        else {
            pendingErrorMessage = "This failed run can no longer be fixed automatically."
            return
        }

        let prompt = Self.fixWithAIPrompt(for: run)
        guard let agentRun = launchAgent(tool, for: worktree, in: modelContext, initialPrompt: prompt) else {
            return
        }

        pendingRunFixesByAgentRunID[agentRun.id] = RunFixRequest(
            tool: tool,
            sourceRunID: run.id,
            runConfigurationID: runConfigurationID,
            worktreeID: worktreeID,
            runTitle: run.title
        )
        selectedWorktreeIDsByRepository[repository.id] = worktreeID
    }

    func completePendingRunFixIfNeeded(afterAgentRunID agentRunID: UUID, succeeded: Bool) {
        guard let request = pendingRunFixesByAgentRunID.removeValue(forKey: agentRunID) else { return }
        guard succeeded else { return }
        guard let modelContext = storedModelContext else {
            pendingErrorMessage = "The original run could not be retried because the model context is unavailable."
            return
        }
        guard let worktree = worktreeRecord(with: request.worktreeID), let repository = worktree.repository else {
            pendingErrorMessage = StackriotError.worktreeUnavailable.localizedDescription
            return
        }

        let configurations = availableRunConfigurations(for: worktree)
        guard let configuration = configurations.first(where: { $0.id == request.runConfigurationID }) else {
            pendingErrorMessage = "The original run configuration \(request.runTitle) is no longer available for retry."
            return
        }

        let availableTools = Set(availableDevTools(for: worktree))
        guard let descriptor = services.runConfigurationDiscovery.makeExecutionDescriptor(
            for: configuration,
            worktree: worktree,
            repositoryID: repository.id,
            availableTools: availableTools
        ) else {
            pendingErrorMessage = StackriotError.runConfigurationUnavailable(configuration.name).localizedDescription
            return
        }

        _ = startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
    }

    nonisolated static func fixWithAIPrompt(for run: RunRecord) -> String {
        let commandLine = run.commandLine.nonEmpty ?? run.title
        let errorCode = run.exitCode.map(String.init) ?? "unbekannt"
        let shellLog = run.outputText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Keine Shell-Ausgabe verfuegbar."

        return """
        # Fehler beim Build
        - Benutztes CMD: \(commandLine)
        - Fehlercode: \(errorCode)

        <ShellLog>
        \(shellLog)
        </ShellLog>

        # Erwartetes Verhalten
        - Loesung finden und beheben
        - denselben Build / dieselbe Run Configuration erneut ausfuehren
        - wenn das Problem weiter auftritt, weiter analysieren bis der Tool-Aufruf erfolgreich ist oder eine klare Blockade benannt werden kann
        """
    }

    @discardableResult
    func launchAgent(
        _ tool: AIAgentTool,
        for worktree: WorktreeRecord,
        in modelContext: ModelContext,
        initialPrompt: String? = nil
    ) -> RunRecord? {
        guard tool != .none else { return nil }

        do {
            worktree.assignedAgent = tool
            try modelContext.save()

            guard let repository = worktree.repository else {
                throw StackriotError.worktreeUnavailable
            }

            let shell = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let loginShell = (shell?.isEmpty == false ? shell! : "/bin/zsh")
            // If a prompt is provided, prefer the tool's dedicated non-interactive command when one
            // exists. Only fall back to PTY stdin injection for tools that lack an automation mode.
            let promptText = initialPrompt?.nonEmpty
            if let promptText {
                let descriptor: CommandExecutionDescriptor?
                switch tool {
                case .codex:
                    descriptor = CommandExecutionDescriptor(
                        title: tool.displayName,
                        actionKind: .aiAgent,
                        showsAgentIndicator: true,
                        executable: "codex",
                        arguments: ["exec", "--full-auto", "--json", "--color", "never", promptText],
                        displayCommandLine: "codex exec --full-auto --json --color never \(promptText.shellEscaped)",
                        currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                        repositoryID: repository.id,
                        worktreeID: worktree.id,
                        runtimeRequirement: nil,
                        stdinText: nil,
                        environment: [:],
                        usesTerminalSession: false,
                        outputInterpreter: .codexExecJSONL,
                        agentTool: tool,
                        initialPrompt: promptText
                    )
                case .claudeCode:
                    descriptor = CommandExecutionDescriptor(
                        title: tool.displayName,
                        actionKind: .aiAgent,
                        showsAgentIndicator: true,
                        executable: "claude",
                        arguments: ["-p", "--dangerously-skip-permissions", "--output-format", "stream-json", promptText],
                        displayCommandLine: "claude -p --dangerously-skip-permissions --output-format stream-json \(promptText.shellEscaped)",
                        currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                        repositoryID: repository.id,
                        worktreeID: worktree.id,
                        runtimeRequirement: nil,
                        stdinText: nil,
                        environment: [:],
                        usesTerminalSession: false,
                        outputInterpreter: .claudePrintStreamJSON,
                        agentTool: tool,
                        initialPrompt: promptText
                    )
                case .githubCopilot:
                    descriptor = CommandExecutionDescriptor(
                        title: tool.displayName,
                        actionKind: .aiAgent,
                        showsAgentIndicator: true,
                        executable: "copilot",
                        arguments: ["-p", promptText, "--allow-all-tools", "--output-format", "json"],
                        displayCommandLine: "copilot -p \(promptText.shellEscaped) --allow-all-tools --output-format json",
                        currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                        repositoryID: repository.id,
                        worktreeID: worktree.id,
                        runtimeRequirement: nil,
                        stdinText: nil,
                        environment: [:],
                        usesTerminalSession: false,
                        outputInterpreter: .copilotPromptJSONL,
                        agentTool: tool,
                        initialPrompt: promptText
                    )
                case .cursorCLI:
                    descriptor = CommandExecutionDescriptor(
                        title: tool.displayName,
                        actionKind: .aiAgent,
                        showsAgentIndicator: true,
                        executable: "cursor-agent",
                        arguments: ["--print", "--output-format", "json", "--trust", "--force", promptText],
                        displayCommandLine: "cursor-agent --print --output-format json --trust --force \(promptText.shellEscaped)",
                        currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                        repositoryID: repository.id,
                        worktreeID: worktree.id,
                        runtimeRequirement: nil,
                        stdinText: nil,
                        environment: [:],
                        usesTerminalSession: false,
                        outputInterpreter: .cursorAgentPrintJSON,
                        agentTool: tool,
                        initialPrompt: promptText
                    )
                default:
                    descriptor = nil
                }

                if let descriptor {
                    let run = startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
                    refreshRunningAgentWorktrees()
                    return run
                }
            }

            let shellCommand: String
            let stdinText: String?
            if let prompt = promptText {
                let cmd = tool.launchCommandWithPrompt(prompt, in: worktree.path)
                if cmd != tool.launchCommand(in: worktree.path) {
                    // Tool handles the prompt via flag — no PTY stdin injection needed
                    shellCommand = cmd
                    stdinText = nil
                } else {
                    // Tool uses interactive mode — inject prompt via PTY stdin
                    shellCommand = tool.launchCommand(in: worktree.path)
                    stdinText = "\(prompt)\n"
                }
            } else {
                shellCommand = tool.launchCommand(in: worktree.path)
                stdinText = nil
            }
            let descriptor = CommandExecutionDescriptor(
                title: tool.displayName,
                actionKind: .aiAgent,
                showsAgentIndicator: promptText != nil,
                executable: loginShell,
                arguments: ["-ilc", shellCommand],
                displayCommandLine: shellCommand,
                currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                repositoryID: repository.id,
                worktreeID: worktree.id,
                runtimeRequirement: nil,
                stdinText: stdinText,
                agentTool: tool,
                initialPrompt: promptText
            )
            let run = startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
            refreshRunningAgentWorktrees()
            return run
        } catch {
            pendingErrorMessage = error.localizedDescription
            return nil
        }
    }

    func launchConflictResolutionAgent(
        _ tool: AIAgentTool,
        for draft: IntegrationConflictDraft,
        in modelContext: ModelContext
    ) {
        guard
            let repository = repositoryRecord(with: draft.repositoryID),
            let defaultWorktree = worktreeRecord(with: draft.defaultWorktreeID)
        else {
            pendingErrorMessage = StackriotError.worktreeUnavailable.localizedDescription
            return
        }

        let prompt = """
        Resolve the current merge conflicts in this repository.
        Source branch: \(draft.sourceBranch)
        Target branch: \(draft.defaultBranch)
        Requirements:
        1. Resolve all merge conflicts in the current working tree.
        2. Stage the resolved files.
        3. Create the merge commit with the exact message: \(draft.commitMessage)
        4. Leave the repository in a clean state if the resolution succeeds.
        """
        pendingIntegrationConflict = nil
        selectedWorktreeIDsByRepository[repository.id] = defaultWorktree.id
        launchAgent(tool, for: defaultWorktree, in: modelContext, initialPrompt: prompt)
    }

    func assignAgent(_ tool: AIAgentTool, to worktree: WorktreeRecord, in modelContext: ModelContext) {
        worktree.assignedAgent = tool
        do {
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func isAgentRunning(for worktree: WorktreeRecord) -> Bool {
        runningAgentWorktreeIDs.contains(worktree.id)
    }

    func isAgentRunning(forRepository repository: ManagedRepository) -> Bool {
        repository.worktrees.contains { runningAgentWorktreeIDs.contains($0.id) }
    }

    func runMakeTarget(
        _ target: String,
        in worktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) {
        let descriptor = CommandExecutionDescriptor(
            title: "make \(target)",
            actionKind: .makeTarget,
            executable: "make",
            arguments: [target],
            displayCommandLine: nil,
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            runtimeRequirement: nil,
            stdinText: nil
        )
        startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
    }

    func runNPMScript(
        _ script: String,
        in worktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) {
        let descriptor = CommandExecutionDescriptor(
            title: "npm run \(script)",
            actionKind: .npmScript,
            executable: "npm",
            arguments: ["run", script],
            displayCommandLine: nil,
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            runtimeRequirement: services.nodeTooling.runtimeRequirement(for: URL(fileURLWithPath: worktree.path)),
            stdinText: nil
        )
        startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
    }

    func installDependencies(
        mode: DependencyInstallMode,
        in worktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) {
        let descriptor = services.nodeTooling.installDescriptor(for: worktree, mode: mode, repositoryID: repository.id)
        startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
    }

    func rebuildManagedNodeRuntime() {
        Task {
            await services.nodeRuntimeManager.rebuildManagedRuntime()
            nodeRuntimeStatus = await services.nodeRuntimeManager.statusSnapshot()
        }
    }

    func startAutoRefreshLoopIfNeeded() {
        guard autoRefreshTask == nil else { return }

        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = AppPreferences.autoRefreshInterval
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled {
                    return
                }
                await self.refreshAllRepositories(force: false)
            }
        }
    }

    func startNodeRuntimeRefreshLoopIfNeeded() {
        guard nodeRuntimeRefreshTask == nil else { return }

        nodeRuntimeRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = AppPreferences.nodeAutoUpdateInterval
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled {
                    return
                }
                await self.services.nodeRuntimeManager.refreshDefaultRuntimeIfNeeded(force: false)
                self.nodeRuntimeStatus = await self.services.nodeRuntimeManager.statusSnapshot()
            }
        }
    }
}
