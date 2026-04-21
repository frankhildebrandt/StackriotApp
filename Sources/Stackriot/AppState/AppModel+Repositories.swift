import Foundation
import SwiftData

enum PathRelocationScope: String, Sendable, Equatable {
    case repositories
    case worktrees

    var title: String {
        switch self {
        case .repositories:
            "repositories"
        case .worktrees:
            "worktrees"
        }
    }

    var singularTitle: String {
        switch self {
        case .repositories:
            "repository"
        case .worktrees:
            "worktree"
        }
    }
}

struct PathRelocationRequest: Identifiable, Sendable, Equatable {
    let id: UUID
    let scope: PathRelocationScope
    let oldLocation: AppPathLocation
    let oldCustomPath: String?
    let newLocation: AppPathLocation
    let newCustomPath: String?
    let oldRoot: URL
    let newRoot: URL
    let affectedCount: Int

    init(
        scope: PathRelocationScope,
        oldLocation: AppPathLocation,
        oldCustomPath: String?,
        newLocation: AppPathLocation,
        newCustomPath: String?,
        oldRoot: URL,
        newRoot: URL,
        affectedCount: Int
    ) {
        id = UUID()
        self.scope = scope
        self.oldLocation = oldLocation
        self.oldCustomPath = oldCustomPath?.nilIfBlank
        self.newLocation = newLocation
        self.newCustomPath = newCustomPath?.nilIfBlank
        self.oldRoot = oldRoot.standardizedFileURL
        self.newRoot = newRoot.standardizedFileURL
        self.affectedCount = affectedCount
    }
}

struct PathRelocationProgress: Sendable, Equatable {
    let scope: PathRelocationScope
    let totalCount: Int
    var completedCount: Int
    var currentItemName: String?
    let startedAt: Date

    var progressLabel: String {
        "\(completedCount) / \(max(totalCount, 1)) \(scope.title)"
    }
}

extension AppModel {
    func preparePathRelocationRequest(
        scope: PathRelocationScope,
        currentLocation: AppPathLocation,
        currentCustomPath: String?,
        newLocation: AppPathLocation,
        newCustomPath: String?,
        modelContext: ModelContext
    ) -> PathRelocationRequest? {
        let normalizedCurrentCustomPath = currentCustomPath?.nilIfBlank
        let normalizedNewCustomPath = newCustomPath?.nilIfBlank
        let oldBase = AppPaths.baseDirectory(location: currentLocation, customPath: normalizedCurrentCustomPath)
        let newBase = AppPaths.baseDirectory(location: newLocation, customPath: normalizedNewCustomPath)
        let oldRoot = scope == .repositories ? AppPaths.repositoriesRoot(in: oldBase) : AppPaths.worktreesRoot(in: oldBase)
        let newRoot = scope == .repositories ? AppPaths.repositoriesRoot(in: newBase) : AppPaths.worktreesRoot(in: newBase)
        guard oldRoot.standardizedFileURL != newRoot.standardizedFileURL else {
            return nil
        }

        let affectedCount: Int
        switch scope {
        case .repositories:
            let descriptor = FetchDescriptor<ManagedRepository>(sortBy: [SortDescriptor(\.displayName)])
            affectedCount = (try? modelContext.fetch(descriptor).count) ?? 0
        case .worktrees:
            let descriptor = FetchDescriptor<WorktreeRecord>()
            affectedCount = (try? modelContext.fetch(descriptor).count) ?? 0
        }

        return PathRelocationRequest(
            scope: scope,
            oldLocation: currentLocation,
            oldCustomPath: normalizedCurrentCustomPath,
            newLocation: newLocation,
            newCustomPath: normalizedNewCustomPath,
            oldRoot: oldRoot,
            newRoot: newRoot,
            affectedCount: affectedCount
        )
    }

