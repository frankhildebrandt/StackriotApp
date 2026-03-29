import Foundation
import SwiftData

extension AppModel {
    func createWorktree(for repository: ManagedRepository, in modelContext: ModelContext) async {
        do {
            let info = try await services.worktreeManager.createWorktree(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                repositoryName: repository.displayName,
                branchName: worktreeDraft.branchName,
                sourceBranch: worktreeDraft.sourceBranch.isEmpty ? repository.defaultBranch : worktreeDraft.sourceBranch
            )

            let worktree = WorktreeRecord(
                branchName: info.branchName,
                issueContext: worktreeDraft.issueContext.nilIfBlank,
                path: info.path.path,
                repository: repository
            )

            repository.worktrees.append(worktree)
            repository.updatedAt = .now
            modelContext.insert(worktree)
            try modelContext.save()

            selectedWorktreeIDsByRepository[repository.id] = worktree.id
            isWorktreeSheetPresented = false
            await refreshWorktreeStatuses(for: repository)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func removeWorktree(_ worktree: WorktreeRecord, in modelContext: ModelContext) async {
        do {
            guard let repository = worktree.repository else {
                throw DevVaultError.unsupportedRepositoryPath
            }

            let worktreeID = worktree.id
            let worktreePath = worktree.path
            let repositoryID = repository.id
            let bareRepositoryPath = repository.bareRepositoryPath
            let remainingWorktreeID = repository.worktrees
                .filter { $0.id != worktreeID }
                .sorted(by: { $0.createdAt > $1.createdAt })
                .first?
                .id
            let runIDsForWorktree = repository.runs
                .filter { $0.worktree?.id == worktreeID }
                .map(\.id)

            try await services.worktreeManager.removeWorktree(
                bareRepositoryPath: URL(fileURLWithPath: bareRepositoryPath),
                worktreePath: URL(fileURLWithPath: worktreePath)
            )

            modelContext.delete(worktree)
            repository.updatedAt = .now
            try modelContext.save()
            worktreeStatuses.removeValue(forKey: worktreeID)
            for runID in runIDsForWorktree {
                cancelAutoHide(for: runID)
            }
            terminalTabs.removeWorktree(worktreeID)
            if selectedWorktreeIDsByRepository[repositoryID] == worktreeID {
                selectedWorktreeIDsByRepository[repositoryID] = remainingWorktreeID
            }
            if worktreePendingMergeOfferID == worktreeID {
                worktreePendingMergeOfferID = nil
            }
            await refreshWorktreeStatuses(for: repository)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func refreshWorktreeStatuses(for repository: ManagedRepository) async {
        let defaultBranch = repository.defaultBranch
        var statuses: [UUID: WorktreeStatus] = [:]

        let statusService = services.worktreeStatusService
        await withTaskGroup(of: (UUID, WorktreeStatus).self) { group in
            for worktree in repository.worktrees {
                let worktreeID = worktree.id
                let worktreePath = worktree.path
                group.addTask { [statusService] in
                    let status = await statusService.fetchStatus(
                        worktreePath: URL(fileURLWithPath: worktreePath),
                        defaultBranch: defaultBranch
                    )
                    return (worktreeID, status)
                }
            }

            for await (worktreeID, status) in group {
                statuses[worktreeID] = status
            }
        }

        for (worktreeID, status) in statuses {
            worktreeStatuses[worktreeID] = status
        }
    }

    func syncWorktreeFromMain(
        _ worktree: WorktreeRecord,
        repository: ManagedRepository,
        strategy: SyncStrategy,
        modelContext: ModelContext
    ) async {
        do {
            switch strategy {
            case .rebase:
                do {
                    try await services.worktreeStatusService.rebase(
                        worktreePath: URL(fileURLWithPath: worktree.path),
                        onto: repository.defaultBranch
                    )
                    worktreePendingMergeOfferID = nil
                } catch {
                    worktreePendingMergeOfferID = worktree.id
                    return
                }
            case .merge:
                try await services.worktreeStatusService.merge(
                    worktreePath: URL(fileURLWithPath: worktree.path),
                    from: repository.defaultBranch
                )
                worktreePendingMergeOfferID = nil
            }

            await refreshWorktreeStatuses(for: repository)
            _ = modelContext
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }
}
