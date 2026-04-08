import Foundation
import OSLog
import SwiftData

extension AppModel {
    func presentProjectDocumentationSourceEditor(for project: RepositoryProject) {
        let documentationRepository = project.documentationRepository
        let remoteURL = documentationRepository?.defaultRemote?.url ?? documentationRepository?.remoteURL ?? ""
        let preferredMode: ProjectDocumentationSourceMode =
            remoteURL.isEmpty ? .automaticRepository : .existingRemote

        projectDocumentationSourceDraft = ProjectDocumentationSourceDraft(
            projectID: project.id,
            mode: preferredMode,
            remoteURLString: remoteURL,
            displayName: documentationRepository?.displayName ?? "",
            repositoryName: documentationRepository?.displayName ?? suggestedDocumentationRepositoryName(for: project)
        )
    }

    func dismissProjectDocumentationSourceEditor() {
        projectDocumentationSourceDraft = nil
    }

    func openDocumentationRepository(for project: RepositoryProject) {
        guard let repository = project.documentationRepository else {
            pendingErrorMessage = "This project has no documentation repository configured yet."
            return
        }
        openRepository(repository)
    }

    func removeDocumentationRepository(from project: RepositoryProject, in modelContext: ModelContext) {
        guard let repository = project.documentationRepository else { return }
        repository.documentationProject = nil
        repository.updatedAt = Date.now
        project.documentationRepository = nil
        project.updatedAt = Date.now
        save(modelContext)
        notifyOperationSuccess(
            title: "Documentation source removed",
            subtitle: project.name,
            body: "\(repository.displayName) remains available as a managed repository."
        )
    }

    func saveProjectDocumentationSource(in modelContext: ModelContext) async {
        guard let draft = projectDocumentationSourceDraft else { return }

        do {
            guard let project = projectRecord(with: draft.projectID) else {
                throw StackriotError.commandFailed("The selected project could not be found.")
            }
            guard let namespace = project.namespace else {
                throw StackriotError.commandFailed("The selected project has no namespace.")
            }

            let previousRepository = project.documentationRepository
            let repository = try await resolvedDocumentationRepository(
                from: draft,
                for: project,
                in: namespace,
                modelContext: modelContext
            )

            if previousRepository?.id != repository.id {
                previousRepository?.documentationProject = nil
                previousRepository?.updatedAt = Date.now
            }

            repository.namespace = namespace
            repository.project = nil
            repository.documentationProject = project
            repository.updatedAt = Date.now
            project.documentationRepository = repository
            project.updatedAt = Date.now
            save(modelContext)

            _ = await ensureDefaultBranchWorkspace(for: repository, in: modelContext)
            await refresh(repository, in: modelContext)
            openRepository(repository)
            dismissProjectDocumentationSourceEditor()
            notifyOperationSuccess(
                title: previousRepository == nil ? "Documentation source configured" : "Documentation source updated",
                subtitle: project.name,
                body: "\(repository.displayName) is now linked as the project documentation repository.",
                userInfo: [
                    "projectID": project.id.uuidString,
                    "repositoryID": repository.id.uuidString,
                ]
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "Documentation source setup failed",
                subtitle: projectRecord(with: draft.projectID)?.name,
                body: error.localizedDescription
            )
        }
    }

