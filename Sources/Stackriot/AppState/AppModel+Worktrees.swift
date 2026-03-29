import Foundation
import SwiftData

extension AppModel {
    func ensureDefaultBranchWorkspace(
        for repository: ManagedRepository,
        in modelContext: ModelContext
    ) async -> WorktreeRecord? {
        if let existing = repository.worktrees.first(where: \.isDefaultBranchWorkspace) {
            if existing.branchName != repository.defaultBranch {
                existing.branchName = repository.defaultBranch
            }
            return existing
        }

        if let existingDefaultBranch = repository.worktrees.first(where: { $0.branchName == repository.defaultBranch }) {
            existingDefaultBranch.isDefaultBranchWorkspace = true
            repository.updatedAt = .now
            save(modelContext)
            return existingDefaultBranch
        }

        do {
            let bareRepositoryPath = URL(fileURLWithPath: repository.bareRepositoryPath)
            let info = try await services.worktreeManager.ensureDefaultBranchWorkspace(
                bareRepositoryPath: bareRepositoryPath,
                repositoryName: repository.displayName,
                defaultBranch: repository.defaultBranch
            )

            if let record = repository.worktrees.first(where: { $0.path == info.path.path }) {
                record.branchName = repository.defaultBranch
                record.isDefaultBranchWorkspace = true
                repository.updatedAt = .now
                save(modelContext)
                return record
            }

            let worktree = WorktreeRecord(
                branchName: repository.defaultBranch,
                isDefaultBranchWorkspace: true,
                path: info.path.path,
                repository: repository
            )
            repository.worktrees.append(worktree)
            repository.updatedAt = .now
            modelContext.insert(worktree)
            try modelContext.save()
            return worktree
        } catch {
            pendingErrorMessage = error.localizedDescription
            return nil
        }
    }

    func refreshTicketProviderStatus(for repository: ManagedRepository) async {
        worktreeDraft.ticketProvider = .github
        worktreeDraft.ticketProviderStatus = await services.gitHubCLIService.issueReadiness(for: repository)
        if worktreeDraft.ticketProviderStatus?.isAvailable != true {
            clearWorktreeTicketSelection()
            worktreeDraft.ticketSearchResults = []
        }
    }

    func clearWorktreeTicketSelection() {
        worktreeDraft.selectedTicket = nil
        worktreeDraft.selectedIssueDetails = nil
        worktreeDraft.hasConfirmedTicket = false
        if worktreeDraft.ticketProviderStatus?.isAvailable == true {
            worktreeDraft.issueContext = ""
        }
    }

    func searchWorktreeTickets(for repository: ManagedRepository) async {
        guard worktreeDraft.ticketProviderStatus?.isAvailable == true else {
            worktreeDraft.ticketSearchResults = []
            worktreeDraft.isTicketLoading = false
            return
        }

        let query = worktreeDraft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            worktreeDraft.ticketSearchResults = []
            worktreeDraft.isTicketLoading = false
            return
        }

