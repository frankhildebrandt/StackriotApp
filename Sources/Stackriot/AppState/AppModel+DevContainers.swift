import Foundation

extension AppModel {
    func hasDevContainerConfiguration(for worktree: WorktreeRecord) -> Bool {
        services.devContainerService.configuration(at: URL(fileURLWithPath: worktree.path)) != nil
    }

    func devContainerState(for worktree: WorktreeRecord) -> DevContainerWorkspaceState {
        let configuration = services.devContainerService.configuration(at: URL(fileURLWithPath: worktree.path))
        var state = devContainerStatesByWorktreeID[worktree.id] ?? DevContainerWorkspaceState(configuration: configuration)
        state.configuration = configuration
        return state
    }

    func refreshDevContainerState(for worktree: WorktreeRecord) async {
        let snapshot = await services.devContainerService.status(for: URL(fileURLWithPath: worktree.path))
        mergeDevContainerSnapshot(snapshot, into: worktree.id)
    }

    func startDevContainer(for worktree: WorktreeRecord) async {
        await performDevContainerOperation(.start, for: worktree) {
            try await services.devContainerService.start(worktreeURL: URL(fileURLWithPath: worktree.path))
        }
    }

    func stopDevContainer(for worktree: WorktreeRecord) async {
        stopDevContainerLogStreaming(for: worktree.id)
        await performDevContainerOperation(.stop, for: worktree) {
            try await services.devContainerService.stop(worktreeURL: URL(fileURLWithPath: worktree.path))
        }
    }

    func restartDevContainer(for worktree: WorktreeRecord) async {
        stopDevContainerLogStreaming(for: worktree.id)
        await performDevContainerOperation(.restart, for: worktree) {
            try await services.devContainerService.restart(worktreeURL: URL(fileURLWithPath: worktree.path))
        }
    }

    func rebuildDevContainer(for worktree: WorktreeRecord) async {
        stopDevContainerLogStreaming(for: worktree.id)
        await performDevContainerOperation(.rebuild, for: worktree) {
            try await services.devContainerService.rebuild(worktreeURL: URL(fileURLWithPath: worktree.path))
        }
    }

    func deleteDevContainer(for worktree: WorktreeRecord) async {
        stopDevContainerLogStreaming(for: worktree.id)
        await performDevContainerOperation(.delete, for: worktree) {
            try await services.devContainerService.delete(worktreeURL: URL(fileURLWithPath: worktree.path))
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
            let (executable, arguments) = try await services.devContainerService.logStreamDescriptor(
                for: URL(fileURLWithPath: worktree.path)
            )
            let handle = try CommandRunner.start(
                executable: executable,
                arguments: arguments,
                currentDirectoryURL: URL(fileURLWithPath: worktree.path),
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
        execute: () async throws -> DevContainerWorkspaceSnapshot
    ) async {
        let worktreeID = worktree.id
        var state = devContainerState(for: worktree)
        state.activeOperation = operation
        state.detailsErrorMessage = nil
        devContainerStatesByWorktreeID[worktreeID] = state

        do {
            let snapshot = try await execute()
            mergeDevContainerSnapshot(snapshot, into: worktreeID)
            var updated = devContainerState(for: worktree)
            updated.activeOperation = nil
            devContainerStatesByWorktreeID[worktreeID] = updated
        } catch {
            var failed = devContainerState(for: worktree)
            failed.activeOperation = nil
            failed.detailsErrorMessage = error.localizedDescription
            devContainerStatesByWorktreeID[worktreeID] = failed
            pendingErrorMessage = error.localizedDescription
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
