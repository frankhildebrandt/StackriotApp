import Foundation
import SwiftData

extension AppModel {
    func hasDevContainerConfiguration(for worktree: WorktreeRecord) -> Bool {
        guard let worktreeURL = worktree.materializedURL else { return false }
        return services.devContainerService.configuration(at: worktreeURL) != nil
    }

    func devContainerState(for worktree: WorktreeRecord) -> DevContainerWorkspaceState {
        let configuration = worktree.materializedURL.flatMap { services.devContainerService.configuration(at: $0) }
        var state = devContainerStatesByWorktreeID[worktree.id] ?? DevContainerWorkspaceState(configuration: configuration)
        state.configuration = configuration
        return state
    }

    func isDevContainerLogsVisible(for worktreeID: UUID) -> Bool {
        visibleDevContainerLogWorktreeIDs.contains(worktreeID)
    }

    func setDevContainerLogsVisible(_ isVisible: Bool, for worktreeID: UUID) {
        if isVisible {
            visibleDevContainerLogWorktreeIDs.insert(worktreeID)
        } else {
            visibleDevContainerLogWorktreeIDs.remove(worktreeID)
        }
    }

    func refreshDevContainerState(for worktree: WorktreeRecord) async {
        guard let worktreeURL = worktree.materializedURL else {
            devContainerStatesByWorktreeID[worktree.id] = DevContainerWorkspaceState(configuration: nil)
            return
        }
        let snapshot = await services.devContainerService.status(for: worktreeURL)
        mergeDevContainerSnapshot(snapshot, into: worktree.id)
    }

    func refreshAllDevContainerStates() async {
        guard let modelContext = storedModelContext else { return }
        let worktrees = (try? modelContext.fetch(FetchDescriptor<WorktreeRecord>())) ?? []
        for worktree in worktrees {
            guard let worktreeURL = worktree.materializedURL else { continue }
            let hasConfiguration = services.devContainerService.configuration(at: worktreeURL) != nil
            guard hasConfiguration || devContainerStatesByWorktreeID[worktree.id] != nil else { continue }
            await refreshDevContainerState(for: worktree)
        }
    }

    func startDevContainer(for worktree: WorktreeRecord) async {
        await performDevContainerOperation(.start, for: worktree) { worktreeURL in
            try await services.devContainerService.start(worktreeURL: worktreeURL)
        }
    }

    func stopDevContainer(for worktree: WorktreeRecord) async {
        stopDevContainerLogStreaming(for: worktree.id)
        await performDevContainerOperation(.stop, for: worktree) { worktreeURL in
            try await services.devContainerService.stop(worktreeURL: worktreeURL)
        }
    }

    func restartDevContainer(for worktree: WorktreeRecord) async {
        stopDevContainerLogStreaming(for: worktree.id)
        await performDevContainerOperation(.restart, for: worktree) { worktreeURL in
            try await services.devContainerService.restart(worktreeURL: worktreeURL)
        }
    }

    func rebuildDevContainer(for worktree: WorktreeRecord) async {
        stopDevContainerLogStreaming(for: worktree.id)
        await performDevContainerOperation(.rebuild, for: worktree) { worktreeURL in
            try await services.devContainerService.rebuild(worktreeURL: worktreeURL)
        }
    }

    func deleteDevContainer(for worktree: WorktreeRecord) async {
        stopDevContainerLogStreaming(for: worktree.id)
        await performDevContainerOperation(.delete, for: worktree) { worktreeURL in
            try await services.devContainerService.delete(worktreeURL: worktreeURL)
        }
    }

    func openDevContainerTerminal(for worktree: WorktreeRecord, in modelContext: ModelContext) async {
        guard let (repository, worktreeURL) = await materializedWorktreeContext(for: worktree, in: modelContext) else { return }

        do {
            let descriptor = try await services.devContainerService.terminalDescriptor(
                for: worktreeURL,
                repositoryID: repository.id,
                worktreeID: worktree.id
            )
            startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
        } catch {
            pendingErrorMessage = error.localizedDescription
            var state = devContainerState(for: worktree)
            state.detailsErrorMessage = error.localizedDescription
            devContainerStatesByWorktreeID[worktree.id] = state
        }
    }

