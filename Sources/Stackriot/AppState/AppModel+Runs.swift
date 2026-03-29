import Foundation
import SwiftData

extension AppModel {
    func cancelRun(_ run: RunRecord, in modelContext: ModelContext) {
        if let session = terminalSessions[run.id] {
            session.terminate()
            return
        }
        runningProcesses[run.id]?.cancel()
        run.status = .cancelled
        run.endedAt = .now
        activeRunIDs.remove(run.id)
        save(modelContext)
    }

    func terminalSession(for run: RunRecord) -> AgentTerminalSession? {
        terminalSessions[run.id]
    }

    func startRun(
        _ descriptor: CommandExecutionDescriptor,
        repository: ManagedRepository,
        worktree: WorktreeRecord?,
        modelContext: ModelContext
    ) {
        let commandLine = descriptor.displayCommandLine ?? ([descriptor.executable] + descriptor.arguments).joined(separator: " ")
        let run = RunRecord(
            actionKind: descriptor.actionKind,
            title: descriptor.title,
            commandLine: commandLine,
            status: .running,
            worktreeID: worktree?.id,
            repository: repository,
            worktree: worktree
        )
        run.outputText = "$ \(commandLine)\n"
        repository.runs.append(run)
        modelContext.insert(run)

        do {
            try modelContext.save()
            let runID = run.id
            activeRunIDs.insert(runID)
            if let worktree {
                terminalTabs.deselectPlanTab(for: worktree.id)
                terminalTabs.activate(runID: runID, worktreeID: worktree.id)
                selectedWorktreeIDsByRepository[repository.id] = worktree.id
            }
            Task { [weak self] in
                await self?.launchRun(runID: runID, descriptor: descriptor)
            }
        } catch {
            modelContext.delete(run)
            pendingErrorMessage = error.localizedDescription
        }
    }

    func handleRunOutput(runID: UUID, chunk: String) {
        guard let run = runRecord(with: runID) else { return }
        run.outputText += chunk
        guard
            run.actionKind == .aiAgent,
            let repositoryID = run.repository?.id,
            let worktreeID = run.worktree?.id,
            selectedRepositoryID == repositoryID,
            selectedWorktreeIDsByRepository[repositoryID] == worktreeID
        else {
            return
        }

        terminalTabs.activate(runID: runID, worktreeID: worktreeID)
    }

    func handleRunTermination(runID: UUID, exitCode: Int32, wasCancelled: Bool) {
        guard let run = runRecord(with: runID), let modelContext = storedModelContext else { return }
        run.endedAt = .now
        run.exitCode = Int(exitCode)
        run.status = wasCancelled ? .cancelled : (exitCode == 0 ? .succeeded : .failed)
        activeRunIDs.remove(runID)
        runningProcesses.removeValue(forKey: runID)
        terminalTabs.markCompleted(runID: runID)
        scheduleAutoHideIfNeeded(for: runID)
        refreshRunningAgentWorktrees()
        if run.actionKind == .gitOperation, let repository = run.repository {
            Task { [weak self] in
                await self?.refreshWorktreeStatuses(for: repository)
            }
        }
        save(modelContext)
        if run.actionKind == .aiAgent {
            summarizeAgentRun(runID: runID)
        }
    }

    func handleRunFailure(runID: UUID, message: String) {
        guard let run = runRecord(with: runID), let modelContext = storedModelContext else { return }
        run.outputText += "\n\(message)\n"
        run.endedAt = .now
        run.status = .failed
        activeRunIDs.remove(runID)
        runningProcesses.removeValue(forKey: runID)
        terminalTabs.markCompleted(runID: runID)
        scheduleAutoHideIfNeeded(for: runID)
        refreshRunningAgentWorktrees()
        save(modelContext)
        if run.actionKind == .aiAgent {
            summarizeAgentRun(runID: runID)
        }
    }

