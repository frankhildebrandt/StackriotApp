import Foundation
import SwiftData

extension AppModel {
    func hasDevContainerConfiguration(for worktree: WorktreeRecord) -> Bool {
        ensureWorktreeDiscoverySnapshot(for: worktree).hasDevContainerConfiguration
    }

    func devContainerState(for worktree: WorktreeRecord) -> DevContainerWorkspaceState {
        let configuration = ensureWorktreeDiscoverySnapshot(for: worktree).configuration
        var state = devContainerStatesByWorktreeID[worktree.id] ?? DevContainerWorkspaceState(configuration: configuration)
        state.configuration = configuration
        return state
    }

    func refreshDevContainerState(for worktree: WorktreeRecord) async {
        guard let worktreeURL = worktree.materializedURL else {
            devContainerStatesByWorktreeID[worktree.id] = DevContainerWorkspaceState(configuration: nil)
            worktreeDiscoverySnapshotsByID[worktree.id] = WorktreeDiscoverySnapshot(
                worktreeID: worktree.id,
                workspacePath: nil,
                configuration: nil,
                availableDevTools: worktreeDiscoverySnapshotsByID[worktree.id]?.availableDevTools,
                lastUpdatedAt: .now
            )
            if let repository = worktree.repository {
                refreshRepositorySidebarSnapshot(for: repository)
            }
            return
        }

        if let inFlightTask = devContainerStateRefreshTasksByWorktreeID[worktree.id] {
            let snapshot = await inFlightTask.value
            mergeDevContainerSnapshot(snapshot, into: worktree.id)
            return
        }

        let discoverySnapshot = ensureWorktreeDiscoverySnapshot(for: worktree)
        guard discoverySnapshot.hasDevContainerConfiguration else {
            let snapshot = DevContainerWorkspaceSnapshot(
                configuration: nil,
                runtimeStatus: .unknown,
                containerCount: 0,
                detailsErrorMessage: nil,
                lastUpdatedAt: .now,
                toolingStatus: devContainerStatesByWorktreeID[worktree.id]?.toolingStatus ?? DevContainerToolingStatus(),
                diagnosticIssue: .noConfiguration
            )
            mergeDevContainerSnapshot(snapshot, into: worktree.id)
            return
        }

        recordDevContainerRefreshStart(for: worktree.id)
        let task = Task.detached(priority: .utility) { [services = services] in
            await services.devContainerService.status(for: worktreeURL)
        }
        devContainerStateRefreshTasksByWorktreeID[worktree.id] = task
        let snapshot = await task.value
        devContainerStateRefreshTasksByWorktreeID.removeValue(forKey: worktree.id)
        mergeDevContainerSnapshot(snapshot, into: worktree.id)
    }

    func refreshAllDevContainerStates() async {
        guard let modelContext = storedModelContext else { return }
        let worktrees = (try? modelContext.fetch(FetchDescriptor<WorktreeRecord>())) ?? []
        for worktree in worktrees {
            guard worktree.materializedURL != nil else { continue }
            let hasConfiguration = ensureWorktreeDiscoverySnapshot(for: worktree).hasDevContainerConfiguration
            guard hasConfiguration || devContainerStatesByWorktreeID[worktree.id] != nil else { continue }
            await refreshDevContainerState(for: worktree)
        }
    }

    func shouldActivelyPollDevContainer(for worktree: WorktreeRecord) -> Bool {
        let state = devContainerState(for: worktree)
        return primaryPane(for: worktree) == .devContainerLogs || state.activeOperation != nil || state.isLogStreaming
    }

    func shouldRefreshDevContainerImmediately(for worktree: WorktreeRecord) -> Bool {
        let state = devContainerState(for: worktree)
        guard state.hasConfiguration else { return false }
        if shouldActivelyPollDevContainer(for: worktree) {
            return true
        }
        return state.lastUpdatedAt == nil
    }

