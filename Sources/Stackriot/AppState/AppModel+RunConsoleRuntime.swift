import AppKit
import Foundation
import OSLog
import SwiftData

extension AppModel {
    /// Graceful PTY stop (Ctrl+C) followed by hard kill is bounded by this window before `forceTerminate`.
    private static let rerunInterruptWaitDuration: Duration = .seconds(2)
    private static let rerunPostForceSettleDuration: Duration = .milliseconds(400)

    func supportsRunConsoleRuntimeTools(for run: RunRecord) -> Bool {
        guard !run.isTransientPlanRun else { return false }
        guard run.runConfigurationID?.nonEmpty != nil else { return false }
        guard let worktreeID = run.worktreeID, worktreeRecord(with: worktreeID) != nil else { return false }
        guard run.repository != nil else { return false }
        return true
    }

    func supportsSessionRecorder(for run: RunRecord) -> Bool {
        guard supportsRunConsoleRuntimeTools(for: run) else { return false }
        guard let repository = run.repository, let project = repository.project else { return false }
        return project.documentationRepository != nil
    }

    func sessionRecorderLogFileURL(for run: RunRecord) -> URL? {
        runSessionLogFileURLByRunID[run.id]
    }

    func isSessionRecordingActive(for run: RunRecord) -> Bool {
        activeSessionRecordingRunIDs.contains(run.id)
    }

    /// Builds a fresh execution descriptor for a stored run configuration ID (replay / fix-with-AI retry).
    func executionDescriptorForRunConfiguration(
        runConfigurationID: String,
        worktree: WorktreeRecord,
        repository: ManagedRepository
    ) -> CommandExecutionDescriptor? {
        let configurations = availableRunConfigurations(for: worktree)
        guard let configuration = configurations.first(where: { $0.id == runConfigurationID }) else {
            return nil
        }
        let availableTools = Set(availableDevTools(for: worktree))
        return services.runConfigurationDiscovery.makeExecutionDescriptor(
            for: configuration,
            worktree: worktree,
            repositoryID: repository.id,
            availableTools: availableTools
        )
    }

    func replayRunConfigurationContext(for run: RunRecord) -> (
        repository: ManagedRepository,
        worktree: WorktreeRecord,
        descriptor: CommandExecutionDescriptor
    )? {
        guard let runConfigurationID = run.runConfigurationID?.nonEmpty else { return nil }
        guard let worktreeID = run.worktreeID,
              let worktree = worktreeRecord(with: worktreeID),
              let repository = worktree.repository
        else {
            return nil
        }
        guard let descriptor = executionDescriptorForRunConfiguration(
            runConfigurationID: runConfigurationID,
            worktree: worktree,
            repository: repository
        ) else {
            return nil
        }
        return (repository, worktree, descriptor)
    }

    func startRunConfigurationAgain(_ run: RunRecord, in modelContext: ModelContext) {
        guard let context = replayRunConfigurationContext(for: run) else {
            pendingErrorMessage = "This run configuration is no longer available to start."
            return
        }
        _ = startRun(context.descriptor, repository: context.repository, worktree: context.worktree, modelContext: modelContext)
    }

