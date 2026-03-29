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
                throw DevVaultError.invalidRemoteURL
            }

            if let duplicate = repository(withCanonicalRemoteURL: canonicalURL, in: modelContext) {
                selectedRepositoryID = duplicate.id
                throw DevVaultError.duplicateRepository(rawRemote)
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
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func refresh(_ repository: ManagedRepository, in modelContext: ModelContext) async {
        guard !refreshingRepositoryIDs.contains(repository.id) else { return }
        refreshingRepositoryIDs.insert(repository.id)
        defer { refreshingRepositoryIDs.remove(repository.id) }

        let status = services.repositoryManager.refreshStatus(for: URL(fileURLWithPath: repository.bareRepositoryPath))
        guard status == .ready else {
            repository.status = status
            repository.updatedAt = .now
            repository.lastErrorMessage = "Repository missing or invalid."
            save(modelContext)
            return
        }

        let contexts = repository.remotes.map(remoteExecutionContext(for:))
        let result = await services.repositoryManager.refreshRepository(
            bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
            remotes: contexts
        )

        repository.status = result.status
        repository.defaultBranch = result.defaultBranch
        repository.lastFetchedAt = result.fetchedAt ?? repository.lastFetchedAt
        repository.lastErrorMessage = result.errorMessage
        repository.updatedAt = .now
        save(modelContext)
        _ = await ensureDefaultBranchWorkspace(for: repository, in: modelContext)
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

    func deleteRepository(_ repository: ManagedRepository, in modelContext: ModelContext) async {
        do {
            for run in repository.runs {
                cancelAutoHide(for: run.id)
            }
            try await services.repositoryManager.deleteRepository(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                worktreePaths: repository.worktrees.map { URL(fileURLWithPath: $0.path) }
            )

            modelContext.delete(repository)
            try modelContext.save()
            if selectedRepositoryID == repository.id {
                selectedRepositoryID = nil
            }
            selectedWorktreeIDsByRepository.removeValue(forKey: repository.id)
            clearRepositoryDeletionRequest()
        } catch {
            pendingErrorMessage = error.localizedDescription
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
        [
            ActionTemplateRecord(kind: .openIDE, title: "Open in Cursor", payload: SupportedIDE.cursor.rawValue, repository: repository),
            ActionTemplateRecord(kind: .openIDE, title: "Open in VS Code", payload: SupportedIDE.vscode.rawValue, repository: repository),
            ActionTemplateRecord(kind: .installDependencies, title: "Install dependencies", payload: DependencyInstallMode.install.rawValue, repository: repository),
        ]
    }

    private func selectedNamespace(in modelContext: ModelContext) -> RepositoryNamespace? {
        if let selectedNamespaceID, let namespace = namespaceRecord(with: selectedNamespaceID) {
            return namespace
        }
        return fetchDefaultNamespace(in: modelContext)
    }
}
