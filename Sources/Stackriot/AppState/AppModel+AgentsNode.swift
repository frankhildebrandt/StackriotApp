import Foundation
import SwiftData

extension AppModel {
    func availableMakeTargets(for worktree: WorktreeRecord) -> [String] {
        services.makeTooling.discoverTargets(in: URL(fileURLWithPath: worktree.path))
    }

    func availableNPMScripts(for worktree: WorktreeRecord) -> [String] {
        services.nodeTooling.discoverScripts(in: URL(fileURLWithPath: worktree.path))
    }

    func openIDE(_ ide: SupportedIDE, for worktree: WorktreeRecord, in modelContext: ModelContext) async {
        do {
            try await services.ideManager.open(ide, path: URL(fileURLWithPath: worktree.path))
            worktree.lastOpenedAt = .now
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
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

    func launchAgent(
        _ tool: AIAgentTool,
        for worktree: WorktreeRecord,
        in modelContext: ModelContext,
        initialPrompt: String? = nil
    ) {
        guard tool != .none else { return }

        do {
            worktree.assignedAgent = tool
            try modelContext.save()

            guard let repository = worktree.repository else {
                throw StackriotError.worktreeUnavailable
            }

            let shell = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let loginShell = (shell?.isEmpty == false ? shell! : "/bin/zsh")
            // If a prompt is provided, prefer the tool's dedicated prompt-flag command (e.g. `copilot -p`)
            // which exits cleanly after completion. For tools without a prompt flag the interactive
            // launch command is used and the prompt is written to PTY stdin as before.
            let promptText = initialPrompt?.nonEmpty
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
                executable: loginShell,
                arguments: ["-ilc", shellCommand],
                displayCommandLine: shellCommand,
                currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                repositoryID: repository.id,
                worktreeID: worktree.id,
                runtimeRequirement: nil,
                stdinText: stdinText
            )
            startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
            refreshRunningAgentWorktrees()
        } catch {
            pendingErrorMessage = error.localizedDescription
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
