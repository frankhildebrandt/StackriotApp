import Foundation
import SwiftData

extension AppModel {
    func requestCloseTab(_ run: RunRecord, in modelContext: ModelContext) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if let draft = await self.terminalCloseConfirmation(for: run) {
                self.pendingTerminalCloseConfirmation = draft
                return
            }

            self.forceCloseTab(run, in: modelContext)
        }
    }

    func confirmPendingTerminalClose(in modelContext: ModelContext) {
        guard
            let runID = pendingTerminalCloseConfirmation?.runID,
            let run = runRecord(with: runID)
        else {
            pendingTerminalCloseConfirmation = nil
            return
        }

        forceCloseTab(run, in: modelContext)
    }

    func cancelRun(_ run: RunRecord, in modelContext: ModelContext) {
        if let session = terminalSessions[run.id] {
            session.terminate()
            return
        }
        runningProcesses[run.id]?.cancel()
        run.status = .cancelled
        run.endedAt = .now
        activeRunIDs.remove(run.id)
        delegatedAgentRunIDs.remove(run.id)
        refreshRunningAgentWorktrees()
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
            outputInterpreter: descriptor.outputInterpreter,
            status: .running,
            worktreeID: worktree?.id,
            repository: repository,
            worktree: worktree
        )
        run.outputText = "$ \(commandLine)\n"
        repository.runs.append(run)
        modelContext.insert(run)
        if let interpreter = descriptor.outputInterpreter {
            let parser = StructuredAgentOutputParserFactory.makeParser(for: interpreter)
            structuredOutputParsersByRunID[run.id] = parser
            applyStructuredParsedChunk(parser.consume(run.outputText), to: run.id)
        }

        do {
            try modelContext.save()
            let runID = run.id
            activeRunIDs.insert(runID)
            if descriptor.actionKind == .aiAgent {
                if descriptor.showsAgentIndicator {
                    delegatedAgentRunIDs.insert(runID)
                } else {
                    delegatedAgentRunIDs.remove(runID)
                }
                refreshRunningAgentWorktrees()
            }
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
        if let parser = structuredOutputParsersByRunID[runID] {
            run.outputText += chunk
            applyStructuredParsedChunk(parser.consume(chunk), to: runID)
        } else {
            run.outputText += chunk
        }
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
        flushBufferedRunOutputIfNeeded(runID: runID)
        run.endedAt = .now
        run.exitCode = Int(exitCode)
        run.status = wasCancelled ? .cancelled : (exitCode == 0 ? .succeeded : .failed)
        activeRunIDs.remove(runID)
        delegatedAgentRunIDs.remove(runID)
        runningProcesses.removeValue(forKey: runID)
        structuredOutputParsersByRunID.removeValue(forKey: runID)
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
        if forceClosingTerminalRunIDs.remove(runID) != nil {
            terminalSessions[runID] = nil
        }
    }

    func handleRunFailure(runID: UUID, message: String) {
        guard let run = runRecord(with: runID), let modelContext = storedModelContext else { return }
        let renderedMessage = "\n\(message)\n"
        if let parser = structuredOutputParsersByRunID[runID] {
            run.outputText += renderedMessage
            applyStructuredParsedChunk(parser.consume(renderedMessage), to: runID)
        } else {
            run.outputText += renderedMessage
        }
        flushBufferedRunOutputIfNeeded(runID: runID)
        run.endedAt = .now
        run.status = .failed
        activeRunIDs.remove(runID)
        delegatedAgentRunIDs.remove(runID)
        runningProcesses.removeValue(forKey: runID)
        structuredOutputParsersByRunID.removeValue(forKey: runID)
        terminalTabs.markCompleted(runID: runID)
        scheduleAutoHideIfNeeded(for: runID)
        refreshRunningAgentWorktrees()
        save(modelContext)
        if run.actionKind == .aiAgent {
            summarizeAgentRun(runID: runID)
        }
        if forceClosingTerminalRunIDs.remove(runID) != nil {
            terminalSessions[runID] = nil
        }
    }

    func scheduleAutoHideIfNeeded(for runID: UUID) {
        cancelAutoHide(for: runID)
        guard let run = runRecord(with: runID) else { return }
        guard run.actionKind != .aiAgent else { return }

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
            if descriptor.actionKind == .aiAgent && descriptor.usesTerminalSession {
                let environment = await ShellEnvironment.resolvedEnvironment(
                    additional: [
                        "TERM": "xterm-256color",
                        "COLORTERM": "truecolor",
                        "TERM_PROGRAM": "Stackriot",
                    ],
                    overrides: descriptor.environment
                )
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
            let environment = await ShellEnvironment.resolvedEnvironment(overrides: prepared.environment)

            let handle = try CommandRunner.start(
                executable: prepared.executable,
                arguments: prepared.arguments,
                currentDirectoryURL: descriptor.currentDirectoryURL,
                environment: environment,
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
                guard delegatedAgentRunIDs.contains(runID) else { return nil }
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let run = self.runRecord(with: runID), let modelContext = self.storedModelContext else { return }
            guard run.actionKind == .aiAgent else { return }

            self.summarizingRunIDs.insert(runID)
            self.dismissedAISummaryRunIDs.remove(runID)
            defer { self.summarizingRunIDs.remove(runID) }

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

    private func flushBufferedRunOutputIfNeeded(runID: UUID) {
        guard let parser = structuredOutputParsersByRunID[runID] else { return }
        applyStructuredParsedChunk(parser.finish(), to: runID)
    }

    func structuredSegments(for run: RunRecord) -> [AgentRunSegment] {
        agentRunSegmentsByRunID[run.id] ?? []
    }

    func hasStructuredFeed(for run: RunRecord) -> Bool {
        run.outputInterpreter != nil
    }

    func ensureStructuredSegmentsLoaded(for run: RunRecord) {
        guard let interpreter = run.outputInterpreter else { return }
        guard agentRunSegmentsByRunID[run.id] == nil else { return }

        let parser = StructuredAgentOutputParserFactory.makeParser(for: interpreter)
        var segments: [AgentRunSegment] = []
        mergeStructuredSegments(parser.consume(run.outputText).segments, into: &segments)
        mergeStructuredSegments(parser.finish().segments, into: &segments)
        agentRunSegmentsByRunID[run.id] = segments
    }

    private func applyStructuredParsedChunk(_ parsedChunk: StructuredAgentOutputChunk, to runID: UUID) {
        guard !parsedChunk.segments.isEmpty else { return }
        var segments = agentRunSegmentsByRunID[runID] ?? []
        mergeStructuredSegments(parsedChunk.segments, into: &segments)
        agentRunSegmentsByRunID[runID] = segments
    }

    private func mergeStructuredSegments(_ newSegments: [AgentRunSegment], into existingSegments: inout [AgentRunSegment]) {
        for segment in newSegments {
            if let index = existingSegments.firstIndex(where: { $0.id == segment.id }) {
                existingSegments[index] = segment
            } else {
                existingSegments.append(segment)
            }
        }
    }

    private func forceCloseTab(_ run: RunRecord, in modelContext: ModelContext) {
        pendingTerminalCloseConfirmation = nil
        cancelAutoHide(for: run.id)
        terminalTabs.hide(runID: run.id)

        if let session = terminalSessions[run.id] {
            if activeRunIDs.contains(run.id) {
                forceClosingTerminalRunIDs.insert(run.id)
                session.forceTerminate()
            } else {
                session.forceTerminate()
                terminalSessions[run.id] = nil
            }
            return
        }

        if activeRunIDs.contains(run.id) {
            cancelRun(run, in: modelContext)
            return
        }

        terminalSessions[run.id] = nil
    }

    private func terminalCloseConfirmation(for run: RunRecord) async -> TerminalCloseConfirmationDraft? {
        guard activeRunIDs.contains(run.id) else { return nil }

        if run.actionKind == .aiAgent {
            return TerminalCloseConfirmationDraft(
                runID: run.id,
                title: "Agent schließen?",
                message: "Der Agent läuft noch. Schließen beendet den Agenten sofort und killt die laufende Session."
            )
        }

        guard let session = terminalSessions[run.id] else { return nil }
        let descendants = await session.runningDescendantProcesses()
        guard !descendants.isEmpty else { return nil }

        let preview = descendants.prefix(3).joined(separator: ", ")
        let suffix = descendants.count > 3 ? " und weitere" : ""
        return TerminalCloseConfirmationDraft(
            runID: run.id,
            title: "Terminal mit laufendem Prozess schließen?",
            message: "Unter dieser Shell laufen noch Prozesse (\(preview)\(suffix)). Schließen beendet die Shell und alle Unterprozesse sofort."
        )
    }
}
