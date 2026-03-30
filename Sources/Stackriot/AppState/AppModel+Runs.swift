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
        if run.isTransientPlanRun, let worktreeID = run.worktree?.id {
            cancelAgentPlanDraft(for: worktreeID)
            return
        }
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

    @discardableResult
    func startRun(
        _ descriptor: CommandExecutionDescriptor,
        repository: ManagedRepository,
        worktree: WorktreeRecord?,
        modelContext: ModelContext
    ) -> RunRecord? {
        let commandLine = descriptor.displayCommandLine ?? ([descriptor.executable] + descriptor.arguments).joined(separator: " ")
        let run = RunRecord(
            actionKind: descriptor.actionKind,
            title: descriptor.title,
            commandLine: commandLine,
            outputInterpreter: descriptor.outputInterpreter,
            status: .running,
            worktreeID: worktree?.id,
            runConfigurationID: descriptor.runConfigurationID,
            repository: repository,
            worktree: worktree
        )
        run.outputText = "$ \(commandLine)\n"

        let rawLogRecord: AgentRawLogRecord?
        do {
            rawLogRecord = try prepareRawLogRecordIfNeeded(
                for: run,
                descriptor: descriptor,
                repository: repository,
                worktree: worktree,
                initialOutput: run.outputText,
                modelContext: modelContext
            )
        } catch {
            pendingErrorMessage = "RAW log archive could not be created: \(error.localizedDescription)"
            return nil
        }

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
            if let rawLogRecord {
                rawLogRecordIDsByRunID[runID] = rawLogRecord.id
            }
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
            return run
        } catch {
            if let rawLogRecord {
                try? services.rawLogArchive.delete(rawLogRecord)
                modelContext.delete(rawLogRecord)
            }
            modelContext.delete(run)
            pendingErrorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func startTransientRun(
        _ descriptor: CommandExecutionDescriptor,
        repository: ManagedRepository,
        worktree: WorktreeRecord?,
        isTransientPlanRun: Bool = false
    ) -> RunRecord? {
        guard let modelContext = storedModelContext else {
            pendingErrorMessage = "The model context is unavailable."
            return nil
        }
        let commandLine = descriptor.displayCommandLine ?? ([descriptor.executable] + descriptor.arguments).joined(separator: " ")
        let run = RunRecord(
            actionKind: descriptor.actionKind,
            title: descriptor.title,
            commandLine: commandLine,
            outputInterpreter: descriptor.outputInterpreter,
            status: .running,
            worktreeID: worktree?.id,
            runConfigurationID: descriptor.runConfigurationID,
            repository: repository,
            worktree: worktree
        )
        run.isTransientPlanRun = isTransientPlanRun
        run.outputText = "$ \(commandLine)\n"

        let rawLogRecord: AgentRawLogRecord?
        do {
            rawLogRecord = try prepareRawLogRecordIfNeeded(
                for: run,
                descriptor: descriptor,
                repository: repository,
                worktree: worktree,
                initialOutput: run.outputText,
                modelContext: modelContext
            )
            if let rawLogRecord {
                try modelContext.save()
                rawLogRecordIDsByRunID[run.id] = rawLogRecord.id
            }
        } catch {
            pendingErrorMessage = "RAW log archive could not be created: \(error.localizedDescription)"
            return nil
        }

        if let interpreter = descriptor.outputInterpreter {
            let parser = StructuredAgentOutputParserFactory.makeParser(for: interpreter)
            structuredOutputParsersByRunID[run.id] = parser
            applyStructuredParsedChunk(parser.consume(run.outputText), to: run.id)
        }

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

        Task { [weak self] in
            await self?.launchRun(runID: runID, descriptor: descriptor)
        }

        return run
    }

    func handleRunOutput(runID: UUID, chunk: String) {
        guard let run = runRecord(with: runID) else { return }

        if run.isTransientPlanRun {
            appendRawLogChunkBuffered(runID: runID, chunk: chunk)
            if let parser = structuredOutputParsersByRunID[runID] {
                run.outputText += chunk
                applyStructuredParsedChunk(parser.consume(chunk), to: runID)
                syncAgentPlanSessionID(forRunID: runID)
            } else {
                run.outputText += chunk
            }
            importCompletedAgentPlanIfAvailable(forRunID: runID)
            return
        }

        appendRawLogChunkBuffered(runID: runID, chunk: chunk)
        pendingRunOutputBuffer[runID, default: ""] += chunk
        scheduleRunOutputFlush(runID: runID)
    }

    func handleRunTermination(runID: UUID, exitCode: Int32, wasCancelled: Bool) {
        guard let run = runRecord(with: runID), let modelContext = storedModelContext else { return }
        flushPendingRunOutput(runID: runID)
        flushBufferedRunOutputIfNeeded(runID: runID)
        if run.isTransientPlanRun {
            syncAgentPlanSessionID(forRunID: runID)
        }
        let endedAt = Date.now
        run.endedAt = endedAt
        run.exitCode = Int(exitCode)
        let finalStatus: RunStatusKind = wasCancelled ? .cancelled : (exitCode == 0 ? .succeeded : .failed)
        run.status = finalStatus
        notifyRunCompletionIfNeeded(run)
        finalizeRawLogIfNeeded(runID: runID, endedAt: endedAt, status: finalStatus)
        activeRunIDs.remove(runID)
        delegatedAgentRunIDs.remove(runID)
        runningProcesses.removeValue(forKey: runID)
        structuredOutputParsersByRunID.removeValue(forKey: runID)
        refreshRunningAgentWorktrees()

        if run.isTransientPlanRun {
            importCompletedAgentPlanIfAvailable(forRunID: runID)
            if let (worktreeID, draft) = agentPlanDraftEntry(forRunID: runID),
               draft.didImportPlan || draft.requestedSessionTermination {
                cleanupAgentPlanDraft(for: worktreeID)
            } else {
                terminalSessions[runID] = nil
            }
            return
        }
        terminalTabs.markCompleted(runID: runID)
        scheduleAutoHideIfNeeded(for: runID)
        if run.actionKind == .gitOperation, let repository = run.repository {
            Task { [weak self] in
                await self?.refreshWorktreeStatuses(for: repository)
            }
        }
        save(modelContext)
        if run.actionKind == .aiAgent {
            summarizeAgentRun(runID: runID)
        }
        completePendingRunFixIfNeeded(afterAgentRunID: runID, succeeded: !wasCancelled && exitCode == 0)
        if forceClosingTerminalRunIDs.remove(runID) != nil {
            terminalSessions[runID] = nil
        }
    }

    func handleRunFailure(runID: UUID, message: String) {
        guard let run = runRecord(with: runID), let modelContext = storedModelContext else { return }
        let renderedMessage = "\n\(message)\n"
        flushPendingRunOutput(runID: runID)
        flushRawLogBuffer(for: runID)
        writeRawLogChunkToDisk(runID: runID, chunk: renderedMessage)
        if let parser = structuredOutputParsersByRunID[runID] {
            run.outputText += renderedMessage
            applyStructuredParsedChunk(parser.consume(renderedMessage), to: runID)
            if run.isTransientPlanRun {
                syncAgentPlanSessionID(forRunID: runID)
            }
        } else {
            run.outputText += renderedMessage
        }
        flushBufferedRunOutputIfNeeded(runID: runID)
        let endedAt = Date.now
        run.endedAt = endedAt
        run.status = .failed
        notifyRunCompletionIfNeeded(run, failureMessage: message)
        finalizeRawLogIfNeeded(runID: runID, endedAt: endedAt, status: .failed)
        activeRunIDs.remove(runID)
        delegatedAgentRunIDs.remove(runID)
        runningProcesses.removeValue(forKey: runID)
        structuredOutputParsersByRunID.removeValue(forKey: runID)
        refreshRunningAgentWorktrees()

        if run.isTransientPlanRun {
            if let (worktreeID, draft) = agentPlanDraftEntry(forRunID: runID),
               draft.requestedSessionTermination {
                cleanupAgentPlanDraft(for: worktreeID)
            } else {
                terminalSessions[runID] = nil
            }
            return
        }
        terminalTabs.markCompleted(runID: runID)
        scheduleAutoHideIfNeeded(for: runID)
        save(modelContext)
        if run.actionKind == .aiAgent {
            summarizeAgentRun(runID: runID)
        }
        completePendingRunFixIfNeeded(afterAgentRunID: runID, succeeded: false)
        if forceClosingTerminalRunIDs.remove(runID) != nil {
            terminalSessions[runID] = nil
        }
    }

    func scheduleAutoHideIfNeeded(for runID: UUID) {
        cancelAutoHide(for: runID)
        guard let run = runRecord(with: runID) else { return }
        let mode = AppPreferences.terminalTabRetentionMode
        guard shouldAutoHideCompletedRun(run, retentionMode: mode) else { return }
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

    func shouldAutoHideCompletedRun(
        _ run: RunRecord,
        retentionMode: TerminalTabRetentionMode = AppPreferences.terminalTabRetentionMode
    ) -> Bool {
        switch retentionMode {
        case .manualClose:
            false
        case .runningOnly, .shortRetain:
            !shouldKeepCompletedRunVisible(run)
        }
    }

    func shouldKeepCompletedRunVisible(_ run: RunRecord) -> Bool {
        run.actionKind == .aiAgent || run.isFixableBuildFailure
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

    private func prepareRawLogRecordIfNeeded(
        for run: RunRecord,
        descriptor: CommandExecutionDescriptor,
        repository: ManagedRepository,
        worktree: WorktreeRecord?,
        initialOutput: String,
        modelContext: ModelContext
    ) throws -> AgentRawLogRecord? {
        guard descriptor.agentTool != nil else { return nil }
        let record = try services.rawLogArchive.createRecord(
            runID: run.id,
            descriptor: descriptor,
            repository: repository,
            worktree: worktree,
            startedAt: run.startedAt,
            initialOutput: initialOutput
        )
        modelContext.insert(record)
        return record
    }

    private enum RunOutputBuffering {
        static let flushInterval: Duration = .milliseconds(75)
        static let rawLogMaxBufferChars = 256 * 1024
        static let rawLogFlushInterval: Duration = .milliseconds(250)
    }

    private func scheduleRunOutputFlush(runID: UUID) {
        runOutputFlushTasks[runID]?.cancel()
        runOutputFlushTasks[runID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: RunOutputBuffering.flushInterval)
            guard !Task.isCancelled else { return }
            self?.performRunOutputFlush(runID: runID)
        }
    }

    private func performRunOutputFlush(runID: UUID) {
        mergePendingRunOutput(runID: runID, activateTerminal: true)
    }

    private func flushPendingRunOutput(runID: UUID) {
        mergePendingRunOutput(runID: runID, activateTerminal: false)
    }

    private func mergePendingRunOutput(runID: UUID, activateTerminal: Bool) {
        runOutputFlushTasks[runID]?.cancel()
        runOutputFlushTasks[runID] = nil
        guard let merged = pendingRunOutputBuffer.removeValue(forKey: runID), !merged.isEmpty else { return }
        guard let run = runRecord(with: runID) else { return }
        if let parser = structuredOutputParsersByRunID[runID] {
            run.outputText += merged
            applyStructuredParsedChunk(parser.consume(merged), to: runID)
        } else {
            run.outputText += merged
        }
        guard activateTerminal else { return }
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

    private func appendRawLogChunkBuffered(runID: UUID, chunk: String) {
        guard rawLogRecordIDsByRunID[runID] != nil else { return }
        rawLogDiskBuffer[runID, default: ""] += chunk
        if rawLogDiskBuffer[runID]!.utf16.count >= RunOutputBuffering.rawLogMaxBufferChars {
            flushRawLogBuffer(for: runID)
        } else {
            scheduleRawLogFlush(runID: runID)
        }
    }

    private func scheduleRawLogFlush(runID: UUID) {
        rawLogFlushTasks[runID]?.cancel()
        rawLogFlushTasks[runID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: RunOutputBuffering.rawLogFlushInterval)
            guard !Task.isCancelled else { return }
            self?.flushRawLogBuffer(for: runID)
            self?.rawLogFlushTasks.removeValue(forKey: runID)
        }
    }

    private func flushRawLogBuffer(for runID: UUID) {
        rawLogFlushTasks[runID]?.cancel()
        rawLogFlushTasks[runID] = nil
        guard let text = rawLogDiskBuffer.removeValue(forKey: runID), !text.isEmpty else { return }
        writeRawLogChunkToDisk(runID: runID, chunk: text)
    }

    private func writeRawLogChunkToDisk(runID: UUID, chunk: String) {
        guard let record = rawLogRecordForRunID(runID) else { return }
        do {
            try services.rawLogArchive.append(chunk, to: record)
        } catch {
            pendingErrorMessage = "RAW log archive could not be updated: \(error.localizedDescription)"
        }
    }

    private func finalizeRawLogIfNeeded(runID: UUID, endedAt: Date, status: RunStatusKind) {
        flushRawLogBuffer(for: runID)
        defer {
            rawLogRecordIDsByRunID.removeValue(forKey: runID)
        }
        guard let record = rawLogRecordForRunID(runID) else { return }
        do {
            try services.rawLogArchive.finalize(record, endedAt: endedAt, status: status)
        } catch {
            pendingErrorMessage = "RAW log archive could not be finalized: \(error.localizedDescription)"
        }
    }

    private func rawLogRecordForRunID(_ runID: UUID) -> AgentRawLogRecord? {
        guard let recordID = rawLogRecordIDsByRunID[runID], let modelContext = storedModelContext else {
            return nil
        }
        let descriptor = FetchDescriptor<AgentRawLogRecord>(predicate: #Predicate { $0.id == recordID })
        return try? modelContext.fetch(descriptor).first
    }

    func structuredSegments(for run: RunRecord) -> [AgentRunSegment] {
        agentRunSegmentsByRunID[run.id] ?? []
    }

    func hasStructuredFeed(for run: RunRecord) -> Bool {
        run.outputInterpreter != nil
    }

    /// Opens a read-only markdown window with the Cursor assistant reply when the run reaches a terminal status (once per run).
    func presentCursorAgentMarkdownSnapshotIfNeeded(for run: RunRecord) {
        guard run.outputInterpreter == .cursorAgentPrintJSON else { return }
        switch run.status {
        case .succeeded, .failed, .cancelled:
            break
        default:
            return
        }
        guard !deliveredCursorAgentMarkdownSnapshotRunIDs.contains(run.id) else { return }
        let segments = agentRunSegmentsByRunID[run.id] ?? []
        let text = segments
            .filter { $0.kind == .agentMessage }
            .map { $0.bodyText ?? "" }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        deliveredCursorAgentMarkdownSnapshotRunIDs.insert(run.id)
        pendingAgentMarkdownWindowPayload = AgentMarkdownWindowPayload(
            id: UUID(),
            title: run.title,
            markdown: text
        )
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