    func scheduleAutoHideIfNeeded(for runID: UUID) {
        cancelAutoHide(for: runID)

        let mode = AppPreferences.terminalTabRetentionMode
        switch mode {
        case .manualClose:
            return
        case .runningOnly:
            terminalTabs.hide(runID: runID)
        case .shortRetain:
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.terminalTabs.hide(runID: runID)
                    self?.terminalTabAutoHideTasks.removeValue(forKey: runID)
                }
            }
            terminalTabAutoHideTasks[runID] = task
        }
    }

    func cancelAutoHide(for runID: UUID) {
        terminalTabAutoHideTasks[runID]?.cancel()
        terminalTabAutoHideTasks.removeValue(forKey: runID)
    }

    func launchRun(runID: UUID, descriptor: CommandExecutionDescriptor) async {
        do {
            if descriptor.actionKind == .aiAgent {
                let environment = ProcessInfo.processInfo.environment.merging(
                    [
                        "PATH": await ShellEnvironment.loginShellPath(),
                        "TERM": "xterm-256color",
                        "COLORTERM": "truecolor",
                        "TERM_PROGRAM": "Stackriot",
                    ]
                ) { _, new in new }
                .merging(descriptor.environment) { _, new in new }
                let session = AgentTerminalSession(
                    runID: runID,
                    onData: { [weak self] chunk in
                        self?.handleRunOutput(runID: runID, chunk: chunk)
                    },
                    onTermination: { [weak self] exitCode, wasCancelled in
                        self?.handleRunTermination(runID: runID, exitCode: exitCode, wasCancelled: wasCancelled)
                    }
                )
                terminalSessions[runID] = session
                session.start(
                    executable: descriptor.executable,
                    arguments: descriptor.arguments,
                    environment: environment,
                    currentDirectory: descriptor.currentDirectoryURL?.path
                )
                if let stdinText = descriptor.stdinText?.nonEmpty {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(700))
                        session.send(text: stdinText)
                    }
                }
                return
            }

            if descriptor.runtimeRequirement != nil {
                handleRunOutput(runID: runID, chunk: "[stackriot] Preparing managed Node runtime…\n")
            }

            let prepared = try await services.nodeRuntimeManager.prepareExecution(for: descriptor)
            nodeRuntimeStatus = await services.nodeRuntimeManager.statusSnapshot()

            let handle = try CommandRunner.start(
                executable: prepared.executable,
                arguments: prepared.arguments,
                currentDirectoryURL: descriptor.currentDirectoryURL,
                environment: prepared.environment,
                onOutput: { [weak self] chunk in
                    Task { @MainActor in
                        guard let self else { return }
                        self.handleRunOutput(runID: runID, chunk: chunk)
                    }
                },
                onTermination: { [weak self] exitCode, wasCancelled in
                    Task { @MainActor in
                        guard let self else { return }
                        self.handleRunTermination(runID: runID, exitCode: exitCode, wasCancelled: wasCancelled)
                    }
                }
            )

            runningProcesses[runID] = handle
        } catch {
            nodeRuntimeStatus = await services.nodeRuntimeManager.statusSnapshot()
            handleRunFailure(runID: runID, message: error.localizedDescription)
        }
    }

    func refreshRunningAgentWorktrees() {
        runningAgentWorktreeIDs = Set(
            activeRunIDs.compactMap { runID in
                guard let run = runRecord(with: runID), run.actionKind == .aiAgent else {
                    return nil
                }
                return run.worktree?.id
            }
        )
    }

    func dismissAISummary(for run: RunRecord) {
        dismissedAISummaryRunIDs.insert(run.id)
    }

    func shouldShowAISummary(for run: RunRecord) -> Bool {
        guard run.actionKind == .aiAgent else { return false }
        guard !dismissedAISummaryRunIDs.contains(run.id) else { return false }
        return summarizingRunIDs.contains(run.id) || run.aiSummaryText?.nonEmpty != nil
    }

    private func summarizeAgentRun(runID: UUID) {
        guard !summarizingRunIDs.contains(runID) else { return }
        summarizingRunIDs.insert(runID)
        dismissedAISummaryRunIDs.remove(runID)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.summarizingRunIDs.remove(runID) }
            guard let run = self.runRecord(with: runID), let modelContext = self.storedModelContext else { return }

            do {
                let summary = try await self.services.aiProviderService.summarizeAgentRun(
                    title: run.title,
                    commandLine: run.commandLine,
                    output: run.outputText,
                    exitCode: run.exitCode
                )
                run.aiSummaryTitle = summary.title
                run.aiSummaryText = summary.summary
            } catch {
                let fallback = self.services.aiProviderService.fallbackRunSummary(
                    title: run.title,
                    commandLine: run.commandLine,
                    output: run.outputText,
                    exitCode: run.exitCode
                )
                run.aiSummaryTitle = fallback.title
                run.aiSummaryText = fallback.summary
                self.pendingErrorMessage = "AI run summary failed: \(error.localizedDescription)"
            }
            self.save(modelContext)
        }
    }
}