    func rerunRunConfiguration(_ run: RunRecord, in modelContext: ModelContext) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopRunForRerunIfNeeded(run, in: modelContext)
            guard let context = self.replayRunConfigurationContext(for: run) else {
                self.pendingErrorMessage = "This run configuration is no longer available to re-run."
                return
            }
            _ = await self.relaunchRunWithSameRecord(
                run,
                descriptor: context.descriptor,
                repository: context.repository,
                worktree: context.worktree,
                modelContext: modelContext
            )
        }
    }

    private func stopRunForRerunIfNeeded(_ run: RunRecord, in modelContext: ModelContext) async {
        guard activeRunIDs.contains(run.id) else { return }
        forceClosingTerminalRunIDs.insert(run.id)

        if let session = terminalSessions[run.id] {
            session.send(text: "\u{3}")
        } else if let acpSession = acpRunSessionsByRunID[run.id] {
            acpSession.cancel()
        } else if let running = runningProcesses[run.id] {
            running.cancel()
        } else {
            cancelRun(run, in: modelContext)
        }

        await waitForRunToLeaveActiveSet(runID: run.id, duration: Self.rerunInterruptWaitDuration)

        if activeRunIDs.contains(run.id) {
            if let session = terminalSessions[run.id] {
                session.forceTerminate()
            } else {
                cancelRun(run, in: modelContext)
            }
            await waitForRunToLeaveActiveSet(runID: run.id, duration: Self.rerunPostForceSettleDuration)
        }
    }

    private func waitForRunToLeaveActiveSet(runID: UUID, duration: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + duration
        while clock.now < deadline {
            if !activeRunIDs.contains(runID) { return }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    // MARK: - Session recorder (documentation worktree)

    func startRunSessionRecording(_ run: RunRecord, in modelContext: ModelContext) {
        guard supportsSessionRecorder(for: run) else { return }
        guard !activeSessionRecordingRunIDs.contains(run.id) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let repository = run.repository,
                  let project = repository.project,
                  let documentationRepository = project.documentationRepository
            else {
                self.pendingErrorMessage = "No documentation repository is configured for this project."
                return
            }

            guard let worktreeID = run.worktreeID, let sourceWorktree = self.worktreeRecord(with: worktreeID) else {
                self.pendingErrorMessage = "The worktree for this run is unavailable."
                return
            }

            guard let documentationWorktree = await self.ensureDefaultBranchWorkspace(
                for: documentationRepository,
                in: modelContext
            ),
                  let documentationRoot = documentationWorktree.materializedURL
            else {
                self.pendingErrorMessage = "The documentation worktree could not be materialized."
                return
            }

            let archiveService = ProjectDocumentationArchiveService()
            let branchDirectory = archiveService.archiveDirectoryName(for: sourceWorktree.branchName)
            let sessionDir = documentationRoot
                .appendingPathComponent("session-logs", isDirectory: true)
                .appendingPathComponent("worktrees", isDirectory: true)
                .appendingPathComponent(branchDirectory, isDirectory: true)

            do {
                try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            } catch {
                self.pendingErrorMessage = "Could not create session log directory: \(error.localizedDescription)"
                return
            }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime]
            let slug = AppPaths.sanitizedPathComponent(run.title)
            let fileURL = sessionDir.appendingPathComponent("\(dateFormatter.string(from: .now))-\(slug).md", isDirectory: false)

            let header = Self.sessionLogMarkdownHeader(
                run: run,
                sourceRepository: repository,
                sourceWorktree: sourceWorktree
            )

            do {
                let opener = "## Transcript\n\n```text\n"
                try (header + opener).write(to: fileURL, atomically: true, encoding: .utf8)
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                self.sessionRecordingFileHandlesByRunID[run.id] = handle
                self.runSessionLogFileURLByRunID[run.id] = fileURL
                self.activeSessionRecordingRunIDs.insert(run.id)
            } catch {
                self.pendingErrorMessage = "Could not start session recording: \(error.localizedDescription)"
            }
        }
    }

    func stopRunSessionRecording(_ run: RunRecord) {
        guard activeSessionRecordingRunIDs.contains(run.id) else { return }
        finalizeRunSessionRecording(runID: run.id, reason: "Recording stopped manually.")
    }

    func openRunSessionRecording(_ run: RunRecord) {
        guard let url = runSessionLogFileURLByRunID[run.id] else { return }
        NSWorkspace.shared.open(url)
    }

    func appendRunSessionRecordingChunk(runID: UUID, chunk: String) {
        guard activeSessionRecordingRunIDs.contains(runID) else { return }
        guard let handle = sessionRecordingFileHandlesByRunID[runID] else { return }
        guard !chunk.isEmpty, let data = chunk.data(using: .utf8) else { return }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            Logger(subsystem: "Stackriot", category: "run-session-recording").error(
                "session-recording-append-failed runID=\(runID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func finalizeRunSessionRecordingIfNeeded(
        runID: UUID,
        exitCode: Int?,
        wasCancelled: Bool,
        failureMessage: String? = nil
    ) {
        guard activeSessionRecordingRunIDs.contains(runID) else { return }
        let reason: String
        if let failureMessage {
            reason = "Run failed: \(failureMessage)"
        } else if wasCancelled {
            reason = "Run was cancelled."
        } else if let exitCode {
            reason = "Run finished with exit code \(exitCode)."
        } else {
            reason = "Run finished."
        }
        finalizeRunSessionRecording(runID: runID, reason: reason)
    }

    private func finalizeRunSessionRecording(runID: UUID, reason: String) {
        guard activeSessionRecordingRunIDs.contains(runID) else { return }
        activeSessionRecordingRunIDs.remove(runID)

        if let handle = sessionRecordingFileHandlesByRunID.removeValue(forKey: runID) {
            let footer = "\n```\n\n---\n\(reason)\n"
            if let data = footer.data(using: .utf8) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
            try? handle.synchronize()
            try? handle.close()
        }
    }

    private static func sessionLogMarkdownHeader(
        run: RunRecord,
        sourceRepository: ManagedRepository,
        sourceWorktree: WorktreeRecord
    ) -> String {
        """
        # Run session log

        - **Run title:** \(run.title)
        - **Repository:** \(sourceRepository.displayName)
        - **Branch / worktree:** \(sourceWorktree.branchName)
        - **Command:** `\(run.commandLine.replacingOccurrences(of: "`", with: "'"))`
        - **Started:** \(ISO8601DateFormatter().string(from: run.startedAt))
        - **Run configuration ID:** \(run.runConfigurationID ?? "—")

        """
    }
}
