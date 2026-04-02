import Foundation
import SwiftData

extension AppModel {
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

    func cloneRepository(in modelContext: ModelContext) async {
        do {
            let rawRemote = cloneDraft.remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
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
                preferredName: cloneDraft.displayName
            )

            let repository = ManagedRepository(
                displayName: info.displayName,
                remoteURL: rawRemote,
                bareRepositoryPath: info.bareRepositoryPath.path,
                defaultBranch: info.defaultBranch,
                defaultRemoteName: info.initialRemoteName,
                namespace: selectedNamespace(in: modelContext) ?? defaultNamespace(in: modelContext)
            )

            let remote = RepositoryRemote(
                name: info.initialRemoteName,
                url: rawRemote,
                canonicalURL: canonicalURL,
                repository: repository
            )

            repository.remotes.append(remote)
            repository.actionTemplates = defaultTemplates(for: repository)
            modelContext.insert(repository)
            modelContext.insert(remote)
            try modelContext.save()

            _ = await ensureDefaultBranchWorkspace(for: repository, in: modelContext)

            selectedNamespaceID = repository.namespace?.id
            selectedRepositoryID = repository.id
            isCloneSheetPresented = false
            await refresh(repository, in: modelContext)
            notifyOperationSuccess(
                title: "Repository cloned",
                subtitle: repository.displayName,
                body: "Finished cloning \(rawRemote).",
                userInfo: ["repositoryID": repository.id.uuidString]
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "Repository clone failed",
                subtitle: cloneDraft.displayName.nonEmpty,
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
            repository.status = status
            repository.updatedAt = .now
            repository.lastErrorMessage = "Repository missing or invalid."
            save(modelContext)
            refreshRepositorySidebarSnapshot(for: repository)
            refreshRepositoryDetailSnapshot(for: repository)
            return
        }

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
        }
        if let syncErr = result.defaultBranchSyncErrorMessage {
            logLines.append("⚠ Sync: \(syncErr)")
        } else if result.defaultBranchSyncSummary != nil {
        } else {
            logLines.append("✓ Sync: Kein Default-Worktree für \(result.defaultBranch) gefunden")
        }
        if logLines != [] {
            syncLogs[repository.id] = logLines.joined(separator: "\n")
        }

        _ = await ensureDefaultBranchWorkspace(for: repository, in: modelContext)
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

    func defaultTemplates(for repository: ManagedRepository) -> [ActionTemplateRecord] {
        let toolTemplates: [ActionTemplateRecord]
        if let worktree = worktrees(for: repository).first {
            toolTemplates = availableDevTools(for: worktree)
                .prefix(2)
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
}