    func applyPathRelocationRequest(
        _ request: PathRelocationRequest,
        moveExistingItems: Bool,
        modelContext: ModelContext
    ) async {
        if moveExistingItems && !activeRunIDs.isEmpty {
            pendingErrorMessage = "Path moves are blocked while jobs are running. Wait for the active jobs to finish, then try again."
            return
        }

        do {
            if moveExistingItems {
                pathRelocationProgress = PathRelocationProgress(
                    scope: request.scope,
                    totalCount: max(request.affectedCount, 1),
                    completedCount: 0,
                    currentItemName: nil,
                    startedAt: .now
                )
                switch request.scope {
                case .repositories:
                    try await moveRepositories(to: request.newRoot, in: modelContext)
                case .worktrees:
                    try await moveWorktrees(to: request.newRoot, in: modelContext)
                }
            }

            persistPathRelocationPreferences(for: request)
            try AppPaths.ensureBaseDirectories()

            if let repository = selectedRepository() {
                refreshRepositorySidebarSnapshot(for: repository)
                refreshRepositoryDetailSnapshot(for: repository)
            }

            notifyOperationSuccess(
                title: moveExistingItems ? "Path updated and existing items moved" : "Default path updated",
                subtitle: request.scope.title.capitalized,
                body: moveExistingItems
                    ? "Moved \(request.affectedCount) \(request.scope.title) to the new root."
                    : "New \(request.scope.singularTitle) items will use the updated path."
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "Path update failed",
                subtitle: request.scope.title.capitalized,
                body: error.localizedDescription
            )
        }

        pathRelocationProgress = nil
    }

    private func moveRepositories(to newRepositoriesRoot: URL, in modelContext: ModelContext) async throws {
        let descriptor = FetchDescriptor<ManagedRepository>(sortBy: [SortDescriptor(\.displayName)])
        let repositories = try modelContext.fetch(descriptor)

        if repositories.isEmpty {
            pathRelocationProgress?.completedCount = 1
            return
        }

        for (index, repository) in repositories.enumerated() {
            pathRelocationProgress?.currentItemName = repository.displayName
            let worktreeURLs = repository.worktrees.compactMap(\.materializedURL)
            let destination = try await services.repositoryManager.moveBareRepository(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                newRepositoriesRoot: newRepositoriesRoot
            )
            repository.bareRepositoryPath = destination.path
            repository.updatedAt = .now
            save(modelContext)
            for worktreeURL in worktreeURLs {
                services.devToolDiscovery.invalidateCache(for: worktreeURL)
            }
            await updateRepositoryWorktreeMonitoring(for: repository)
            pathRelocationProgress?.completedCount = index + 1
        }
    }

    private func moveWorktrees(to newWorktreesRoot: URL, in modelContext: ModelContext) async throws {
        let descriptor = FetchDescriptor<ManagedRepository>(sortBy: [SortDescriptor(\.displayName)])
        let repositories = try modelContext.fetch(descriptor)
        let totalCount = repositories.reduce(0) { $0 + $1.worktrees.count }

        if totalCount == 0 {
            pathRelocationProgress?.completedCount = 1
            return
        }

        var completedCount = 0
        for repository in repositories {
            let targetRoot = AppPaths.defaultWorktreeRoot(
                forRepositoryName: repository.displayName,
                worktreesRoot: newWorktreesRoot
            )

            for worktree in worktrees(for: repository) {
                pathRelocationProgress?.currentItemName = "\(repository.displayName) - \(worktree.branchName)"
                try await relocateWorktree(worktree, in: repository, to: targetRoot)
                completedCount += 1
                pathRelocationProgress?.completedCount = completedCount
            }

            repository.updatedAt = .now
            save(modelContext)
            refreshRepositorySidebarSnapshot(for: repository)
            refreshRepositoryDetailSnapshot(for: repository)
            await refreshWorktreeStatuses(for: repository)
        }
    }

    private func relocateWorktree(
        _ worktree: WorktreeRecord,
        in repository: ManagedRepository,
        to targetRoot: URL
    ) async throws {
        if worktree.isIdeaTree, !worktree.isMaterialized {
            worktree.destinationRootPath = targetRoot.path
            return
        }

        guard let currentURL = worktree.materializedURL else {
            worktree.destinationRootPath = targetRoot.path
            return
        }

        let directoryName = preferredRelocationDirectoryName(for: worktree, in: repository)
        let previousURL = currentURL
        let destination = try await services.worktreeManager.moveWorktree(
            bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
            worktreePath: currentURL,
            newParentDirectory: targetRoot,
            directoryName: directoryName
        )

        worktree.markMaterialized(at: destination.path, kind: worktree.kind)
        if !worktree.isDefaultBranchWorkspace {
            worktree.destinationRootPath = targetRoot.path
        }
        worktree.lastOpenedAt = .now
        services.devToolDiscovery.invalidateCache(for: previousURL)
        invalidateWorktreeDiscoverySnapshot(for: worktree.id)
        invalidateRunConfigurationCache(for: worktree.id)
        _ = refreshWorktreeConfigurationSnapshot(for: worktree)
        _ = refreshAvailableDevToolsCache(for: worktree)
        await refreshAvailableRunConfigurationsCache(for: worktree)
    }