    func navigateToDevContainer(_ summary: DevContainerGlobalSummary) {
        selectedRepositoryID = summary.repositoryID
        if let repository = repositoryRecord(with: summary.repositoryID),
           let worktree = worktreeRecord(with: summary.worktreeID) {
            selectWorktree(worktree, in: repository)
        }
    }

    func activeDevContainerSummaries() -> [DevContainerGlobalSummary] {
        devContainerStatesByWorktreeID.compactMap { worktreeID, state in
            guard let worktree = worktreeRecord(with: worktreeID),
                  let repository = worktree.repository
            else {
                return nil
            }
            guard state.isRunning || state.activeOperation != nil || (state.diagnosticIssue != nil && state.hasConfiguration) else {
                return nil
            }
            return DevContainerGlobalSummary(
                worktreeID: worktreeID,
                repositoryID: repository.id,
                namespaceName: repository.namespace?.name ?? "Unknown Namespace",
                repositoryName: repository.displayName,
                worktreeName: worktree.isDefaultBranchWorkspace ? "Main/Default" : worktree.branchName,
                runtimeStatus: state.runtimeStatus,
                containerName: state.containerName,
                containerID: state.containerID,
                imageName: state.imageName,
                resourceUsage: state.resourceUsage,
                activeOperation: state.activeOperation,
                detailsErrorMessage: state.detailsErrorMessage,
                toolingStatus: state.toolingStatus,
                diagnosticIssue: state.diagnosticIssue,
                lastUpdatedAt: state.lastUpdatedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            if lhs.lastUpdatedAt != rhs.lastUpdatedAt {
                return (lhs.lastUpdatedAt ?? .distantPast) > (rhs.lastUpdatedAt ?? .distantPast)
            }
            return lhs.worktreeName.localizedStandardCompare(rhs.worktreeName) == .orderedAscending
        }
    }

    func hasActiveDevContainer(in repository: ManagedRepository) -> Bool {
        repository.worktrees.contains { worktree in
            let state = devContainerStatesByWorktreeID[worktree.id]
            return state?.isRunning == true || state?.activeOperation != nil
        }
    }

    func activeDevContainerCount(in repository: ManagedRepository) -> Int {
        repository.worktrees.reduce(into: 0) { partialResult, worktree in
            let state = devContainerStatesByWorktreeID[worktree.id]
            if state?.isRunning == true || state?.activeOperation != nil {
                partialResult += 1
            }
        }
    }

    func startDevContainerLogStreaming(for worktree: WorktreeRecord) async {
        let worktreeID = worktree.id
        if devContainerLogProcessesByWorktreeID[worktreeID] != nil {
            var state = devContainerState(for: worktree)
            state.isLogStreaming = true
            devContainerStatesByWorktreeID[worktreeID] = state
            return
        }

        do {
            guard let repository = worktree.repository,
                  let modelContext = storedModelContext,
                  await materializeIdeaTreeIfNeeded(worktree, in: repository, modelContext: modelContext) != nil,
                  let worktreeURL = worktree.materializedURL
            else {
                return
            }
            let (executable, arguments) = try await services.devContainerService.logStreamDescriptor(
                for: worktreeURL
            )
            let handle = try CommandRunner.start(
                executable: executable,
                arguments: arguments,
                currentDirectoryURL: worktreeURL,
                onOutput: { [weak self] chunk in
                    Task { @MainActor in
                        self?.appendDevContainerLogChunk(chunk, for: worktreeID)
                    }
                },
                onTermination: { [weak self] exitCode, wasCancelled in
                    Task { @MainActor in
                        self?.handleDevContainerLogTermination(
                            for: worktreeID,
                            exitCode: exitCode,
                            wasCancelled: wasCancelled
                        )
                    }
                }
            )
            devContainerLogProcessesByWorktreeID[worktreeID] = handle
            var state = devContainerState(for: worktree)
            state.isLogStreaming = true
            state.detailsErrorMessage = nil
            devContainerStatesByWorktreeID[worktreeID] = state
        } catch {
            pendingErrorMessage = error.localizedDescription
            var state = devContainerState(for: worktree)
            state.isLogStreaming = false
            state.detailsErrorMessage = error.localizedDescription
            devContainerStatesByWorktreeID[worktreeID] = state
        }
    }

    func stopDevContainerLogStreaming(for worktreeID: UUID) {
        devContainerLogProcessesByWorktreeID[worktreeID]?.cancel()
        devContainerLogProcessesByWorktreeID.removeValue(forKey: worktreeID)
        guard var state = devContainerStatesByWorktreeID[worktreeID] else { return }
        state.isLogStreaming = false
        devContainerStatesByWorktreeID[worktreeID] = state
    }

    private func performDevContainerOperation(
        _ operation: DevContainerOperation,
        for worktree: WorktreeRecord,
        execute: (URL) async throws -> DevContainerWorkspaceSnapshot
    ) async {
        let worktreeID = worktree.id
        var state = devContainerState(for: worktree)
        state.activeOperation = operation
        state.detailsErrorMessage = nil
        devContainerStatesByWorktreeID[worktreeID] = state

        do {
            guard let repository = worktree.repository,
                  let modelContext = storedModelContext,
                  await materializeIdeaTreeIfNeeded(worktree, in: repository, modelContext: modelContext) != nil,
                  let worktreeURL = worktree.materializedURL
            else {
                state.activeOperation = nil
                devContainerStatesByWorktreeID[worktreeID] = state
                return
            }
            let snapshot = try await execute(worktreeURL)
            mergeDevContainerSnapshot(snapshot, into: worktreeID)
            var updated = devContainerState(for: worktree)
            updated.activeOperation = nil
            devContainerStatesByWorktreeID[worktreeID] = updated
            notifyDevContainerOperationCompletion(operation, worktree: worktree, snapshot: snapshot)
        } catch {
            var failed = devContainerState(for: worktree)
            failed.activeOperation = nil
            failed.detailsErrorMessage = error.localizedDescription
            devContainerStatesByWorktreeID[worktreeID] = failed
            pendingErrorMessage = error.localizedDescription
            notifyDevContainerOperationFailure(operation, worktree: worktree, message: error.localizedDescription)
        }
    }

    private func mergeDevContainerSnapshot(_ snapshot: DevContainerWorkspaceSnapshot, into worktreeID: UUID) {
        var state = devContainerStatesByWorktreeID[worktreeID] ?? DevContainerWorkspaceState(configuration: snapshot.configuration)
        let logs = state.logs
        let isLogStreaming = state.isLogStreaming
        let activeOperation = state.activeOperation
        state.apply(snapshot: snapshot)
        state.logs = logs
        state.isLogStreaming = isLogStreaming
        state.activeOperation = activeOperation
        devContainerStatesByWorktreeID[worktreeID] = state
    }

    private func appendDevContainerLogChunk(_ chunk: String, for worktreeID: UUID) {
        var state = devContainerStatesByWorktreeID[worktreeID] ?? DevContainerWorkspaceState()
        state.logs += chunk
        if state.logs.count > 120_000 {
            state.logs = String(state.logs.suffix(100_000))
        }
        state.isLogStreaming = true
        devContainerStatesByWorktreeID[worktreeID] = state
    }

    private func handleDevContainerLogTermination(for worktreeID: UUID, exitCode: Int32, wasCancelled: Bool) {
        devContainerLogProcessesByWorktreeID.removeValue(forKey: worktreeID)
        guard var state = devContainerStatesByWorktreeID[worktreeID] else { return }
        state.isLogStreaming = false
        if !wasCancelled, exitCode != 0 {
            state.logs += "\n[stackriot] Devcontainer log stream exited with code \(exitCode).\n"
            state.detailsErrorMessage = "The devcontainer log stream stopped unexpectedly."
        }
        devContainerStatesByWorktreeID[worktreeID] = state
    }
}