    func consoleDevContainerPollInterval(for worktree: WorktreeRecord) -> TimeInterval {
        shouldActivelyPollDevContainer(for: worktree) ? 4 : max(AppPreferences.devContainerMonitoringInterval, 30)
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

    func openDevContainerLogs(for worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectedRepositoryID = repository.id
        selectPrimaryPane(.devContainerLogs, for: worktree, in: repository)
    }

    func activeDevContainerSummaries() -> [DevContainerGlobalSummary] {
        devContainerStatesByWorktreeID.compactMap { worktreeID, state in
            guard let worktree = worktreeRecord(with: worktreeID),
                  let repository = worktree.repository
            else {
                return nil
            }
            guard state.isRunning || state.activeOperation != nil else {
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
        repositorySidebarSnapshotsByID[repository.id]?.activeDevContainerCount ?? 0
    }

    func sidebarSnapshot(for repository: ManagedRepository) -> RepositorySidebarSnapshot {
        if let snapshot = repositorySidebarSnapshotsByID[repository.id] {
            return snapshot
        }
        return RepositorySidebarSnapshot(
            repositoryID: repository.id,
            isRefreshing: refreshingRepositoryIDs.contains(repository.id),
            isAgentRunning: isAgentRunning(forRepository: repository),
            activeDevContainerCount: repository.worktrees.reduce(into: 0) { result, worktree in
                let state = devContainerStatesByWorktreeID[worktree.id]
                if state?.isRunning == true || state?.activeOperation != nil {
                    result += 1
                }
            }
        )
    }

    func refreshRepositorySidebarSnapshot(for repository: ManagedRepository) {
        let snapshot = measureSelectionPhase(
            repositoryID: repository.id,
            phase: "build-repository-sidebar-snapshot",
            metadata: ["worktreeCount": repository.worktrees.count]
        ) {
            RepositorySidebarSnapshot(
                repositoryID: repository.id,
                isRefreshing: refreshingRepositoryIDs.contains(repository.id),
                isAgentRunning: isAgentRunning(forRepository: repository),
                activeDevContainerCount: repository.worktrees.reduce(into: 0) { result, worktree in
                    let state = devContainerStatesByWorktreeID[worktree.id]
                    if state?.isRunning == true || state?.activeOperation != nil {
                        result += 1
                    }
                }
            )
        }
        repositorySidebarSnapshotsByID[repository.id] = snapshot
        refreshRepositoryDetailSnapshot(for: repository)
    }

    func repositoryDetailSnapshot(for repository: ManagedRepository) -> RepositoryDetailSnapshot {
        if let snapshot = repositoryDetailSnapshotsByID[repository.id] {
            return snapshot
        }
        let snapshot = makeRepositoryDetailSnapshot(for: repository)
        repositoryDetailSnapshotsByID[repository.id] = snapshot
        return snapshot
    }

    func refreshRepositoryDetailSnapshot(for repository: ManagedRepository) {
        repositoryDetailSnapshotsByID[repository.id] = measureSelectionPhase(
            repositoryID: repository.id,
            phase: "build-repository-detail-snapshot",
            metadata: ["worktreeCount": repository.worktrees.count]
        ) {
            makeRepositoryDetailSnapshot(for: repository)
        }
    }

    func primeWorktreeConfigurationSnapshots(for repository: ManagedRepository) {
        for worktree in repository.worktrees {
            _ = ensureWorktreeDiscoverySnapshot(for: worktree)
        }
    }

    func cachedWorktreeDiscoverySnapshot(for worktree: WorktreeRecord) -> WorktreeDiscoverySnapshot {
        let workspacePath = worktree.materializedURL?.path
        if let snapshot = worktreeDiscoverySnapshotsByID[worktree.id],
           snapshot.workspacePath == workspacePath
        {
            return snapshot
        }
        return WorktreeDiscoverySnapshot(
            worktreeID: worktree.id,
            workspacePath: workspacePath,
            configuration: nil,
            availableDevTools: nil,
            lastUpdatedAt: .distantPast
        )
    }

    @discardableResult
    func ensureWorktreeDiscoverySnapshot(for worktree: WorktreeRecord) -> WorktreeDiscoverySnapshot {
        let workspacePath = worktree.materializedURL?.path
        if let snapshot = worktreeDiscoverySnapshotsByID[worktree.id],
           snapshot.workspacePath == workspacePath
        {
            return snapshot
        }
        return refreshWorktreeConfigurationSnapshot(for: worktree)
    }

    @discardableResult
    func refreshWorktreeConfigurationSnapshot(for worktree: WorktreeRecord) -> WorktreeDiscoverySnapshot {
        guard let worktreeURL = worktree.materializedURL else {
            let snapshot = WorktreeDiscoverySnapshot(
                worktreeID: worktree.id,
                workspacePath: nil,
                configuration: nil,
                availableDevTools: nil,
                lastUpdatedAt: .now
            )
            worktreeDiscoverySnapshotsByID[worktree.id] = snapshot
            return snapshot
        }

        recordDevContainerConfigurationProbe(for: worktree.id)
        let configuration = services.devContainerService.configuration(at: worktreeURL)
        let snapshot = WorktreeDiscoverySnapshot(
            worktreeID: worktree.id,
            workspacePath: worktreeURL.path,
            configuration: configuration,
            availableDevTools: worktreeDiscoverySnapshotsByID[worktree.id]?.availableDevTools,
            lastUpdatedAt: .now
        )
        worktreeDiscoverySnapshotsByID[worktree.id] = snapshot
        return snapshot
    }

    func invalidateWorktreeDiscoverySnapshot(for worktreeID: UUID) {
        worktreeDiscoverySnapshotsByID.removeValue(forKey: worktreeID)
    }

    private func makeRepositoryDetailSnapshot(for repository: ManagedRepository) -> RepositoryDetailSnapshot {
        let selectedWorktreeID = selectedWorktreeIDsByRepository[repository.id] ?? worktrees(for: repository).first?.id
        let defaultRemoteName = resolvedDefaultRemote(for: repository)?.name
        let activeRunCount = repository.runs.reduce(into: 0) { result, run in
            if activeRunIDs.contains(run.id) {
                result += 1
            }
        }
        let activeDevContainerCount = repository.worktrees.reduce(into: 0) { result, worktree in
            let state = devContainerStatesByWorktreeID[worktree.id]
            if state?.isRunning == true || state?.activeOperation != nil {
                result += 1
            }
        }
        let installedAgents = AIAgentTool.allCases.filter { tool in
            tool != .none && self.availableAgents.contains(tool)
        }

        let worktreeSnapshots = Dictionary(uniqueKeysWithValues: repository.worktrees.map { worktree in
            (
                worktree.id,
                WorktreePresentationSnapshot(
                    worktreeID: worktree.id,
                    isSelected: selectedWorktreeID == worktree.id,
                    status: worktreeStatuses[worktree.id] ?? WorktreeStatus(),
                    pullRequestStatus: pullRequestUpstreamStatuses[worktree.id],
                    isAgentRunning: runningAgentWorktreeIDs.contains(worktree.id),
                    devContainerState: devContainerState(for: worktree)
                )
            )
        })

        return RepositoryDetailSnapshot(
            repositoryID: repository.id,
            selectedWorktreeID: selectedWorktreeID,
            defaultRemoteName: defaultRemoteName,
            activeRunCount: activeRunCount,
            activeDevContainerCount: activeDevContainerCount,
            syncLog: syncLogs[repository.id],
            availableAgents: installedAgents,
            worktreeSnapshotsByID: worktreeSnapshots
        )
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
        let previousState = devContainerStatesByWorktreeID[worktreeID]
        var state = previousState ?? DevContainerWorkspaceState(configuration: snapshot.configuration)
        let logs = state.logs
        let isLogStreaming = state.isLogStreaming
        let activeOperation = state.activeOperation
        state.apply(snapshot: snapshot)
        state.logs = logs
        state.isLogStreaming = isLogStreaming
        state.activeOperation = activeOperation

        if let worktree = worktreeRecord(with: worktreeID) {
            let currentPath = worktree.materializedURL?.path
            let discoverySnapshot = WorktreeDiscoverySnapshot(
                worktreeID: worktreeID,
                workspacePath: currentPath,
                configuration: snapshot.configuration,
                availableDevTools: worktreeDiscoverySnapshotsByID[worktreeID]?.availableDevTools,
                lastUpdatedAt: snapshot.lastUpdatedAt ?? .now
            )
            let previousDiscoverySnapshot = worktreeDiscoverySnapshotsByID[worktreeID]
            let previousDiscoveryConfiguration = previousDiscoverySnapshot?.configuration
            let previousDiscoveryTools = previousDiscoverySnapshot?.availableDevTools
            let shouldUpdateState = normalizedDevContainerState(previousState) != normalizedDevContainerState(state)
            let shouldUpdateDiscovery =
                previousDiscoverySnapshot?.workspacePath != discoverySnapshot.workspacePath ||
                previousDiscoveryConfiguration != discoverySnapshot.configuration ||
                previousDiscoveryTools != discoverySnapshot.availableDevTools

            guard shouldUpdateState || shouldUpdateDiscovery else { return }

            devContainerStatesByWorktreeID[worktreeID] = state
            worktreeDiscoverySnapshotsByID[worktreeID] = discoverySnapshot
            if let repository = worktree.repository {
                refreshRepositorySidebarSnapshot(for: repository)
            }
        } else {
            guard normalizedDevContainerState(previousState) != normalizedDevContainerState(state) else { return }
            devContainerStatesByWorktreeID[worktreeID] = state
        }
    }

    private func normalizedDevContainerState(_ state: DevContainerWorkspaceState?) -> DevContainerWorkspaceState? {
        guard var state else { return nil }
        state.lastUpdatedAt = nil
        return state
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