    private func preferredRelocationDirectoryName(for worktree: WorktreeRecord, in repository: ManagedRepository) -> String {
        if worktree.isDefaultBranchWorkspace {
            return "default-branch"
        }

        if let materializedURL = worktree.materializedURL {
            let currentDefaultRoot = AppPaths.defaultWorktreeRoot(forRepositoryName: repository.displayName)
            if materializedURL.path.hasPrefix(currentDefaultRoot.path + "/") {
                let relativePath = String(materializedURL.path.dropFirst(currentDefaultRoot.path.count + 1))
                if let relativePath = relativePath.nilIfBlank {
                    return relativePath
                }
            }
        }

        return worktree.branchName
    }

    private func persistPathRelocationPreferences(for request: PathRelocationRequest) {
        let defaults = UserDefaults.standard
        switch request.scope {
        case .repositories:
            defaults.set(request.newLocation.rawValue, forKey: AppPreferences.repositoriesRootLocationKey)
            if let customPath = request.newCustomPath {
                defaults.set(customPath, forKey: AppPreferences.repositoriesRootCustomPathKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.repositoriesRootCustomPathKey)
            }
        case .worktrees:
            defaults.set(request.newLocation.rawValue, forKey: AppPreferences.worktreesRootLocationKey)
            if let customPath = request.newCustomPath {
                defaults.set(customPath, forKey: AppPreferences.worktreesRootCustomPathKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.worktreesRootCustomPathKey)
            }
        }
    }

    func migrateLegacyRepositoriesIfNeeded(in modelContext: ModelContext) {
        let defaultNamespace = defaultNamespace(in: modelContext)
        let descriptor = FetchDescriptor<ManagedRepository>()
        guard let repositories = try? modelContext.fetch(descriptor) else { return }
        var didChange = false

        for repository in repositories {
            if repository.namespace == nil {
                repository.namespace = defaultNamespace
                didChange = true
            }

            if let project = repository.project {
                if project.namespace == nil {
                    project.namespace = repository.namespace
                    project.updatedAt = .now
                    didChange = true
                } else if project.namespace?.id != repository.namespace?.id {
                    repository.project = nil
                    didChange = true
                }
            }

            if let documentationProject = repository.documentationProject {
                if repository.project != nil {
                    repository.project = nil
                    didChange = true
                }
                if repository.namespace?.id != documentationProject.namespace?.id {
                    repository.namespace = documentationProject.namespace
                    repository.updatedAt = .now
                    didChange = true
                }
            }

            guard repository.remotes.isEmpty else { continue }
            guard
                let remoteURL = repository.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                let canonicalURL = RepositoryManager.canonicalRemoteURL(from: remoteURL)
            else {
                continue
            }

            let remote = RepositoryRemote(
                name: "origin",
                url: remoteURL,
                canonicalURL: canonicalURL,
                repository: repository
            )
            repository.remotes.append(remote)
            modelContext.insert(remote)
            didChange = true
        }

        for repository in repositories {
            let previousDefaultRemoteName = repository.defaultRemoteName
            ensureDefaultRemoteSelection(for: repository)
            if repository.defaultRemoteName != previousDefaultRemoteName {
                didChange = true
            }
        }

        if didChange {
            save(modelContext)
        }

        if selectedNamespaceID == nil {
            selectedNamespaceID = defaultNamespace.id
        }
    }

