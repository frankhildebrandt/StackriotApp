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
        let githubStatus = await services.gitHubCLIService.readiness(for: repository)
        let jiraStatus = await services.jiraCloudService.readiness(for: repository)
        let statuses = [githubStatus, jiraStatus]
        worktreeDraft.ticketProviderStatuses = statuses

        let availableProviders = statuses.filter(\.isAvailable).map(\.provider)
        if let currentProvider = worktreeDraft.ticketProvider, availableProviders.contains(currentProvider) {
            // keep explicit selection
        } else if availableProviders.count == 1 {
            worktreeDraft.ticketProvider = availableProviders[0]
        } else if let firstAvailable = availableProviders.first {
            worktreeDraft.ticketProvider = firstAvailable
        } else {
            worktreeDraft.ticketProvider = statuses.first?.provider
        }

        if worktreeDraft.selectedTicketProviderStatus?.isAvailable != true {
            clearWorktreeTicketSelection()
            worktreeDraft.ticketSearchResults = []
        }
    }

    func setWorktreeTicketProvider(_ provider: TicketProviderKind?) {
        guard worktreeDraft.ticketProvider != provider else { return }
        worktreeDraft.ticketProvider = provider
        clearWorktreeTicketSelection()
        worktreeDraft.ticketSearchResults = []
    }

    func clearWorktreeTicketSelection() {
        worktreeDraft.selectedTicket = nil
        worktreeDraft.selectedIssueDetails = nil
        worktreeDraft.hasConfirmedTicket = false
        worktreeDraft.isGeneratingSuggestedName = false
        if worktreeDraft.selectedTicketProviderStatus?.isAvailable == true {
            worktreeDraft.issueContext = ""
        }
    }

    func searchWorktreeTickets(for repository: ManagedRepository) async {
        guard
            let provider = worktreeDraft.ticketProvider,
            worktreeDraft.selectedTicketProviderStatus?.isAvailable == true
        else {
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
            let service = services.ticketProviderService(for: provider)
            worktreeDraft.ticketSearchResults = try await service.searchTickets(query: query, in: repository)
        } catch {
            worktreeDraft.ticketSearchResults = []
            pendingErrorMessage = error.localizedDescription
        }
        worktreeDraft.isTicketLoading = false
    }

    func confirmWorktreeTicket(_ ticket: TicketSearchResult, for repository: ManagedRepository) async {
        worktreeDraft.isTicketLoading = true
        do {
            let service = services.ticketProviderService(for: ticket.reference.provider)
            let details = try await service.loadTicket(id: ticket.reference.id, in: repository)
            worktreeDraft.selectedTicket = ticket
            worktreeDraft.selectedIssueDetails = details
            worktreeDraft.ticketProvider = ticket.reference.provider
            worktreeDraft.hasConfirmedTicket = true
            worktreeDraft.issueContext = compactIssueContext(for: details)
            await populateSuggestedWorktreeName(from: details)
        } catch {
            clearWorktreeTicketSelection()
            pendingErrorMessage = error.localizedDescription
        }
        worktreeDraft.isTicketLoading = false
    }

    func createWorktree(for repository: ManagedRepository, in modelContext: ModelContext) async {
        do {
            let normalizedName = WorktreeManager.normalizedWorktreeName(from: worktreeDraft.branchName)
            let createFromConfirmedTicket = worktreeDraft.hasConfirmedTicket && worktreeDraft.selectedIssueDetails != nil
            let info = try await services.worktreeManager.createWorktree(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                repositoryName: repository.displayName,
                branchName: normalizedName,
                sourceBranch: resolvedSourceBranch(for: repository),
                directoryName: normalizedName,
                destinationRoot: worktreeDraft.destinationRootURL
            )

            let issueContext = createFromConfirmedTicket
                ? worktreeDraft.selectedIssueDetails.map(compactIssueContext(for:))
                : worktreeDraft.issueContext.nilIfBlank
            let initialPlanText = createFromConfirmedTicket
                ? worktreeDraft.selectedIssueDetails.map(initialPlan(from:))
                : nil

            let worktree = try persistCreatedWorktree(
                from: info,
                repository: repository,
                ticketDetails: createFromConfirmedTicket ? worktreeDraft.selectedIssueDetails : nil,
                issueContext: issueContext,
                initialPlanText: initialPlanText,
                in: modelContext
            )
            finishCreatedWorktree(worktree, in: repository)
            await refreshWorktreeStatuses(for: repository)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func createWorktreeFromTicket(for repository: ManagedRepository, in modelContext: ModelContext) async {
        await createWorktree(for: repository, in: modelContext)
    }

    private func resolvedSourceBranch(for repository: ManagedRepository) -> String {
        let sourceBranch = worktreeDraft.sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceBranch.isEmpty ? repository.defaultBranch : sourceBranch
    }

    private func compactIssueContext(for ticket: TicketDetails) -> String {
        let title = ticket.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            return ticket.reference.displayID
        }
        return "\(ticket.reference.displayID) \(title)"
    }

    func populateSuggestedWorktreeName(from ticket: TicketDetails) async {
        worktreeDraft.isGeneratingSuggestedName = true
        defer { worktreeDraft.isGeneratingSuggestedName = false }

        do {
            let suggestion = try await services.aiProviderService.suggestWorktreeName(for: ticket)
            worktreeDraft.branchName = suggestion.branchName
        } catch {
            let fallback = services.aiProviderService.fallbackWorktreeNameSuggestion(for: ticket)
            worktreeDraft.branchName = fallback.branchName
            pendingErrorMessage = "AI worktree suggestion failed: \(error.localizedDescription)"
        }
    }

    private func persistCreatedWorktree(
        from info: CreatedWorktreeInfo,
        repository: ManagedRepository,
        ticketDetails: TicketDetails?,
        issueContext: String?,
        initialPlanText: String?,
        in modelContext: ModelContext
    ) throws -> WorktreeRecord {
        let worktree = WorktreeRecord(
            branchName: info.branchName,
            issueContext: issueContext,
            ticketProvider: ticketDetails?.provider,
            ticketIdentifier: ticketDetails?.reference.id,
            ticketURL: ticketDetails?.url,
            path: info.path.path,
            repository: repository,
            primaryContext: ticketDetails.map {
                WorktreePrimaryContext(
                    kind: .ticket,
                    canonicalURL: $0.url,
                    title: $0.title,
                    label: $0.provider.ticketLabel,
                    provider: $0.provider,
                    prNumber: nil,
                    ticketID: $0.reference.id,
                    upstreamReference: nil,
                    upstreamSHA: nil
                )
            }
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

    func finishCreatedWorktree(_ worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectedWorktreeIDsByRepository[repository.id] = worktree.id
        terminalTabs.selectPlanTab(for: worktree.id)
        isWorktreeSheetPresented = false
    }

    func moveWorktree(
        _ worktree: WorktreeRecord,
        in repository: ManagedRepository,
        to newParentDirectory: URL,
        modelContext: ModelContext
    ) async {
        do {
            if worktree.isDefaultBranchWorkspace {
                throw StackriotError.commandFailed("The default workspace cannot be moved.")
            }

            let destination = try await services.worktreeManager.moveWorktree(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                worktreePath: URL(fileURLWithPath: worktree.path),
                newParentDirectory: newParentDirectory,
                directoryName: worktree.branchName
            )

            worktree.path = destination.path
            worktree.lastOpenedAt = .now
            repository.updatedAt = .now
            save(modelContext)
            await refreshWorktreeStatuses(for: repository)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func setPinned(
        _ isPinned: Bool,
        for worktree: WorktreeRecord,
        in repository: ManagedRepository,
        modelContext: ModelContext
    ) {
        guard !worktree.isDefaultBranchWorkspace else { return }
        guard worktree.isPinned != isPinned else { return }

        worktree.isPinned = isPinned
        if isPinned {
            worktree.shouldDeleteOnMerge = false
        }
        repository.updatedAt = .now
        save(modelContext)
    }

    func setCardColor(
        _ color: WorktreeCardColor,
        for worktree: WorktreeRecord,
        in repository: ManagedRepository,
        modelContext: ModelContext
    ) {
        guard worktree.cardColor != color else { return }

        worktree.cardColor = color
        repository.updatedAt = .now
        save(modelContext)
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

            stopPRMonitoring(for: worktreeID)
            modelContext.delete(worktree)
            repository.updatedAt = .now
            try modelContext.save()
            worktreeStatuses.removeValue(forKey: worktreeID)
            pullRequestUpstreamStatuses.removeValue(forKey: worktreeID)
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
        await refreshPullRequestUpstreamStatuses(for: repository)
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
        let deleteAfterIntegration = draft.deleteAfterIntegration && !worktree.isPinned

        switch draft.method {
        case .localMerge:
            let outcome = await performLocalMerge(worktree, repository: repository, modelContext: modelContext)
            await refreshWorktreeStatuses(for: repository)
            if case .committed = outcome {
                pendingErrorMessage = "Integrated \(worktree.branchName) into \(repository.defaultBranch)."
                worktree.lifecycleState = .merged
                save(modelContext)
                if deleteAfterIntegration {
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
                worktree.shouldDeleteOnMerge = deleteAfterIntegration
                worktree.primaryContext = WorktreePrimaryContext(
                    kind: .pullRequest,
                    canonicalURL: prInfo.url,
                    title: draft.prTitle,
                    label: "PR",
                    provider: .github,
                    prNumber: prInfo.number,
                    ticketID: nil,
                    upstreamReference: worktree.primaryContext?.upstreamReference,
                    upstreamSHA: worktree.primaryContext?.upstreamSHA
                )
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
        for _: WorktreeRecord,
        repository _: ManagedRepository,
        in _: ModelContext
    ) {
        ensurePRMonitoringCoordinatorIfNeeded()
    }

    func stopPRMonitoring(for worktreeID: UUID) {
        // A single coordinator loop reads state from SwiftData each cycle; nothing to cancel per worktree.
    }

    func ensurePRMonitoringCoordinatorIfNeeded() {
        guard prMonitoringCoordinatorTask == nil else { return }
        prMonitoringCoordinatorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self.runPRMonitoringCycle()
            }
        }
    }

    private func runPRMonitoringCycle() async {
        guard let modelContext = storedModelContext else { return }
        let descriptor = FetchDescriptor<WorktreeRecord>()
        let allWorktrees = (try? modelContext.fetch(descriptor)) ?? []
        for worktree in allWorktrees {
            guard worktree.prNumber != nil, worktree.lifecycleState != .merged else { continue }
            guard let repository = worktree.repository,
                  let prNumber = worktree.resolvedPrimaryContext?.prNumber ?? worktree.prNumber
            else { continue }

            do {
                let pr = try await services.gitHubCLIService.loadPullRequest(number: prNumber, in: repository)
                if pr.status == .merged {
                    worktree.lifecycleState = .merged
                    save(modelContext)
                    if worktree.shouldDeleteOnMerge {
                        await removeWorktree(worktree, in: modelContext)
                    }
                }
            } catch {
                // Netzwerk- oder CLI-Fehler — nächsten Zyklus erneut versuchen
            }
        }
    }

    func restoreAllPRMonitoring(in modelContext: ModelContext) {
        ensurePRMonitoringCoordinatorIfNeeded()
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