    func archiveProjectDocumentationIfNeeded(
        for worktree: WorktreeRecord,
        repository: ManagedRepository,
        targetBranchName: String?,
        modelContext: ModelContext
    ) async {
        guard let project = repository.project,
              let documentationRepository = project.documentationRepository
        else {
            return
        }

        do {
            guard let documentationWorktree = await ensureDefaultBranchWorkspace(for: documentationRepository, in: modelContext) else {
                throw StackriotError.worktreeUnavailable
            }
            guard let documentationWorktreeURL = documentationWorktree.materializedURL else {
                throw StackriotError.worktreeUnavailable
            }

            _ = try services.projectDocumentationArchiveService.archiveWorktreeArtifacts(
                documentationWorktreeURL: documentationWorktreeURL,
                worktree: worktree,
                repository: repository,
                project: project,
                targetBranchName: targetBranchName
            )
        } catch {
            Logger(subsystem: "Stackriot", category: "project-documentation").warning(
                "Documentation archive failed for worktree \(worktree.branchName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            notifyOperationFailure(
                title: "Documentation archive failed",
                subtitle: project.name,
                body: "The integration completed, but Stackriot could not archive the worktree intent and plan: \(error.localizedDescription)",
                userInfo: [
                    "projectID": project.id.uuidString,
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
        }
    }

    func suggestedDocumentationRepositoryName(for project: RepositoryProject) -> String {
        let namespaceName = project.namespace?.name ?? "project"
        let namespaceComponent = AppPaths.sanitizedPathComponent(namespaceName)
        let projectComponent = AppPaths.sanitizedPathComponent(project.name)
        return "\(namespaceComponent)-\(projectComponent)-docs"
    }

    private func resolvedDocumentationRepository(
        from draft: ProjectDocumentationSourceDraft,
        for project: RepositoryProject,
        in namespace: RepositoryNamespace,
        modelContext: ModelContext
    ) async throws -> ManagedRepository {
        switch draft.mode {
        case .existingRemote:
            return try await documentationRepositoryFromRemote(
                remoteURLString: draft.remoteURLString,
                preferredDisplayName: draft.displayName,
                project: project,
                namespace: namespace,
                modelContext: modelContext
            )
        case .automaticRepository:
            return try await documentationRepositoryFromTemplate(
                repositoryName: draft.repositoryName,
                project: project,
                namespace: namespace,
                modelContext: modelContext
            )
        }
    }

    private func documentationRepositoryFromRemote(
        remoteURLString: String,
        preferredDisplayName: String,
        project: RepositoryProject,
        namespace: RepositoryNamespace,
        modelContext: ModelContext
    ) async throws -> ManagedRepository {
        let rawRemote = remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let canonicalURL = RepositoryManager.canonicalRemoteURL(from: rawRemote),
            let remoteURL = URL(string: rawRemote)
        else {
            throw StackriotError.invalidRemoteURL
        }

        if let existingRepository = repository(withCanonicalRemoteURL: canonicalURL, in: modelContext) {
            try validateDocumentationRepositoryCandidate(existingRepository, for: project)
            if let preferredDisplayName = preferredDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
               existingRepository.displayName != preferredDisplayName
            {
                existingRepository.displayName = preferredDisplayName
                existingRepository.updatedAt = Date.now
                save(modelContext)
            }
            return existingRepository
        }

        let info = try await services.repositoryManager.cloneBareRepository(
            remoteURL: remoteURL,
            preferredName: preferredDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        )
        return try persistRepository(
            displayName: info.displayName,
            remoteURL: rawRemote,
            bareRepositoryPath: info.bareRepositoryPath.path,
            defaultBranch: info.defaultBranch,
            defaultRemoteName: info.initialRemoteName,
            remoteDescriptor: (name: info.initialRemoteName, url: rawRemote, canonicalURL: canonicalURL),
            namespace: namespace,
            in: modelContext
        )
    }

    private func documentationRepositoryFromTemplate(
        repositoryName: String,
        project: RepositoryProject,
        namespace: RepositoryNamespace,
        modelContext: ModelContext
    ) async throws -> ManagedRepository {
        let trimmedName = repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repositoryName = trimmedName.nonEmpty else {
            throw StackriotError.repositoryNameRequired
        }

        if let currentRepository = project.documentationRepository,
           currentRepository.remoteURL == nil,
           currentRepository.defaultRemote == nil,
           currentRepository.displayName == repositoryName
        {
            try validateDocumentationRepositoryCandidate(currentRepository, for: project)
            return currentRepository
        }

        let info = try await services.repositoryManager.createBareRepository(
            displayName: repositoryName,
            seed: .entries(documentationRepositorySeedEntries(for: project))
        )
        return try persistRepository(
            displayName: info.displayName,
            remoteURL: nil,
            bareRepositoryPath: info.bareRepositoryPath.path,
            defaultBranch: info.defaultBranch,
            defaultRemoteName: nil,
            remoteDescriptor: nil,
            namespace: namespace,
            in: modelContext
        )
    }

    private func validateDocumentationRepositoryCandidate(
        _ repository: ManagedRepository,
        for project: RepositoryProject
    ) throws {
        if let currentProject = repository.project {
            throw StackriotError.commandFailed(
                "\(repository.displayName) is already assigned as a working repository in project \(currentProject.name)."
            )
        }

        if let existingDocumentationProject = repository.documentationProject,
           existingDocumentationProject.id != project.id
        {
            throw StackriotError.commandFailed(
                "\(repository.displayName) is already used as the documentation source for project \(existingDocumentationProject.name)."
            )
        }
    }

    private func documentationRepositorySeedEntries(for project: RepositoryProject) -> [RepositorySeedEntry] {
        let projectName = project.name
        return [
            .file(
                path: "README.md",
                contents: """
                # \(projectName)

                Projektweite Dokumentation, Marktinformationen und archivierte Worktree-Artefakte fuer **\(projectName)**.

                ## Struktur

                - `market-data/` fuer Recherche, Benchmarks und externe Signale
                - `archive/intents/` fuer projektweite Intent-Snapshots
                - `archive/plans/` fuer uebergeordnete Implementierungsplaene
                - `archive/worktrees/` fuer archivierte Worktree-Artefakte
                """
            ),
            .file(path: "market-data/.gitkeep", contents: ""),
            .file(path: "archive/intents/.gitkeep", contents: ""),
            .file(path: "archive/plans/.gitkeep", contents: ""),
            .file(path: "archive/worktrees/.gitkeep", contents: ""),
        ]
    }
}