    func createRepository(in modelContext: ModelContext) async {
        do {
            let mode = repositoryCreationDraft.mode
            let createdRepository: ManagedRepository

            switch mode {
            case .cloneRemote:
                let rawRemote = repositoryCreationDraft.remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    let canonicalURL = RepositoryManager.canonicalRemoteURL(from: rawRemote),
                    let remoteURL = URL(string: rawRemote)
                else {
                    throw StackriotError.invalidRemoteURL
                }

                if let duplicate = repository(withCanonicalRemoteURL: canonicalURL, in: modelContext) {
                    selectedRepositoryID = duplicate.id
                    throw StackriotError.duplicateRepository(rawRemote)
                }

                let info = try await services.repositoryManager.cloneBareRepository(
                    remoteURL: remoteURL,
                    preferredName: repositoryCreationDraft.displayName
                )
                createdRepository = try persistRepository(
                    displayName: info.displayName,
                    remoteURL: rawRemote,
                    bareRepositoryPath: info.bareRepositoryPath.path,
                    defaultBranch: info.defaultBranch,
                    defaultRemoteName: info.initialRemoteName,
                    remoteDescriptor: (name: info.initialRemoteName, url: rawRemote, canonicalURL: canonicalURL),
                    in: modelContext
                )
            case .npxTemplate:
                let info = try await services.repositoryManager.createBareRepository(
                    displayName: requiredRepositoryName(),
                    seed: .npx(command: requiredNPXCommand())
                )
                createdRepository = try persistRepository(
                    displayName: info.displayName,
                    remoteURL: nil,
                    bareRepositoryPath: info.bareRepositoryPath.path,
                    defaultBranch: info.defaultBranch,
                    defaultRemoteName: nil,
                    remoteDescriptor: nil,
                    in: modelContext
                )
            case .aiReadme:
                let repositoryName = try requiredRepositoryName()
                let readmeContents = try await services.aiProviderService.generateRepositoryReadme(
                    repositoryName: repositoryName,
                    prompt: requiredReadmePrompt()
                )
                let info = try await services.repositoryManager.createBareRepository(
                    displayName: repositoryName,
                    seed: .readme(contents: readmeContents)
                )
                createdRepository = try persistRepository(
                    displayName: info.displayName,
                    remoteURL: nil,
                    bareRepositoryPath: info.bareRepositoryPath.path,
                    defaultBranch: info.defaultBranch,
                    defaultRemoteName: nil,
                    remoteDescriptor: nil,
                    in: modelContext
                )
            case .archiveImport:
                let info = try await services.repositoryManager.createBareRepository(
                    displayName: requiredRepositoryName(),
                    seed: .archive(fileURL: requiredArchiveFileURL())
                )
                createdRepository = try persistRepository(
                    displayName: info.displayName,
                    remoteURL: nil,
                    bareRepositoryPath: info.bareRepositoryPath.path,
                    defaultBranch: info.defaultBranch,
                    defaultRemoteName: nil,
                    remoteDescriptor: nil,
                    in: modelContext
                )
            }

            _ = await ensureDefaultBranchWorkspace(for: createdRepository, in: modelContext)

            selectedNamespaceID = createdRepository.namespace?.id
            selectedRepositoryID = createdRepository.id
            isRepositoryCreationSheetPresented = false
            await refresh(createdRepository, in: modelContext)
            notifyOperationSuccess(
                title: mode == .cloneRemote ? "Repository cloned" : "Repository created",
                subtitle: createdRepository.displayName,
                body: successBody(for: mode, repository: createdRepository),
                userInfo: ["repositoryID": createdRepository.id.uuidString]
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: repositoryCreationDraft.mode == .cloneRemote ? "Repository clone failed" : "Repository creation failed",
                subtitle: repositoryCreationDraft.displayName.nonEmpty,
                body: error.localizedDescription
            )
        }
    }

