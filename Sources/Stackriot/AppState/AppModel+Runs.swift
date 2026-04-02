import Foundation
import SwiftData

actor RunOutputThrottle {
    typealias Delivery = @MainActor @Sendable (String) -> Void

    private let interval: Duration
    private var bufferedChunks: [UUID: String] = [:]
    private var scheduledFlushes: [UUID: Task<Void, Never>] = [:]

    init(interval: Duration = .milliseconds(50)) {
        self.interval = interval
    }

    func enqueue(_ chunk: String, for runID: UUID, deliver: @escaping Delivery) {
        guard !chunk.isEmpty else { return }
        bufferedChunks[runID, default: ""] += chunk
        guard scheduledFlushes[runID] == nil else { return }

        scheduledFlushes[runID] = Task { [interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await flush(runID: runID, deliver: deliver)
        }
    }

    func flush(runID: UUID, deliver: @escaping Delivery) async {
        scheduledFlushes[runID]?.cancel()
        scheduledFlushes[runID] = nil
        guard let merged = bufferedChunks.removeValue(forKey: runID), !merged.isEmpty else { return }
        await deliver(merged)
    }

    func cancel(runID: UUID) {
        scheduledFlushes[runID]?.cancel()
        scheduledFlushes.removeValue(forKey: runID)
        bufferedChunks.removeValue(forKey: runID)
    }
}

actor RawLogAppendCoordinator {
    private let fileManager = FileManager.default
    private var handlesByRunID: [UUID: FileHandle] = [:]

    func register(runID: UUID, logURL: URL) throws {
        guard handlesByRunID[runID] == nil else { return }
        handlesByRunID[runID] = try FileHandle(forWritingTo: logURL)
    }

    func append(_ chunk: String, runID: UUID, logURL: URL) throws {
        guard !chunk.isEmpty else { return }
        let handle = try fileHandle(for: runID, logURL: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(chunk.utf8))
    }

    func finalize(runID: UUID, logURL: URL) throws -> Int64 {
        if let handle = handlesByRunID.removeValue(forKey: runID) {
            try handle.synchronize()
            try handle.close()
        }
        let attributes = try fileManager.attributesOfItem(atPath: logURL.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    func close(runID: UUID) {
        guard let handle = handlesByRunID.removeValue(forKey: runID) else { return }
        try? handle.close()
    }

    private func fileHandle(for runID: UUID, logURL: URL) throws -> FileHandle {
        if let existing = handlesByRunID[runID] {
            return existing
        }

        let handle = try FileHandle(forWritingTo: logURL)
        handlesByRunID[runID] = handle
        return handle
    }
}

extension AppModel {
    func requestCloseTab(_ run: RunRecord, in modelContext: ModelContext) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if let draft = await self.terminalCloseConfirmation(for: run) {
                self.notifyOperationSuccess(
                    title: "Terminal force-closed",
                    subtitle: run.title,
                    body: draft.message,
                    userInfo: ["runID": run.id.uuidString]
                )
            }

            self.forceCloseTab(run, in: modelContext)
        }
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
                rawLogFileURLsByRunID[runID] = rawLogRecord.logFileURL
                Task {
                    try? await rawLogAppendCoordinator.register(runID: runID, logURL: rawLogRecord.logFileURL)
                }
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
                selectedWorktreeIDsByRepository[repository.id] = worktree.id
                if descriptor.activatesTerminalTab {
                    terminalTabs.deselectPlanTab(for: worktree.id)
                    terminalTabs.activate(runID: runID, worktreeID: worktree.id)
                } else {
                    terminalTabs.showInBackground(runID: runID, worktreeID: worktree.id)
                }
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
                rawLogFileURLsByRunID[run.id] = rawLogRecord.logFileURL
                Task {
                    try? await rawLogAppendCoordinator.register(runID: run.id, logURL: rawLogRecord.logFileURL)
                }
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

    func handleRunTermination(runID: UUID, exitCode: Int32, wasCancelled: Bool) async {
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
        await finalizeRawLogIfNeeded(runID: runID, endedAt: endedAt, status: finalStatus)
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

    func handleRunFailure(runID: UUID, message: String) async {
        guard let run = runRecord(with: runID), let modelContext = storedModelContext else { return }
        let renderedMessage = "\n\(message)\n"
        flushPendingRunOutput(runID: runID)
        await flushRawLogBufferForFinalization(runID: runID)
        await writeRawLogChunkToDisk(runID: runID, chunk: renderedMessage)
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
        await finalizeRawLogIfNeeded(runID: runID, endedAt: endedAt, status: .failed)
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
        run.actionKind == .aiAgent || run.actionKind == .devContainer || run.isFixableBuildFailure
    }

    func cancelAutoHide(for runID: UUID) {
        terminalTabAutoHideTasks[runID]?.cancel()
        terminalTabAutoHideTasks.removeValue(forKey: runID)
    }

    func launchRun(runID: UUID, descriptor: CommandExecutionDescriptor) async {
        do {
            let deliverBufferedOutput: RunOutputThrottle.Delivery = { [weak self] merged in
                guard let self else { return }
                self.handleRunOutput(runID: runID, chunk: merged)
            }

            if descriptor.usesTerminalSession {
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
                        guard let self else { return }
                        Task {
                            await self.incomingRunOutputThrottle.enqueue(chunk, for: runID, deliver: deliverBufferedOutput)
                        }
                    },
                    onTermination: { [weak self] exitCode, wasCancelled in
                        guard let self else { return }
                        Task {
                            await self.incomingRunOutputThrottle.flush(runID: runID, deliver: deliverBufferedOutput)
                            await self.handleRunTermination(runID: runID, exitCode: exitCode, wasCancelled: wasCancelled)
                        }
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
                    guard let self else { return }
                    Task {
                        await self.incomingRunOutputThrottle.enqueue(chunk, for: runID, deliver: deliverBufferedOutput)
                    }
                },
                onTermination: { [weak self] exitCode, wasCancelled in
                    Task { @MainActor in
                        guard let self else { return }
                        await self.incomingRunOutputThrottle.flush(runID: runID, deliver: deliverBufferedOutput)
                        await self.handleRunTermination(runID: runID, exitCode: exitCode, wasCancelled: wasCancelled)
                    }
                }
            )

            runningProcesses[runID] = handle
        } catch {
            nodeRuntimeStatus = await services.nodeRuntimeManager.statusSnapshot()
            await handleRunFailure(runID: runID, message: error.localizedDescription)
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
        guard let modelContext = storedModelContext else { return }
        let repositories = (try? modelContext.fetch(FetchDescriptor<ManagedRepository>())) ?? []
        for repository in repositories {
            refreshRepositorySidebarSnapshot(for: repository)
            refreshRepositoryDetailSnapshot(for: repository)
        }
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
        Task {
            await writeRawLogChunkToDisk(runID: runID, chunk: text)
        }
    }

    private func flushRawLogBufferForFinalization(runID: UUID) async {
        rawLogFlushTasks[runID]?.cancel()
        rawLogFlushTasks[runID] = nil
        guard let text = rawLogDiskBuffer.removeValue(forKey: runID), !text.isEmpty else { return }
        await writeRawLogChunkToDisk(runID: runID, chunk: text)
    }

    private func writeRawLogChunkToDisk(runID: UUID, chunk: String) async {
        guard let logURL = rawLogFileURLsByRunID[runID] else { return }
        do {
            try await rawLogAppendCoordinator.append(chunk, runID: runID, logURL: logURL)
        } catch {
            pendingErrorMessage = "RAW log archive could not be updated: \(error.localizedDescription)"
        }
    }

    private func finalizeRawLogIfNeeded(runID: UUID, endedAt: Date, status: RunStatusKind) async {
        await flushRawLogBufferForFinalization(runID: runID)
        guard let record = rawLogRecordForRunID(runID) else { return }
        do {
            if let logURL = rawLogFileURLsByRunID[runID] {
                record.fileSize = try await rawLogAppendCoordinator.finalize(runID: runID, logURL: logURL)
            }
            try services.rawLogArchive.finalize(record, endedAt: endedAt, status: status)
        } catch {
            pendingErrorMessage = "RAW log archive could not be finalized: \(error.localizedDescription)"
        }
        rawLogRecordIDsByRunID.removeValue(forKey: runID)
        rawLogFileURLsByRunID.removeValue(forKey: runID)
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