        worktreeDraft.isTicketLoading = true
        clearWorktreeTicketSelection()
        do {
            worktreeDraft.ticketSearchResults = try await services.gitHubCLIService.searchIssues(query: query, in: repository)
        } catch {
            worktreeDraft.ticketSearchResults = []
            pendingErrorMessage = error.localizedDescription
        }
        worktreeDraft.isTicketLoading = false
    }

    func confirmWorktreeTicket(_ issue: GitHubIssueSearchResult, for repository: ManagedRepository) async {
        worktreeDraft.isTicketLoading = true
        do {
            let details = try await services.gitHubCLIService.loadIssue(number: issue.number, in: repository)
            worktreeDraft.selectedTicket = issue
            worktreeDraft.selectedIssueDetails = details
            worktreeDraft.hasConfirmedTicket = true
            worktreeDraft.issueContext = compactIssueContext(for: details)
        } catch {
            clearWorktreeTicketSelection()
            pendingErrorMessage = error.localizedDescription
        }
        worktreeDraft.isTicketLoading = false
    }

    func createWorktree(for repository: ManagedRepository, in modelContext: ModelContext) async {
        do {
            let normalizedName = WorktreeManager.normalizedWorktreeName(from: worktreeDraft.branchName)
            let info = try await services.worktreeManager.createWorktree(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                repositoryName: repository.displayName,
                branchName: normalizedName,
                sourceBranch: resolvedSourceBranch(for: repository),
                directoryName: normalizedName
            )

            let worktree = try persistCreatedWorktree(
                from: info,
                repository: repository,
                issueContext: worktreeDraft.issueContext.nilIfBlank,
                initialPlanText: nil,
                in: modelContext
            )
            finishCreatedWorktree(worktree, in: repository)
            await refreshWorktreeStatuses(for: repository)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func createWorktreeFromTicket(for repository: ManagedRepository, in modelContext: ModelContext) async {
        guard let issue = worktreeDraft.selectedIssueDetails, worktreeDraft.hasConfirmedTicket else {
            pendingErrorMessage = "Select and confirm a GitHub issue before creating the worktree."
            return
        }

        do {
            let normalizedName = WorktreeManager.normalizedWorktreeName(from: worktreeDraft.branchName)
            let info = try await services.worktreeManager.createWorktree(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                repositoryName: repository.displayName,
                branchName: normalizedName,
                sourceBranch: resolvedSourceBranch(for: repository),
                directoryName: normalizedName
            )

            let worktree = try persistCreatedWorktree(
                from: info,
                repository: repository,
                issueContext: compactIssueContext(for: issue),
                initialPlanText: initialPlan(from: issue),
                in: modelContext
            )
            finishCreatedWorktree(worktree, in: repository)
            await refreshWorktreeStatuses(for: repository)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    private func resolvedSourceBranch(for repository: ManagedRepository) -> String {
        let sourceBranch = worktreeDraft.sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceBranch.isEmpty ? repository.defaultBranch : sourceBranch
    }

    private func compactIssueContext(for issue: GitHubIssueDetails) -> String {
        let title = issue.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            return "#\(issue.number)"
        }
        return "#\(issue.number) \(title)"
    }

    private func persistCreatedWorktree(
        from info: CreatedWorktreeInfo,
        repository: ManagedRepository,
        issueContext: String?,
        initialPlanText: String?,
        in modelContext: ModelContext
    ) throws -> WorktreeRecord {
        let worktree = WorktreeRecord(
            branchName: info.branchName,
            issueContext: issueContext,
            path: info.path.path,
            repository: repository
        )

        repository.worktrees.append(worktree)
        repository.updatedAt = .now
        modelContext.insert(worktree)
        try modelContext.save()

        if let initialPlanText {
            try writePlan(initialPlanText, for: worktree.id)
        }

        return worktree
    }

    private func finishCreatedWorktree(_ worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectedWorktreeIDsByRepository[repository.id] = worktree.id
        terminalTabs.selectPlanTab(for: worktree.id)
        isWorktreeSheetPresented = false
    }

    func removeWorktree(_ worktree: WorktreeRecord, in modelContext: ModelContext) async {
        do {
            if worktree.isDefaultBranchWorkspace {
                throw StackriotError.commandFailed("The default workspace cannot be removed.")
            }
            guard let repository = worktree.repository else {
                throw StackriotError.unsupportedRepositoryPath
            }

            let worktreeID = worktree.id
            let worktreePath = worktree.path
            let repositoryID = repository.id
            let bareRepositoryPath = repository.bareRepositoryPath
            let remainingWorktreeID = try modelContext.fetch(
                FetchDescriptor<WorktreeRecord>(
                    predicate: #Predicate {
                        $0.repository?.id == repositoryID && $0.id != worktreeID
                    }
                )
            )
            .sorted(by: { $0.createdAt > $1.createdAt })
            .first?
            .id
            let runIDsForWorktree = try modelContext.fetch(
                FetchDescriptor<RunRecord>(
                    predicate: #Predicate {
                        $0.repository?.id == repositoryID && $0.worktree?.id == worktreeID
                    }
                )
            )
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
        let defaultRemoteName = resolvedDefaultRemote(for: repository)?.name ?? "origin"
        var statuses: [UUID: WorktreeStatus] = [:]

        let statusService = services.worktreeStatusService
        await withTaskGroup(of: (UUID, WorktreeStatus).self) { group in
            for worktree in repository.worktrees {
                let worktreeID = worktree.id
                let worktreePath = worktree.path
                let isDefault = worktree.isDefaultBranchWorkspace
                let compareBranch = isDefault ? "\(defaultRemoteName)/\(defaultBranch)" : defaultBranch
                group.addTask { [statusService] in
                    let status = await statusService.fetchStatus(
                        worktreePath: URL(fileURLWithPath: worktreePath),
                        defaultBranch: compareBranch
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

    func integrateIntoDefaultBranch(
        _ sourceWorktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) async {
        guard !sourceWorktree.isDefaultBranchWorkspace else { return }
        let outcome = await performLocalMerge(sourceWorktree, repository: repository, modelContext: modelContext)
        if case .committed = outcome {
            pendingErrorMessage = "Integrated \(sourceWorktree.branchName) into \(repository.defaultBranch)."
        }
        await refreshWorktreeStatuses(for: repository)
    }

    // MARK: - Integration Workflow

    func startIntegration(
        _ worktree: WorktreeRecord,
        repository: ManagedRepository,
        draft: IntegrationDraft,
        modelContext: ModelContext
    ) async {
        guard !worktree.isDefaultBranchWorkspace else { return }

        switch draft.method {
        case .localMerge:
            let outcome = await performLocalMerge(worktree, repository: repository, modelContext: modelContext)
            await refreshWorktreeStatuses(for: repository)
            if case .committed = outcome {
                pendingErrorMessage = "Integrated \(worktree.branchName) into \(repository.defaultBranch)."
                worktree.lifecycleState = .merged
                save(modelContext)
                if draft.deleteAfterIntegration {
                    await removeWorktree(worktree, in: modelContext)
                }
            }

        case .githubPR:
            do {
                let prInfo = try await services.gitHubCLIService.createPR(
                    worktreePath: URL(fileURLWithPath: worktree.path),
                    title: draft.prTitle,
                    body: draft.prBody,
                    baseBranch: repository.defaultBranch
                )
                worktree.prNumber = prInfo.number
                worktree.prURL = prInfo.url
                worktree.lifecycleState = .integrating
                worktree.shouldDeleteOnMerge = draft.deleteAfterIntegration
                save(modelContext)
                startPRMonitoring(for: worktree, repository: repository, in: modelContext)
            } catch {
                pendingErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Internal Merge Helper

    private enum LocalMergeOutcome: Sendable {
        case committed, conflict, failed
    }

    private func performLocalMerge(
        _ sourceWorktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) async -> LocalMergeOutcome {
        guard !sourceWorktree.isDefaultBranchWorkspace else { return .failed }
        guard let defaultWorktree = await ensureDefaultBranchWorkspace(for: repository, in: modelContext) else {
            return .failed
        }
        do {
            let result = try await services.worktreeStatusService.integrate(
                sourceBranch: sourceWorktree.branchName,
                defaultBranch: repository.defaultBranch,
                defaultWorktreePath: URL(fileURLWithPath: defaultWorktree.path)
            )
            switch result {
            case .committed:
                pendingIntegrationConflict = nil
                selectedWorktreeIDsByRepository[repository.id] = defaultWorktree.id
                return .committed
            case let .conflicts(message):
                pendingIntegrationConflict = IntegrationConflictDraft(
                    repositoryID: repository.id,
                    sourceWorktreeID: sourceWorktree.id,
                    defaultWorktreeID: defaultWorktree.id,
                    sourceBranch: sourceWorktree.branchName,
                    defaultBranch: repository.defaultBranch,
                    message: message
                )
                selectedWorktreeIDsByRepository[repository.id] = defaultWorktree.id
                return .conflict
            }
        } catch {
            pendingErrorMessage = error.localizedDescription
            return .failed
        }
    }

    // MARK: - PR Monitoring

    func startPRMonitoring(
        for worktree: WorktreeRecord,
        repository: ManagedRepository,
        in modelContext: ModelContext
    ) {
        let worktreeID = worktree.id
        stopPRMonitoring(for: worktreeID)

        let task = Task { [self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard
                    let record = self.worktreeRecord(with: worktreeID),
                    let prNumber = record.prNumber
                else { break }

                do {
                    let status = try await services.gitHubCLIService.getPRStatus(
                        worktreePath: URL(fileURLWithPath: record.path),
                        prNumber: prNumber
                    )
                    if status == .merged {
                        record.lifecycleState = .merged
                        self.save(modelContext)
                        if record.shouldDeleteOnMerge {
                            await self.removeWorktree(record, in: modelContext)
                        }
                        break
                    }
                } catch {
                    // Netzwerk- oder CLI-Fehler — nächsten Zyklus erneut versuchen
                }
            }
            self.prMonitoringTasks.removeValue(forKey: worktreeID)
        }

        prMonitoringTasks[worktreeID] = task
    }

    func stopPRMonitoring(for worktreeID: UUID) {
        prMonitoringTasks[worktreeID]?.cancel()
        prMonitoringTasks.removeValue(forKey: worktreeID)
    }

    func restoreAllPRMonitoring(in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<WorktreeRecord>()
        let allWorktrees = (try? modelContext.fetch(descriptor)) ?? []
        for worktree in allWorktrees {
            if worktree.lifecycleState == .integrating,
               worktree.prNumber != nil,
               let repository = worktree.repository
            {
                startPRMonitoring(for: worktree, repository: repository, in: modelContext)
            }
        }
    }

    func loadDiff(for worktree: WorktreeRecord) async -> WorkspaceDiffSnapshot {
        do {
            return try await services.worktreeStatusService.loadUncommittedDiff(
                worktreePath: URL(fileURLWithPath: worktree.path)
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            return WorkspaceDiffSnapshot(files: [])
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