    func refresh(_ repository: ManagedRepository, in modelContext: ModelContext) async {
        guard !refreshingRepositoryIDs.contains(repository.id) else { return }
        refreshingRepositoryIDs.insert(repository.id)
        refreshRepositorySidebarSnapshot(for: repository)
        defer {
            refreshingRepositoryIDs.remove(repository.id)
            refreshRepositorySidebarSnapshot(for: repository)
        }

        let status = services.repositoryManager.refreshStatus(for: URL(fileURLWithPath: repository.bareRepositoryPath))
        guard status == .ready else {
            stopRepositoryWorktreeMonitoring(for: repository.id)
            repository.status = status
            repository.updatedAt = .now
            repository.lastErrorMessage = "Repository missing or invalid."
            save(modelContext)
            refreshRepositorySidebarSnapshot(for: repository)
            refreshRepositoryDetailSnapshot(for: repository)
            return
        }

        _ = await reconcileRepositoryRemotes(for: repository, in: modelContext)
        ensureDefaultRemoteSelection(for: repository)
        _ = await ensureDefaultBranchWorkspace(for: repository, in: modelContext)
        let contexts = repository.remotes.map(remoteExecutionContext(for:))
        let defaultRemoteName = resolvedDefaultRemote(for: repository)?.name
        let result = await services.repositoryManager.refreshRepository(
            bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
            remotes: contexts,
            defaultRemoteName: defaultRemoteName
        )

        repository.status = result.status
        repository.defaultBranch = result.defaultBranch
        repository.defaultRemoteName = defaultRemoteName
        repository.lastFetchedAt = result.fetchedAt ?? repository.lastFetchedAt
        repository.lastErrorMessage = result.errorMessage
        repository.updatedAt = .now
        save(modelContext)

        var logLines: [String] = []
        if let fetchErr = result.fetchErrorMessage {
            logLines.append("⚠ Fetch: \(fetchErr)")
        } else if result.fetchedAt != nil {
            let remoteName = defaultRemoteName ?? "remote"
            logLines.append("✓ Fetch von \(remoteName) abgeschlossen")
        }
        if let syncErr = result.defaultBranchSyncErrorMessage {
            logLines.append("⚠ Sync: \(syncErr)")
        } else if let syncSummary = result.defaultBranchSyncSummary {
            logLines.append("✓ Sync: \(syncSummary)")
        } else {
            logLines.append("✓ Sync: Kein Default-Worktree für \(result.defaultBranch) gefunden")
        }
        syncLogs[repository.id] = logLines.isEmpty ? nil : logLines.joined(separator: "\n")

        _ = await ensureDefaultBranchWorkspace(for: repository, in: modelContext)
        await reconcileRepositoryWorktrees(for: repository, in: modelContext)
        await updateRepositoryWorktreeMonitoring(for: repository)
        primeWorktreeConfigurationSnapshots(for: repository)
        refreshRepositorySidebarSnapshot(for: repository)
        refreshRepositoryDetailSnapshot(for: repository)
        await refreshWorktreeStatuses(for: repository)
    }

    func refreshSelectedRepository() {
        guard
            let repository = selectedRepository(),
            let modelContext = storedModelContext
        else {
            pendingErrorMessage = "No repository is currently selected."
            return
        }

        Task {
            await refresh(repository, in: modelContext)
        }
    }

    func refreshAllRepositories(force: Bool) async {
        guard let modelContext = storedModelContext else { return }
        if !force, !AppPreferences.autoRefreshEnabled { return }
        let descriptor = FetchDescriptor<ManagedRepository>(sortBy: [SortDescriptor(\.displayName)])
        guard let repositories = try? modelContext.fetch(descriptor) else { return }
        for repository in repositories {
            await refresh(repository, in: modelContext)
        }
    }

    /// Lightweight status refresh when the app returns to the foreground (no full `git fetch` for every repo).
    func handleAppDidBecomeActive() async {
        let now = Date.now
        configureQuickIntentHotKey()
        if let last = lastForegroundLightRefreshAt, now.timeIntervalSince(last) < 2 {
            return
        }
        lastForegroundLightRefreshAt = now
        guard let repository = selectedRepository(), storedModelContext != nil else { return }

        if AppPreferences.worktreeStatusPollingEnabled {
            if let lastPoll = lastWorktreeStatusPollAt,
               now.timeIntervalSince(lastPoll) < AppPreferences.worktreeStatusPollingInterval
            {
                return
            }
        }

        await refreshWorktreeStatuses(for: repository)
        if AppPreferences.devContainerMonitoringEnabled {
            await refreshAllDevContainerStates()
        }
    }

