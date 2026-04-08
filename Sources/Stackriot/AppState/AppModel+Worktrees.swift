import Foundation
import SwiftData

extension AppModel {
    private struct RepositoryWorktreeReconcileResult {
        var didChange = false
        var addedWorktreeIDs: Set<UUID> = []
        var updatedWorktreeIDs: Set<UUID> = []
        var removedWorktreeIDs: Set<UUID> = []
    }

    struct AutoRebaseTarget: Equatable {
        let worktreeID: UUID
        let worktreePath: URL
        let branchName: String
        let ontoBranch: String
    }

    private struct IntegrationTarget {
        let worktree: WorktreeRecord
        let branchName: String
        let isDefaultTarget: Bool
    }

    private struct WorktreeCreationRequest {
        let mode: WorktreeCreationMode
        let branchName: String
        let sourceBranch: String
        let destinationRootPath: String?
        let ticketDetails: TicketDetails?
        let issueContext: String?
        let initialPlanText: String?
    }

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
            let request = try makeWorktreeCreationRequest(for: repository)
            let worktree: WorktreeRecord

            switch request.mode {
            case .ideaTree:
                worktree = try persistIdeaTree(
                    branchName: request.branchName,
                    repository: repository,
                    sourceBranch: request.sourceBranch,
                    destinationRootPath: request.destinationRootPath,
                    ticketDetails: request.ticketDetails,
                    issueContext: request.issueContext,
                    initialPlanText: request.initialPlanText,
                    in: modelContext
                )
                notifyOperationSuccess(
                    title: "IdeaTree created",
                    subtitle: repository.displayName,
                    body: "\(worktree.branchName) will materialize when a filesystem checkout is needed.",
                    userInfo: [
                        "repositoryID": repository.id.uuidString,
                        "worktreeID": worktree.id.uuidString,
                    ]
                )
            case .fullWorktree:
                let info = try await services.worktreeManager.createWorktree(
                    bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                    repositoryName: repository.displayName,
                    branchName: request.branchName,
                    sourceBranch: request.sourceBranch,
                    directoryName: request.branchName,
                    destinationRoot: request.destinationRootPath?.nilIfBlank.map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    }
                )
                worktree = try persistMaterializedWorktree(
                    branchName: request.branchName,
                    materializedPath: info.path.path,
                    repository: repository,
                    sourceBranch: request.sourceBranch,
                    destinationRootPath: request.destinationRootPath,
                    ticketDetails: request.ticketDetails,
                    issueContext: request.issueContext,
                    initialPlanText: request.initialPlanText,
                    in: modelContext
                )
                await refreshWorktreeStatuses(for: repository)
                notifyOperationSuccess(
                    title: "Worktree created",
                    subtitle: repository.displayName,
                    body: "\(worktree.branchName) is now available as a filesystem worktree.",
                    userInfo: [
                        "repositoryID": repository.id.uuidString,
                        "worktreeID": worktree.id.uuidString,
                    ]
                )
            }

            finishCreatedWorktree(worktree, in: repository)
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: worktreeDraft.creationMode == .ideaTree ? "IdeaTree creation failed" : "Worktree creation failed",
                subtitle: repository.displayName,
                body: error.localizedDescription,
                userInfo: ["repositoryID": repository.id.uuidString]
            )
        }
    }

    func createWorktreeFromTicket(for repository: ManagedRepository, in modelContext: ModelContext) async {
        await createWorktree(for: repository, in: modelContext)
    }

    private func resolvedSourceBranch(for repository: ManagedRepository) -> String {
        let sourceBranch = worktreeDraft.sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceBranch.isEmpty ? repository.defaultBranch : sourceBranch
    }

    private func makeWorktreeCreationRequest(for repository: ManagedRepository) throws -> WorktreeCreationRequest {
        let normalizedName = WorktreeManager.normalizedWorktreeName(from: worktreeDraft.branchName)
        guard !normalizedName.isEmpty else {
            throw StackriotError.branchNameRequired
        }

        let ticketDetails = worktreeDraft.hasConfirmedTicket ? worktreeDraft.selectedIssueDetails : nil
        return WorktreeCreationRequest(
            mode: worktreeDraft.creationMode,
            branchName: normalizedName,
            sourceBranch: resolvedSourceBranch(for: repository),
            destinationRootPath: worktreeDraft.destinationRootPath,
            ticketDetails: ticketDetails,
            issueContext: ticketDetails.map(compactIssueContext(for:)) ?? worktreeDraft.issueContext.nilIfBlank,
            initialPlanText: ticketDetails.map(initialPlan(from:))
        )
    }

    func childWorktrees(of parent: WorktreeRecord, in repository: ManagedRepository) -> [WorktreeRecord] {
        orderedWorktrees(
            repository.worktrees.filter { normalizedParentWorktreeID(for: $0, in: repository) == parent.id }
        )
    }

    func groupedRootWorktrees(from worktrees: [WorktreeRecord], in repository: ManagedRepository) -> [WorktreeRecord] {
        orderedWorktrees(
            worktrees.filter { worktree in
                guard let parentID = normalizedParentWorktreeID(for: worktree, in: repository) else { return true }
                return worktrees.contains(where: { $0.id == parentID }) == false
            }
        )
    }

    func canAssignParentWorktree(_ parent: WorktreeRecord?, to child: WorktreeRecord, in repository: ManagedRepository) -> Bool {
        guard let parent else { return true }
        if parent.id == child.id {
            return false
        }

        var visited: Set<UUID> = [child.id]
        var currentParentID = parent.parentWorktreeID
        while let resolvedParentID = currentParentID {
            if visited.contains(resolvedParentID) {
                return false
            }
            visited.insert(resolvedParentID)
            currentParentID = repository.worktrees.first(where: { $0.id == resolvedParentID })?.parentWorktreeID
        }
        return true
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

    @discardableResult
    func materializeIdeaTreeIfNeeded(
        _ worktree: WorktreeRecord,
        in repository: ManagedRepository,
        modelContext: ModelContext
    ) async -> WorktreeRecord? {
        if worktree.isDefaultBranchWorkspace {
            return worktree
        }
        if worktree.materializedURL != nil {
            if worktree.isIdeaTree {
                worktree.kind = .regular
                worktree.materializedAt = worktree.materializedAt ?? .now
                repository.updatedAt = .now
                save(modelContext)
            }
            _ = ensureWorktreeDiscoverySnapshot(for: worktree)
            return worktree
        }

        do {
            let previousURL = worktree.materializedURL
            let sourceBranch = worktree.sourceBranchName ?? repository.defaultBranch
            let info = try await services.worktreeManager.createWorktree(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                repositoryName: repository.displayName,
                branchName: worktree.branchName,
                sourceBranch: sourceBranch,
                directoryName: worktree.branchName,
                destinationRoot: worktree.destinationRootURL
            )
            worktree.sourceBranch = sourceBranch
            worktree.markMaterialized(at: info.path.path)
            repository.updatedAt = .now
            try modelContext.save()
            if let previousURL {
                services.devToolDiscovery.invalidateCache(for: previousURL)
            }
            invalidateWorktreeDiscoverySnapshot(for: worktree.id)
            _ = refreshWorktreeConfigurationSnapshot(for: worktree)
            refreshRepositorySidebarSnapshot(for: repository)
            refreshRepositoryDetailSnapshot(for: repository)
            await refreshWorktreeStatuses(for: repository)
            notifyOperationSuccess(
                title: "IdeaTree materialized",
                subtitle: repository.displayName,
                body: "\(worktree.branchName) is now available as a filesystem worktree.",
                userInfo: [
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
            return worktree
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "IdeaTree materialization failed",
                subtitle: repository.displayName,
                body: error.localizedDescription,
                userInfo: [
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
            return nil
        }
    }

    func summarizeQuickIntent() async {
        guard var session = quickIntentSession else { return }
        let input = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            pendingErrorMessage = "Quick Intent ist leer."
            return
        }

        session.isSummarizing = true
        quickIntentSession = session
        do {
            let summary = try await services.aiProviderService.summarizeTextForIntent(input)
            guard var updated = quickIntentSession, updated.id == session.id else { return }
            updated.summaryTitle = summary.title
            updated.text = summary.summary
            updated.branchName = WorktreeManager.normalizedWorktreeName(from: summary.title)
            updated.isSummarizing = false
            quickIntentSession = updated
        } catch {
            guard var updated = quickIntentSession, updated.id == session.id else { return }
            updated.isSummarizing = false
            quickIntentSession = updated
            pendingErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createIdeaTreeFromQuickIntent(
        repository: ManagedRepository,
        branchName: String,
        sourceBranch: String,
        parentWorktreeID: UUID?,
        initialIntentText: String,
        in modelContext: ModelContext
    ) throws -> WorktreeRecord {
        let normalizedBranchName = WorktreeManager.normalizedWorktreeName(from: branchName)
        guard !normalizedBranchName.isEmpty else {
            throw StackriotError.branchNameRequired
        }

        let worktree = try persistIdeaTree(
            branchName: normalizedBranchName,
            repository: repository,
            sourceBranch: sourceBranch,
            parentWorktreeID: parentWorktreeID,
            destinationRootPath: nil,
            ticketDetails: nil,
            issueContext: nil,
            initialPlanText: initialIntentText,
            in: modelContext
        )
        finishCreatedWorktree(worktree, in: repository)
        return worktree
    }

    func runQuickIntentCreateAction(
        planningAgent: AIAgentTool? = nil,
        executionAgent: AIAgentTool? = nil
    ) async {
        guard var session = quickIntentSession else { return }
        guard let modelContext = storedModelContext else {
            pendingErrorMessage = "Model context unavailable."
            return
        }

        let context = quickIntentRepositoryContext()
        guard let repository = context.repository else {
            pendingErrorMessage = "Waehle zuerst ein Repository aus."
            return
        }

        let initialIntentText = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !initialIntentText.isEmpty else {
            pendingErrorMessage = "Quick Intent ist leer."
            return
        }

        let requestedParent = session.useCurrentWorktreeAsParent ? context.worktree : nil
        let parentWorktreeID = requestedParent?.isDefaultBranchWorkspace == false ? requestedParent?.id : nil
        let sourceBranch = session.useCurrentWorktreeAsParent
            ? requestedParent?.branchName.nonEmpty ?? repository.defaultBranch
            : repository.defaultBranch
        let branchSeed = session.branchName.nonEmpty ?? session.summaryTitle.nonEmpty ?? initialIntentText
        let normalizedBranch = WorktreeManager.normalizedWorktreeName(from: branchSeed)

        session.isPerformingAction = true
        quickIntentSession = session

        do {
            let worktree = try createIdeaTreeFromQuickIntent(
                repository: repository,
                branchName: normalizedBranch,
                sourceBranch: sourceBranch,
                parentWorktreeID: parentWorktreeID,
                initialIntentText: initialIntentText,
                in: modelContext
            )

            if let planningAgent {
                await startAgentPlanDraft(
                    using: planningAgent,
                    for: worktree,
                    in: repository,
                    currentIntentText: initialIntentText,
                    modelContext: modelContext
                )
            } else if let executionAgent {
                await prepareAgentExecutionWithPlan(executionAgent, for: worktree, in: repository)
            }

            quickIntentSession = nil
            notifyOperationSuccess(
                title: "IdeaTree created",
                subtitle: repository.displayName,
                body: "\(worktree.branchName) wurde aus dem Quick Intent angelegt.",
                userInfo: [
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
        } catch {
            guard var updated = quickIntentSession, updated.id == session.id else {
                pendingErrorMessage = error.localizedDescription
                return
            }
            updated.isPerformingAction = false
            quickIntentSession = updated
            pendingErrorMessage = error.localizedDescription
        }
    }

    private func persistIdeaTree(
        branchName: String,
        repository: ManagedRepository,
        sourceBranch: String,
        parentWorktreeID: UUID? = nil,
        destinationRootPath: String?,
        ticketDetails: TicketDetails?,
        issueContext: String?,
        initialPlanText: String?,
        in modelContext: ModelContext
    ) throws -> WorktreeRecord {
        try persistWorktreeRecord(
            branchName: branchName,
            kind: .idea,
            materializedPath: nil,
            repository: repository,
            sourceBranch: sourceBranch,
            parentWorktreeID: parentWorktreeID,
            destinationRootPath: destinationRootPath,
            ticketDetails: ticketDetails,
            issueContext: issueContext,
            initialPlanText: initialPlanText,
            in: modelContext
        )
    }

    private func persistMaterializedWorktree(
        branchName: String,
        materializedPath: String,
        repository: ManagedRepository,
        sourceBranch: String,
        destinationRootPath: String?,
        ticketDetails: TicketDetails?,
        issueContext: String?,
        initialPlanText: String?,
        in modelContext: ModelContext
    ) throws -> WorktreeRecord {
        try persistWorktreeRecord(
            branchName: branchName,
            kind: .regular,
            materializedPath: materializedPath,
            repository: repository,
            sourceBranch: sourceBranch,
            parentWorktreeID: nil,
            destinationRootPath: destinationRootPath,
            ticketDetails: ticketDetails,
            issueContext: issueContext,
            initialPlanText: initialPlanText,
            in: modelContext
        )
    }

    private func persistWorktreeRecord(
        branchName: String,
        kind: WorktreeKind,
        materializedPath: String?,
        repository: ManagedRepository,
        sourceBranch: String,
        parentWorktreeID: UUID? = nil,
        destinationRootPath: String?,
        ticketDetails: TicketDetails?,
        issueContext: String?,
        initialPlanText: String?,
        in modelContext: ModelContext
    ) throws -> WorktreeRecord {
        let worktree = WorktreeRecord(
            branchName: branchName,
            kind: kind,
            issueContext: issueContext,
            ticketProvider: ticketDetails?.provider,
            ticketIdentifier: ticketDetails?.reference.id,
            ticketURL: ticketDetails?.url,
            path: materializedPath ?? "",
            materializedPath: materializedPath,
            sourceBranch: sourceBranch,
            parentWorktreeID: parentWorktreeID,
            destinationRootPath: destinationRootPath,
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
            try writeIntent(initialPlanText, for: worktree.id)
        }

        if worktree.materializedURL != nil {
            _ = refreshWorktreeConfigurationSnapshot(for: worktree)
        } else {
            invalidateWorktreeDiscoverySnapshot(for: worktree.id)
        }
        refreshRepositorySidebarSnapshot(for: repository)
        refreshRepositoryDetailSnapshot(for: repository)

        return worktree
    }

    func finishCreatedWorktree(_ worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectedWorktreeIDsByRepository[repository.id] = worktree.id
        terminalTabs.selectPlanTab(for: worktree.id)
        beginWorktreeSelectionTrace(repositoryID: repository.id, worktreeID: worktree.id)
        _ = ensureWorktreeDiscoverySnapshot(for: worktree)
        _ = refreshAvailableDevToolsCache(for: worktree)
        refreshRepositorySidebarSnapshot(for: repository)
        refreshRepositoryDetailSnapshot(for: repository)
        isWorktreeSheetPresented = false
    }

    @discardableResult
    func reconcileRepositoryWorktrees(for repository: ManagedRepository, in modelContext: ModelContext) async -> Bool {
        await reconcileRepositoryWorktrees(forRepositoryID: repository.id, in: modelContext)
    }

    @discardableResult
    func reconcileRepositoryWorktrees(forRepositoryID repositoryID: UUID, in modelContext: ModelContext) async -> Bool {
        guard let repository = repositoryRecord(with: repositoryID) else {
            stopRepositoryWorktreeMonitoring(for: repositoryID)
            return false
        }
        guard repository.status == .ready else {
            stopRepositoryWorktreeMonitoring(for: repositoryID)
            return false
        }

        do {
            let bareRepositoryPath = URL(fileURLWithPath: repository.bareRepositoryPath)
            let entries = try await services.repositoryManager.listWorktreeEntries(in: bareRepositoryPath)
            let result = reconcileRepositoryWorktreeEntries(entries, for: repository, in: modelContext)
            if result.didChange {
                repository.updatedAt = .now
                try modelContext.save()
                refreshRepositorySidebarSnapshot(for: repository)
                refreshRepositoryDetailSnapshot(for: repository)
                primeWorktreeConfigurationSnapshots(for: repository)
                for worktreeID in result.addedWorktreeIDs.union(result.updatedWorktreeIDs) {
                    guard let worktree = repository.worktrees.first(where: { $0.id == worktreeID }),
                          worktree.materializedURL != nil
                    else {
                        continue
                    }
                    _ = refreshAvailableDevToolsCache(for: worktree)
                    Task {
                        await refreshAvailableRunConfigurationsCache(for: worktree)
                    }
                }
            }
            await updateRepositoryWorktreeMonitoring(for: repository)
            await refreshWorktreeStatuses(for: repository)
            return result.didChange
        } catch {
            pendingErrorMessage = error.localizedDescription
            return false
        }
    }

    private func reconcileRepositoryWorktreeEntries(
        _ entries: [GitWorktreeListEntry],
        for repository: ManagedRepository,
        in modelContext: ModelContext
    ) -> RepositoryWorktreeReconcileResult {
        let defaultBranch = repository.defaultBranch
        var result = RepositoryWorktreeReconcileResult()
        var matchedWorktreeIDs: Set<UUID> = []
        var remainingWorktrees = repository.worktrees

        for entry in entries where !entry.isBare {
            let resolvedBranchName = resolvedBranchName(for: entry, defaultBranch: defaultBranch)
            guard let match = matchedRepositoryWorktree(
                for: entry,
                resolvedBranchName: resolvedBranchName,
                in: remainingWorktrees,
                repository: repository
            ) else {
                let worktree = WorktreeRecord(
                    branchName: resolvedBranchName,
                    isDefaultBranchWorkspace: resolvedBranchName == defaultBranch,
                    path: entry.path,
                    materializedPath: entry.path,
                    repository: repository
                )
                repository.worktrees.append(worktree)
                modelContext.insert(worktree)
                matchedWorktreeIDs.insert(worktree.id)
                result.addedWorktreeIDs.insert(worktree.id)
                result.didChange = true
                continue
            }

            remainingWorktrees.removeAll(where: { $0.id == match.id })
            matchedWorktreeIDs.insert(match.id)
            if updateRepositoryWorktree(match, with: entry, resolvedBranchName: resolvedBranchName, defaultBranch: defaultBranch) {
                result.updatedWorktreeIDs.insert(match.id)
                result.didChange = true
            }
        }

        let removableWorktrees = repository.worktrees.filter {
            !matchedWorktreeIDs.contains($0.id) && $0.isMaterialized && !$0.isIdeaTree
        }

        if !removableWorktrees.isEmpty {
            for worktree in removableWorktrees {
                cleanupRepositoryWorktreeState(for: worktree, repository: repository, modelContext: modelContext)
                result.removedWorktreeIDs.insert(worktree.id)
            }
            result.didChange = true
        }

        if result.didChange {
            let survivingWorktrees = repository.worktrees.filter { !result.removedWorktreeIDs.contains($0.id) }
            let remainingSelection = selectedWorktreeIDsByRepository[repository.id]
            if let selectedID = remainingSelection, result.removedWorktreeIDs.contains(selectedID) {
                let fallbackWorktreeID = survivingWorktrees.first(where: { $0.isDefaultBranchWorkspace })?.id
                    ?? survivingWorktrees.first?.id
                selectedWorktreeIDsByRepository[repository.id] = fallbackWorktreeID
                if let fallbackWorktreeID {
                    terminalTabs.selectPlanTab(for: fallbackWorktreeID)
                }
            }
        }

        return result
    }

    private func matchedRepositoryWorktree(
        for entry: GitWorktreeListEntry,
        resolvedBranchName: String,
        in worktrees: [WorktreeRecord],
        repository: ManagedRepository
    ) -> WorktreeRecord? {
        let entryPath = URL(fileURLWithPath: entry.path).standardizedFileURL.path

        if let exactPathMatch = worktrees.first(where: { worktree in
            normalizedWorktreePath(worktree.materializedPath) == entryPath
                || normalizedWorktreePath(worktree.path) == entryPath
                || normalizedWorktreePath(worktree.projectedMaterializationPath) == entryPath
        }) {
            return exactPathMatch
        }

        if resolvedBranchName == repository.defaultBranch,
           let defaultBranchMatch = worktrees.first(where: { $0.isDefaultBranchWorkspace })
        {
            return defaultBranchMatch
        }

        if let branchMatch = worktrees.first(where: { $0.branchName == resolvedBranchName }) {
            return branchMatch
        }

        return nil
    }

    private func updateRepositoryWorktree(
        _ worktree: WorktreeRecord,
        with entry: GitWorktreeListEntry,
        resolvedBranchName: String,
        defaultBranch: String
    ) -> Bool {
        var didChange = false
        let entryPath = entry.path
        let isDefaultBranchWorkspace = resolvedBranchName == defaultBranch

        if worktree.branchName != resolvedBranchName {
            worktree.branchName = resolvedBranchName
            didChange = true
        }

        if worktree.isDefaultBranchWorkspace != isDefaultBranchWorkspace {
            worktree.isDefaultBranchWorkspace = isDefaultBranchWorkspace
            didChange = true
        }

        if worktree.materializedPath != entryPath {
            worktree.markMaterialized(at: entryPath, kind: .regular)
            didChange = true
        } else if worktree.kind == .idea {
            worktree.kind = .regular
            worktree.materializedAt = worktree.materializedAt ?? .now
            didChange = true
        }

        return didChange
    }

    private func cleanupRepositoryWorktreeState(
        for worktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) {
        stopPRMonitoring(for: worktree.id)
        if let worktreeURL = worktree.materializedURL {
            services.devToolDiscovery.invalidateCache(for: worktreeURL)
        }
        invalidateWorktreeDiscoverySnapshot(for: worktree.id)
        invalidateRunConfigurationCache(for: worktree.id)
        worktreeStatuses.removeValue(forKey: worktree.id)
        pullRequestUpstreamStatuses.removeValue(forKey: worktree.id)
        devContainerStatesByWorktreeID.removeValue(forKey: worktree.id)
        terminalTabs.removeWorktree(worktree.id)
        modelContext.delete(worktree)
        repository.updatedAt = .now
    }

    private func resolvedBranchName(for entry: GitWorktreeListEntry, defaultBranch: String) -> String {
        if let branchShortName = entry.branchShortName {
            return branchShortName
        }
        let fallbackPathComponent = URL(fileURLWithPath: entry.path).lastPathComponent
        return fallbackPathComponent.nonEmpty ?? defaultBranch
    }

    private func normalizedWorktreePath(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
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
            if worktree.isIdeaTree {
                worktree.destinationRootPath = newParentDirectory.path
                repository.updatedAt = .now
                save(modelContext)
                notifyOperationSuccess(
                    title: "IdeaTree updated",
                    subtitle: repository.displayName,
                    body: "\(worktree.branchName) will materialize under \(newParentDirectory.lastPathComponent).",
                    userInfo: [
                        "repositoryID": repository.id.uuidString,
                        "worktreeID": worktree.id.uuidString,
                    ]
                )
                return
            }
            guard let worktreeURL = worktree.materializedURL else {
                throw StackriotError.worktreeUnavailable
            }
            let previousURL = worktreeURL

            let destination = try await services.worktreeManager.moveWorktree(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                worktreePath: worktreeURL,
                newParentDirectory: newParentDirectory,
                directoryName: worktree.branchName
            )

            worktree.markMaterialized(at: destination.path)
            worktree.lastOpenedAt = .now
            repository.updatedAt = .now
            save(modelContext)
            services.devToolDiscovery.invalidateCache(for: previousURL)
            invalidateWorktreeDiscoverySnapshot(for: worktree.id)
            _ = refreshWorktreeConfigurationSnapshot(for: worktree)
            refreshRepositorySidebarSnapshot(for: repository)
            refreshRepositoryDetailSnapshot(for: repository)
            await refreshWorktreeStatuses(for: repository)
            notifyOperationSuccess(
                title: "Worktree moved",
                subtitle: repository.displayName,
                body: "\(worktree.branchName) moved to \(destination.lastPathComponent).",
                userInfo: [
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "Worktree move failed",
                subtitle: repository.displayName,
                body: error.localizedDescription,
                userInfo: [
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
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

    func discardAgentImplementation(
        _ worktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) async {
        guard let worktreePath = worktree.materializedURL else {
            pendingErrorMessage = "Worktree ist nicht materialisiert."
            return
        }
        let sourceBranch = worktree.sourceBranchName ?? repository.defaultBranch
        do {
            try await services.worktreeManager.resetToSourceBranch(
                worktreePath: worktreePath,
                sourceBranch: sourceBranch
            )
            invalidateWorktreeDiscoverySnapshot(for: worktree.id)
            await refreshWorktreeStatuses(for: repository)
            notifyOperationSuccess(
                title: "AI-Implementierung verworfen",
                subtitle: repository.displayName,
                body: "\(worktree.branchName) wurde auf \(sourceBranch) zurückgesetzt.",
                userInfo: [
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "Fehler beim Verwerfen",
                subtitle: repository.displayName,
                body: error.localizedDescription,
                userInfo: ["worktreeID": worktree.id.uuidString]
            )
        }
    }

    func removeWorktree(_ worktree: WorktreeRecord, in modelContext: ModelContext, notifySuccess: Bool = true) async {
        do {
            if worktree.isDefaultBranchWorkspace {
                throw StackriotError.commandFailed("The default workspace cannot be removed.")
            }
            guard let repository = worktree.repository else {
                throw StackriotError.unsupportedRepositoryPath
            }

            let worktreeID = worktree.id
            let worktreePath = worktree.materializedPath
            let repositoryID = repository.id
            let bareRepositoryPath = repository.bareRepositoryPath
            for child in repository.childWorktrees(of: worktree) {
                child.parentWorktreeID = nil
            }
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

            if let worktreePath {
                try await services.worktreeManager.removeWorktree(
                    bareRepositoryPath: URL(fileURLWithPath: bareRepositoryPath),
                    worktreePath: URL(fileURLWithPath: worktreePath)
                )
            }

            stopPRMonitoring(for: worktreeID)
            if let worktreeURL = worktree.materializedURL {
                services.devToolDiscovery.invalidateCache(for: worktreeURL)
            }
            invalidateWorktreeDiscoverySnapshot(for: worktreeID)
            invalidateRunConfigurationCache(for: worktreeID)
            modelContext.delete(worktree)
            repository.updatedAt = .now
            try modelContext.save()
            worktreeStatuses.removeValue(forKey: worktreeID)
            pullRequestUpstreamStatuses.removeValue(forKey: worktreeID)
            devContainerStatesByWorktreeID.removeValue(forKey: worktreeID)
            for runID in runIDsForWorktree {
                cancelAutoHide(for: runID)
            }
            terminalTabs.removeWorktree(worktreeID)
            if selectedWorktreeIDsByRepository[repositoryID] == worktreeID {
                selectedWorktreeIDsByRepository[repositoryID] = remainingWorktreeID
            }
            refreshRepositorySidebarSnapshot(for: repository)
            refreshRepositoryDetailSnapshot(for: repository)
            await refreshWorktreeStatuses(for: repository)
            if notifySuccess {
                notifyOperationSuccess(
                    title: "Worktree removed",
                    subtitle: repository.displayName,
                    body: "\(worktree.branchName) was removed.",
                    userInfo: [
                        "repositoryID": repository.id.uuidString,
                        "worktreeID": worktreeID.uuidString,
                    ]
                )
            }
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "Worktree removal failed",
                subtitle: worktree.repository?.displayName,
                body: error.localizedDescription,
                userInfo: ["worktreeID": worktree.id.uuidString]
            )
        }
    }

    func refreshWorktreeStatuses(for repository: ManagedRepository, allowAutoRebase: Bool = true) async {
        recordWorktreeStatusRefreshStart(for: repository.id)
        let repositoryID = repository.id
        if worktreeStatusRefreshTasksByRepositoryID[repositoryID] != nil {
            pendingWorktreeStatusRefreshRepositoryIDs.insert(repositoryID)
            worktreeStatusRefreshGenerationByRepositoryID[repositoryID, default: 0] += 1
            return
        }

        while true {
            pendingWorktreeStatusRefreshRepositoryIDs.remove(repositoryID)
            let generation = worktreeStatusRefreshGenerationByRepositoryID[repositoryID, default: 0] + 1
            worktreeStatusRefreshGenerationByRepositoryID[repositoryID] = generation

            let snapshot = makeWorktreeStatusRefreshSnapshot(for: repository, generation: generation)
            let statusService = services.worktreeStatusService
            let worktreeManager = services.worktreeManager
            let gitHubService = services.gitHubCLIService

            let task = Task.detached(priority: .utility) {
                await AppModel.computeWorktreeStatusRefresh(
                    snapshot: snapshot,
                    statusService: statusService,
                    worktreeManager: worktreeManager,
                    gitHubService: gitHubService
                )
            }
            worktreeStatusRefreshTasksByRepositoryID[repositoryID] = task

            let result = await task.value
            worktreeStatusRefreshTasksByRepositoryID[repositoryID] = nil

            if worktreeStatusRefreshGenerationByRepositoryID[repositoryID] == result.generation {
                applyWorktreeStatusRefreshResult(result, to: repository)
                refreshRepositoryDetailSnapshot(for: repository)
            }

            guard pendingWorktreeStatusRefreshRepositoryIDs.contains(repositoryID) else {
                break
            }
        }

        if allowAutoRebase {
            await autoRebaseEligibleWorktreesIfNeeded(for: repository)
        }
    }

    func integrateIntoDefaultBranch(
        _ sourceWorktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) async {
        guard !sourceWorktree.isDefaultBranchWorkspace else { return }
        _ = await performLocalMerge(sourceWorktree, repository: repository, modelContext: modelContext)
        // Success is reflected by the refreshed worktree state; avoid a post-merge confirmation dialog.
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
            if case .committed = outcome {
                worktree.lifecycleState = .merged
                save(modelContext)
                if deleteAfterIntegration {
                    await removeWorktree(worktree, in: modelContext, notifySuccess: false)
                } else {
                    await refreshWorktreeStatuses(for: repository)
                }
            } else if case .conflict = outcome {
                await refreshWorktreeStatuses(for: repository)
            }

        case .githubPR:
            do {
                let target = try await resolvedIntegrationTarget(for: worktree, repository: repository, modelContext: modelContext)
                guard await materializeIdeaTreeIfNeeded(worktree, in: repository, modelContext: modelContext) != nil,
                      let worktreeURL = worktree.materializedURL
                else {
                    return
                }

                let publishResult: PublishBranchResult
                do {
                    publishResult = try await ensurePublishedBranchForPullRequest(
                        worktreeURL: worktreeURL,
                        repository: repository
                    )
                } catch {
                    pendingErrorMessage = error.localizedDescription
                    notifyOperationFailure(
                        title: "Branch publish failed",
                        subtitle: repository.displayName,
                        body: error.localizedDescription,
                        userInfo: [
                            "repositoryID": repository.id.uuidString,
                            "worktreeID": worktree.id.uuidString,
                        ]
                    )
                    return
                }

                let prInfo: GitHubCLIService.PRInfo
                do {
                    prInfo = try await services.gitHubCLIService.createPR(
                        worktreePath: worktreeURL,
                        title: draft.prTitle,
                        body: draft.prBody,
                        baseBranch: target.branchName,
                        headBranch: publishResult.branch
                    )
                } catch {
                    pendingErrorMessage = error.localizedDescription
                    notifyOperationFailure(
                        title: "Pull request creation failed",
                        subtitle: repository.displayName,
                        body: error.localizedDescription,
                        userInfo: [
                            "repositoryID": repository.id.uuidString,
                            "worktreeID": worktree.id.uuidString,
                        ]
                    )
                    return
                }

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
                repository.updatedAt = .now
                scheduleWorktreeStatusRefresh(for: repository)
                notifyOperationSuccess(
                    title: "Pull request created",
                    subtitle: repository.displayName,
                    body: "#\(prInfo.number) is ready for \(worktree.branchName).",
                    userInfo: [
                        "repositoryID": repository.id.uuidString,
                        "worktreeID": worktree.id.uuidString,
                    ]
                )
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
        let target: IntegrationTarget
        do {
            target = try await resolvedIntegrationTarget(for: sourceWorktree, repository: repository, modelContext: modelContext)
        } catch {
            pendingErrorMessage = error.localizedDescription
            return .failed
        }
        guard await materializeIdeaTreeIfNeeded(sourceWorktree, in: repository, modelContext: modelContext) != nil,
              let targetWorktreeURL = target.worktree.materializedURL
        else {
            return .failed
        }
        do {
            let result = try await services.worktreeStatusService.integrate(
                sourceBranch: sourceWorktree.branchName,
                targetBranch: target.branchName,
                targetWorktreePath: targetWorktreeURL
            )
            switch result {
            case .committed:
                selectedWorktreeIDsByRepository[repository.id] = target.worktree.id
                return .committed
            case let .conflicts(message):
                let draft = IntegrationConflictDraft(
                    repositoryID: repository.id,
                    sourceWorktreeID: sourceWorktree.id,
                    defaultWorktreeID: target.worktree.id,
                    sourceBranch: sourceWorktree.branchName,
                    defaultBranch: target.branchName,
                    message: message
                )
                selectedWorktreeIDsByRepository[repository.id] = target.worktree.id
                let preferredAgent = sourceWorktree.assignedAgent
                if preferredAgent != .none, availableAgents.contains(preferredAgent) {
                    await launchConflictResolutionAgent(preferredAgent, for: draft, in: modelContext)
                } else {
                    pendingErrorMessage = message
                    notifyOperationFailure(
                        title: "Merge conflicts detected",
                        subtitle: repository.displayName,
                        body: "Conflicts occurred while integrating \(sourceWorktree.branchName) into \(target.branchName). Resolve them manually or assign an available agent."
                    )
                }
                return .conflict
            }
        } catch {
            pendingErrorMessage = error.localizedDescription
            return .failed
        }
    }

    private func resolvedIntegrationTarget(
        for sourceWorktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) async throws -> IntegrationTarget {
        if let parentID = sourceWorktree.parentWorktreeID,
           let parentWorktree = repository.worktrees.first(where: { $0.id == parentID })
        {
            guard let parentURL = parentWorktree.materializedURL else {
                throw StackriotError.commandFailed("Der Parent-Worktree \(parentWorktree.branchName) muss materialisiert sein, bevor ein Sub-Worktree integriert oder als PR gegen ihn angelegt wird.")
            }
            _ = parentURL
            return IntegrationTarget(
                worktree: parentWorktree,
                branchName: parentWorktree.branchName,
                isDefaultTarget: false
            )
        }

        guard let defaultWorktree = await ensureDefaultBranchWorkspace(for: repository, in: modelContext) else {
            throw StackriotError.worktreeUnavailable
        }
        return IntegrationTarget(
            worktree: defaultWorktree,
            branchName: repository.defaultBranch,
            isDefaultTarget: true
        )
    }

    private func normalizedParentWorktreeID(for worktree: WorktreeRecord, in repository: ManagedRepository) -> UUID? {
        guard let parentID = worktree.parentWorktreeID, parentID != worktree.id else { return nil }
        return repository.worktrees.contains(where: { $0.id == parentID }) ? parentID : nil
    }

    private func orderedWorktrees(_ worktrees: [WorktreeRecord]) -> [WorktreeRecord] {
        worktrees.sorted { lhs, rhs in
            if lhs.isDefaultBranchWorkspace != rhs.isDefaultBranchWorkspace {
                return lhs.isDefaultBranchWorkspace
            }
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            if lhs.isIdeaTree != rhs.isIdeaTree {
                return lhs.isIdeaTree
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func autoRebaseTargets(for repository: ManagedRepository) -> [AutoRebaseTarget] {
        repository.worktrees.compactMap { worktree in
            guard !worktree.isDefaultBranchWorkspace else { return nil }
            guard worktree.resolvedPrimaryContext?.kind != .pullRequest, worktree.prNumber == nil else { return nil }
            guard worktree.allowsSyncFromDefaultBranch else { return nil }
            guard let worktreeURL = worktree.materializedURL else { return nil }
            guard let status = worktreeStatuses[worktree.id] else { return nil }
            guard status.behindCount > 0, !status.hasUncommittedChanges, !status.hasConflicts else { return nil }
            let ontoBranch = autoRebaseTargetBranch(for: worktree, in: repository)
            return AutoRebaseTarget(
                worktreeID: worktree.id,
                worktreePath: worktreeURL,
                branchName: worktree.branchName,
                ontoBranch: ontoBranch
            )
        }
    }

    private func autoRebaseTargetBranch(for worktree: WorktreeRecord, in repository: ManagedRepository) -> String {
        if let parentID = worktree.parentWorktreeID,
           let parent = repository.worktrees.first(where: { $0.id == parentID }),
           parent.materializedURL != nil
        {
            return parent.branchName
        }
        return repository.defaultBranch
    }

    private func autoRebaseEligibleWorktreesIfNeeded(for repository: ManagedRepository) async {
        let repositoryID = repository.id
        guard !autoRebasingRepositoryIDs.contains(repositoryID) else {
            pendingAutoRebaseRepositoryIDs.insert(repositoryID)
            return
        }

        autoRebasingRepositoryIDs.insert(repositoryID)
        defer {
            autoRebasingRepositoryIDs.remove(repositoryID)
            pendingAutoRebaseRepositoryIDs.remove(repositoryID)
        }

        while true {
            pendingAutoRebaseRepositoryIDs.remove(repositoryID)
            var didRebase = false

            for target in autoRebaseTargets(for: repository) {
                do {
                    try await services.worktreeStatusService.rebase(
                        worktreePath: target.worktreePath,
                        onto: target.ontoBranch
                    )
                    didRebase = true
                } catch {
                    pendingErrorMessage = error.localizedDescription
                    notifyOperationFailure(
                        title: "Auto-rebase failed",
                        subtitle: repository.displayName,
                        body: "Could not rebase \(target.branchName) onto \(target.ontoBranch). Resolve it manually if you want to continue.",
                        userInfo: [
                            "repositoryID": repository.id.uuidString,
                            "worktreeID": target.worktreeID.uuidString,
                        ]
                    )
                }
            }

            if didRebase {
                await refreshWorktreeStatuses(for: repository, allowAutoRebase: false)
            }

            guard pendingAutoRebaseRepositoryIDs.contains(repositoryID) else {
                break
            }
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
                    notifyOperationSuccess(
                        title: "Pull request merged",
                        subtitle: repository.displayName,
                        body: "\(worktree.branchName) was merged upstream.",
                        userInfo: [
                            "repositoryID": repository.id.uuidString,
                            "worktreeID": worktree.id.uuidString,
                        ]
                    )
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
        guard let worktreeURL = worktree.materializedURL else {
            return WorkspaceDiffSnapshot(files: [])
        }
        do {
            return try await services.worktreeStatusService.loadUncommittedDiff(
                worktreePath: worktreeURL
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
        guard await materializeIdeaTreeIfNeeded(worktree, in: repository, modelContext: modelContext) != nil,
              let worktreeURL = worktree.materializedURL
        else {
            return
        }
        do {
            switch strategy {
            case .rebase:
                do {
                    try await services.worktreeStatusService.rebase(
                        worktreePath: worktreeURL,
                        onto: repository.defaultBranch
                    )
                } catch {
                    pendingErrorMessage = error.localizedDescription
                    notifyOperationFailure(
                        title: "Rebase failed",
                        subtitle: repository.displayName,
                        body: "Could not rebase \(worktree.branchName) onto \(repository.defaultBranch). Start a merge manually if you want to continue."
                    )
                    return
                }
            case .merge:
                try await services.worktreeStatusService.merge(
                    worktreePath: worktreeURL,
                    from: repository.defaultBranch
                )
            }

            await refreshWorktreeStatuses(for: repository)
            _ = modelContext
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func scheduleWorktreeStatusRefresh(for repository: ManagedRepository) {
        Task { @MainActor [weak self] in
            await self?.refreshWorktreeStatuses(for: repository)
        }
    }

    private func makeWorktreeStatusRefreshSnapshot(
        for repository: ManagedRepository,
        generation: Int
    ) -> WorktreeStatusRefreshSnapshot {
        let defaultBranch = repository.defaultBranch
        let defaultRemoteName = resolvedDefaultRemote(for: repository)?.name ?? "origin"
        let remotes = repository.remotes.map(remoteExecutionContext(for:))

        let statusItems = repository.worktrees.compactMap { worktree -> WorktreeStatusRefreshItem? in
            guard let worktreeURL = worktree.materializedURL else { return nil }
            let compareBranch = worktree.isDefaultBranchWorkspace
                ? "\(defaultRemoteName)/\(defaultBranch)"
                : autoRebaseTargetBranch(for: worktree, in: repository)
            return WorktreeStatusRefreshItem(
                worktreeID: worktree.id,
                worktreePath: worktreeURL.path,
                compareBranch: compareBranch
            )
        }

        let pullRequestItems = repository.worktrees.compactMap { worktree -> PullRequestStatusRefreshItem? in
            guard let prNumber = worktree.resolvedPrimaryContext?.prNumber ?? worktree.prNumber else { return nil }
            return PullRequestStatusRefreshItem(
                worktreeID: worktree.id,
                prNumber: prNumber,
                storedHeadSHA: worktree.resolvedPrimaryContext?.upstreamSHA,
                worktreePath: worktree.materializedURL?.path
            )
        }

        return WorktreeStatusRefreshSnapshot(
            repositoryID: repository.id,
            generation: generation,
            githubRepositoryTarget: GitHubCLIService.repositoryTarget(
                remotes: remotes,
                defaultRemoteName: repository.defaultRemoteName
            ),
            materializedWorktreeIDs: Set(statusItems.map(\.worktreeID)),
            statusItems: statusItems,
            pullRequestItems: pullRequestItems
        )
    }

    private func applyWorktreeStatusRefreshResult(
        _ result: WorktreeStatusRefreshResult,
        to repository: ManagedRepository
    ) {
        let repositoryWorktreeIDs = Set(repository.worktrees.map(\.id))

        for worktreeID in repositoryWorktreeIDs.subtracting(result.materializedWorktreeIDs) {
            worktreeStatuses.removeValue(forKey: worktreeID)
        }
        for (worktreeID, status) in result.statuses {
            worktreeStatuses[worktreeID] = status
        }

        let pullRequestWorktreeIDs = Set(repository.worktrees.compactMap { worktree in
            (worktree.resolvedPrimaryContext?.kind == .pullRequest || worktree.prNumber != nil) ? worktree.id : nil
        })
        for worktreeID in repositoryWorktreeIDs.subtracting(pullRequestWorktreeIDs) {
            pullRequestUpstreamStatuses.removeValue(forKey: worktreeID)
        }
        for (worktreeID, status) in result.pullRequestStatuses {
            pullRequestUpstreamStatuses[worktreeID] = status
        }
    }

    private func pullRequestCreationRemote(for repository: ManagedRepository) throws -> RemoteExecutionContext {
        if let remote = resolvedDefaultRemote(for: repository) {
            return remoteExecutionContext(for: remote)
        }
        throw StackriotError.remoteNameRequired
    }

    private func ensurePublishedBranchForPullRequest(
        worktreeURL: URL,
        repository: ManagedRepository
    ) async throws -> PublishBranchResult {
        let remote = try pullRequestCreationRemote(for: repository)
        return try await services.repositoryManager.publishCurrentBranchIfNeeded(
            worktreePath: worktreeURL,
            remote: remote
        )
    }

    nonisolated static func computeWorktreeStatusRefresh(
        snapshot: WorktreeStatusRefreshSnapshot,
        statusService: WorktreeStatusService,
        worktreeManager: WorktreeManager,
        gitHubService: GitHubCLIService
    ) async -> WorktreeStatusRefreshResult {
        let statuses = await withTaskGroup(of: (UUID, WorktreeStatus).self, returning: [UUID: WorktreeStatus].self) { group in
            for item in snapshot.statusItems {
                group.addTask {
                    let status = await statusService.fetchStatus(
                        worktreePath: URL(fileURLWithPath: item.worktreePath),
                        defaultBranch: item.compareBranch
                    )
                    return (item.worktreeID, status)
                }
            }

            var statuses: [UUID: WorktreeStatus] = [:]
            for await (worktreeID, status) in group {
                statuses[worktreeID] = status
            }
            return statuses
        }

        let pullRequestStatuses = await withTaskGroup(
            of: (UUID, PullRequestUpstreamStatus).self,
            returning: [UUID: PullRequestUpstreamStatus].self
        ) { group in
            for item in snapshot.pullRequestItems {
                group.addTask {
                    guard let repositoryTarget = snapshot.githubRepositoryTarget else {
                        return (
                            item.worktreeID,
                            PullRequestUpstreamStatus(
                                state: .open,
                                remoteHeadSHA: item.storedHeadSHA ?? "",
                                localHeadSHA: nil,
                                storedHeadSHA: item.storedHeadSHA,
                                errorMessage: "Kein GitHub-Remote fuer dieses Repository konfiguriert."
                            )
                        )
                    }

                    do {
                        let pr = try await gitHubService.loadPullRequest(
                            number: item.prNumber,
                            repositoryTarget: repositoryTarget
                        )
                        let localHead: String?
                        if let worktreePath = item.worktreePath {
                            localHead = try? await worktreeManager.currentRevision(
                                worktreePath: URL(fileURLWithPath: worktreePath)
                            )
                        } else {
                            localHead = nil
                        }

                        return (
                            item.worktreeID,
                            PullRequestUpstreamStatus(
                                state: pr.status,
                                remoteHeadSHA: pr.headRefOID,
                                localHeadSHA: localHead,
                                storedHeadSHA: item.storedHeadSHA,
                                errorMessage: nil
                            )
                        )
                    } catch {
                        return (
                            item.worktreeID,
                            PullRequestUpstreamStatus(
                                state: .open,
                                remoteHeadSHA: item.storedHeadSHA ?? "",
                                localHeadSHA: nil,
                                storedHeadSHA: item.storedHeadSHA,
                                errorMessage: error.localizedDescription
                            )
                        )
                    }
                }
            }

            var statuses: [UUID: PullRequestUpstreamStatus] = [:]
            for await (worktreeID, status) in group {
                statuses[worktreeID] = status
            }
            return statuses
        }

        return WorktreeStatusRefreshResult(
            repositoryID: snapshot.repositoryID,
            generation: snapshot.generation,
            materializedWorktreeIDs: snapshot.materializedWorktreeIDs,
            statuses: statuses,
            pullRequestStatuses: pullRequestStatuses
        )
    }
}