    func revealWorktreeInFinder(_ worktree: WorktreeRecord) async {
        do {
            guard let repository = worktree.repository else {
                throw StackriotError.worktreeUnavailable
            }
            guard let modelContext = storedModelContext else {
                throw StackriotError.worktreeUnavailable
            }
            guard await materializeIdeaTreeIfNeeded(worktree, in: repository, modelContext: modelContext) != nil,
                  let worktreeURL = worktree.materializedURL
            else {
                return
            }
            try await services.ideManager.revealInFinder(path: worktreeURL)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func deleteRepository(_ repository: ManagedRepository, in modelContext: ModelContext) async {
        do {
            for run in repository.runs {
                cancelAutoHide(for: run.id)
            }
            stopRepositoryWorktreeMonitoring(for: repository.id)
            for worktreeURL in repository.worktrees.compactMap(\.materializedURL) {
                services.devToolDiscovery.invalidateCache(for: worktreeURL)
            }
            try await services.repositoryManager.deleteRepository(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                worktreePaths: repository.worktrees.compactMap(\.materializedURL)
            )

            modelContext.delete(repository)
            try modelContext.save()
            if selectedRepositoryID == repository.id {
                selectedRepositoryID = nil
            }
            selectedWorktreeIDsByRepository.removeValue(forKey: repository.id)
            repositorySidebarSnapshotsByID.removeValue(forKey: repository.id)
            repositoryDetailSnapshotsByID.removeValue(forKey: repository.id)
            for worktree in repository.worktrees {
                invalidateWorktreeDiscoverySnapshot(for: worktree.id)
                invalidateRunConfigurationCache(for: worktree.id)
                devContainerStatesByWorktreeID.removeValue(forKey: worktree.id)
            }
            notifyOperationSuccess(
                title: "Repository deleted",
                subtitle: repository.displayName,
                body: "Removed the bare repository and its worktrees.",
                userInfo: ["repositoryID": repository.id.uuidString]
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "Repository deletion failed",
                subtitle: repository.displayName,
                body: error.localizedDescription,
                userInfo: ["repositoryID": repository.id.uuidString]
            )
        }
    }

    func revealRepositoryInFinder(_ repository: ManagedRepository) async {
        do {
            try await services.ideManager.revealInFinder(path: URL(fileURLWithPath: repository.bareRepositoryPath))
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func preferredOpenWorktree(for repository: ManagedRepository) -> WorktreeRecord? {
        selectedWorktree(for: repository) ?? defaultBranchWorkspace(for: repository) ?? worktrees(for: repository).first
    }

    func availableDevTools(for repository: ManagedRepository) -> [SupportedDevTool] {
        guard let worktree = preferredOpenWorktree(for: repository) else {
            return []
        }
        return availableDevTools(for: worktree)
    }

    func openDevTool(_ tool: SupportedDevTool, for repository: ManagedRepository, in modelContext: ModelContext) async {
        guard let worktree = preferredOpenWorktree(for: repository) else {
            pendingErrorMessage = StackriotError.worktreeUnavailable.localizedDescription
            return
        }
        await openDevTool(tool, for: worktree, in: modelContext)
    }

    func openExternalTerminal(
        _ terminal: SupportedExternalTerminal,
        for repository: ManagedRepository,
        in modelContext: ModelContext
    ) async {
        guard let worktree = preferredOpenWorktree(for: repository) else {
            pendingErrorMessage = StackriotError.worktreeUnavailable.localizedDescription
            return
        }
        await openExternalTerminal(terminal, for: worktree, in: modelContext)
    }

    func updateRepositoryWorktreeMonitoring(for repository: ManagedRepository) async {
        guard repository.status == .ready else {
            stopRepositoryWorktreeMonitoring(for: repository.id)
            return
        }

        guard let selectedID = selectedRepositoryID, selectedID == repository.id else {
            stopRepositoryWorktreeMonitoring(for: repository.id)
            return
        }

        let repositoryID = repository.id
        let monitor = repositoryWorktreeMonitoringByRepositoryID[repositoryID] ?? {
            let monitor = RepositoryWorktreeMonitor { [weak self] in
                Task { @MainActor in
                    self?.scheduleRepositoryWorktreeReconciliation(for: repositoryID)
                }
            }
            repositoryWorktreeMonitoringByRepositoryID[repositoryID] = monitor
            return monitor
        }()

        do {
            let adminPaths = try await services.repositoryManager.repositoryGitAdminPaths(
                for: URL(fileURLWithPath: repository.bareRepositoryPath)
            )
            let observedPaths = [
                URL(fileURLWithPath: repository.bareRepositoryPath),
                adminPaths.config,
                adminPaths.worktrees,
            ].compactMap { $0 }
            guard repositoryWorktreeMonitoringByRepositoryID[repositoryID] === monitor else { return }
            monitor.updateObservedPaths(observedPaths)
        } catch {
            guard repositoryWorktreeMonitoringByRepositoryID[repositoryID] === monitor else { return }
            monitor.updateObservedPaths([URL(fileURLWithPath: repository.bareRepositoryPath)])
        }
    }

    func stopRepositoryWorktreeMonitoring(for repositoryID: UUID) {
        repositoryWorktreeReconcileTasksByRepositoryID[repositoryID]?.cancel()
        repositoryWorktreeReconcileTasksByRepositoryID.removeValue(forKey: repositoryID)
        pendingRepositoryWorktreeReconcileRepositoryIDs.remove(repositoryID)
        repositoryWorktreeMonitoringByRepositoryID.removeValue(forKey: repositoryID)?.stop()
    }

    /// Debounced worktree list + status sync after the selected repository changes (no full `git fetch`).
    func scheduleRepositorySelectionSync(afterSelecting newRepositoryID: UUID?) {
        repositorySelectionSyncTask?.cancel()
        repositorySelectionSyncTask = nil
        guard let newRepositoryID else { return }

        repositorySelectionSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.repositorySelectionSyncTask = nil }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, self.selectedRepositoryID == newRepositoryID else { return }
            guard let modelContext = self.storedModelContext,
                  let repository = self.repositoryRecord(with: newRepositoryID)
            else { return }
            await self.updateRepositoryWorktreeMonitoring(for: repository)
            _ = await self.reconcileRepositoryWorktrees(for: repository, in: modelContext)
            await self.refreshWorktreeStatuses(for: repository)
        }
    }

    func scheduleRepositoryWorktreeReconciliation(for repositoryID: UUID) {
        guard let modelContext = storedModelContext else { return }
        if repositoryWorktreeReconcileTasksByRepositoryID[repositoryID] != nil {
            pendingRepositoryWorktreeReconcileRepositoryIDs.insert(repositoryID)
            return
        }

        repositoryWorktreeReconcileTasksByRepositoryID[repositoryID] = Task { @MainActor in
            defer {
                repositoryWorktreeReconcileTasksByRepositoryID.removeValue(forKey: repositoryID)
            }

            while true {
                pendingRepositoryWorktreeReconcileRepositoryIDs.remove(repositoryID)
                await reconcileRepositoryWorktrees(forRepositoryID: repositoryID, in: modelContext)
                guard pendingRepositoryWorktreeReconcileRepositoryIDs.contains(repositoryID) else {
                    break
                }
            }
        }
    }

    @discardableResult
    func reconcileRepositoryRemotes(for repository: ManagedRepository, in modelContext: ModelContext) async -> Bool {
        do {
            let descriptors = try await services.repositoryManager.listRemotes(
                in: URL(fileURLWithPath: repository.bareRepositoryPath)
            )
            let didChange = reconcileRepositoryRemoteDescriptors(descriptors, for: repository, in: modelContext)
            if didChange {
                repository.updatedAt = .now
                save(modelContext)
                refreshRepositoryDetailSnapshot(for: repository)
            }
            return didChange
        } catch {
            pendingErrorMessage = error.localizedDescription
            return false
        }
    }

    private func reconcileRepositoryRemoteDescriptors(
        _ descriptors: [GitRemoteDescriptor],
        for repository: ManagedRepository,
        in modelContext: ModelContext
    ) -> Bool {
        var didChange = false
        var remainingRemotes = repository.remotes
        var matchedRemoteIDs: Set<UUID> = []

        for descriptor in descriptors {
            let match = remainingRemotes.first(where: { $0.name == descriptor.name })
                ?? remainingRemotes.first(where: { $0.canonicalURL == descriptor.canonicalURL })

            if let match {
                var didChangeForMatch = false
                remainingRemotes.removeAll(where: { $0.id == match.id })
                matchedRemoteIDs.insert(match.id)
                if match.name != descriptor.name {
                    match.name = descriptor.name
                    didChange = true
                    didChangeForMatch = true
                }
                if match.url != descriptor.url {
                    match.url = descriptor.url
                    didChange = true
                    didChangeForMatch = true
                }
                if match.canonicalURL != descriptor.canonicalURL {
                    match.canonicalURL = descriptor.canonicalURL
                    didChange = true
                    didChangeForMatch = true
                }
                if didChangeForMatch {
                    match.updatedAt = .now
                }
                continue
            }

            let remote = RepositoryRemote(
                name: descriptor.name,
                url: descriptor.url,
                canonicalURL: descriptor.canonicalURL,
                repository: repository
            )
            repository.remotes.append(remote)
            modelContext.insert(remote)
            matchedRemoteIDs.insert(remote.id)
            didChange = true
        }

        let removableRemotes = repository.remotes.filter { !matchedRemoteIDs.contains($0.id) }
        if !removableRemotes.isEmpty {
            for remote in removableRemotes {
                modelContext.delete(remote)
            }
            didChange = true
        }

        let previousDefaultRemoteName = repository.defaultRemoteName
        ensureDefaultRemoteSelection(for: repository)
        if repository.defaultRemoteName != previousDefaultRemoteName {
            didChange = true
        }

        return didChange
    }

    func defaultTemplates(for repository: ManagedRepository) -> [ActionTemplateRecord] {
        let toolTemplates: [ActionTemplateRecord]
        if let worktree = worktrees(for: repository).first {
            toolTemplates = availableDevTools(for: worktree)
                .map {
                    ActionTemplateRecord(
                        kind: .openIDE,
                        title: "Open in \($0.displayName)",
                        payload: $0.rawValue,
                        repository: repository
                    )
                }
        } else {
            toolTemplates = []
        }

        return toolTemplates + [
            ActionTemplateRecord(
                kind: .installDependencies,
                title: "Install dependencies",
                payload: DependencyInstallMode.install.rawValue,
                repository: repository
            ),
        ]
    }

    private func selectedNamespace(in modelContext: ModelContext) -> RepositoryNamespace? {
        if let selectedNamespaceID, let namespace = namespaceRecord(with: selectedNamespaceID) {
            return namespace
        }
        return fetchDefaultNamespace(in: modelContext)
    }

    private func requiredRepositoryName() throws -> String {
        guard let value = repositoryCreationDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw StackriotError.repositoryNameRequired
        }
        return value
    }

    private func requiredNPXCommand() throws -> String {
        guard let value = repositoryCreationDraft.npxCommand.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw StackriotError.commandFailed("An NPX command is required.")
        }
        return value
    }

    private func requiredReadmePrompt() throws -> String {
        guard let value = repositoryCreationDraft.readmePrompt.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw StackriotError.commandFailed("A README prompt is required.")
        }
        return value
    }

    private func requiredArchiveFileURL() throws -> URL {
        guard let archiveURL = repositoryCreationDraft.archiveFileURL else {
            throw StackriotError.commandFailed("Choose a ZIP or tar archive to import.")
        }
        return archiveURL
    }

    func persistRepository(
        displayName: String,
        remoteURL: String?,
        bareRepositoryPath: String,
        defaultBranch: String,
        defaultRemoteName: String?,
        remoteDescriptor: (name: String, url: String, canonicalURL: String)?,
        namespace: RepositoryNamespace? = nil,
        in modelContext: ModelContext
    ) throws -> ManagedRepository {
        let repository = ManagedRepository(
            displayName: displayName,
            remoteURL: remoteURL,
            bareRepositoryPath: bareRepositoryPath,
            defaultBranch: defaultBranch,
            defaultRemoteName: defaultRemoteName,
            namespace: namespace ?? selectedNamespace(in: modelContext) ?? defaultNamespace(in: modelContext)
        )

        if let remoteDescriptor {
            let remote = RepositoryRemote(
                name: remoteDescriptor.name,
                url: remoteDescriptor.url,
                canonicalURL: remoteDescriptor.canonicalURL,
                repository: repository
            )
            repository.remotes.append(remote)
            modelContext.insert(remote)
        }

        repository.actionTemplates = defaultTemplates(for: repository)
        modelContext.insert(repository)
        try modelContext.save()
        return repository
    }

    private func successBody(for mode: RepositoryCreationMode, repository: ManagedRepository) -> String {
        switch mode {
        case .cloneRemote:
            return "Finished cloning \(repository.remoteURL ?? repository.displayName)."
        case .npxTemplate:
            return "Created \(repository.displayName) from the provided NPX template command."
        case .aiReadme:
            return "Created \(repository.displayName) with an AI-generated README."
        case .archiveImport:
            return "Imported the archive contents into \(repository.displayName)."
        }
    }
}
