import Foundation
import SwiftData

extension AppModel {
    func defaultNamespace(in modelContext: ModelContext) -> RepositoryNamespace {
        if let existing = fetchDefaultNamespace(in: modelContext) {
            return existing
        }

        let namespace = RepositoryNamespace(
            name: Self.defaultNamespaceName,
            isDefault: true,
            sortOrder: 0
        )
        modelContext.insert(namespace)
        save(modelContext)
        return namespace
    }

    func fetchDefaultNamespace(in modelContext: ModelContext) -> RepositoryNamespace? {
        let descriptor = FetchDescriptor<RepositoryNamespace>(predicate: #Predicate { $0.isDefault })
        return try? modelContext.fetch(descriptor).first
    }

    func namespaces(in modelContext: ModelContext) -> [RepositoryNamespace] {
        let descriptor = FetchDescriptor<RepositoryNamespace>()
        return ((try? modelContext.fetch(descriptor)) ?? []).sorted(by: namespaceSort)
    }

    func projects(in namespace: RepositoryNamespace, modelContext: ModelContext? = nil) -> [RepositoryProject] {
        let context = modelContext ?? storedModelContext
        guard let context else { return namespace.projects.sorted(by: projectSort) }
        let namespaceID = namespace.id
        let descriptor = FetchDescriptor<RepositoryProject>(
            predicate: #Predicate { $0.namespace?.id == namespaceID },
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.name)
            ]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func visibleRepositories(
        from repositories: [ManagedRepository],
        in namespace: RepositoryNamespace?
    ) -> [ManagedRepository] {
        repositories
            .filter { repository in
                guard let namespace else { return repository.namespace == nil }
                return repository.namespace?.id == namespace.id
            }
            .sorted(by: repositorySort)
    }

    func ungroupedRepositories(from repositories: [ManagedRepository]) -> [ManagedRepository] {
        repositories.filter { $0.project == nil }
            .sorted(by: repositorySort)
    }

    func repositories(in project: RepositoryProject, from repositories: [ManagedRepository]) -> [ManagedRepository] {
        repositories.filter { $0.project?.id == project.id }
            .sorted(by: repositorySort)
    }

    func selectNamespace(_ namespace: RepositoryNamespace) {
        selectedNamespaceID = namespace.id
    }

    func presentNamespaceEditor(for namespace: RepositoryNamespace? = nil) {
        namespaceEditorDraft = NamespaceEditorDraft(
            mode: namespace == nil ? .create : .rename,
            namespaceID: namespace?.id,
            name: namespace?.name ?? ""
        )
    }

    func dismissNamespaceEditor() {
        namespaceEditorDraft = nil
    }

    func presentProjectEditor(in namespace: RepositoryNamespace, project: RepositoryProject? = nil) {
        projectEditorDraft = ProjectEditorDraft(
            mode: project == nil ? .create : .rename,
            namespaceID: namespace.id,
            projectID: project?.id,
            name: project?.name ?? ""
        )
    }

    func dismissProjectEditor() {
        projectEditorDraft = nil
    }

    func requestNamespaceDeletion(_ namespace: RepositoryNamespace) {
        pendingNamespaceDeletionID = namespace.id
    }

    func clearNamespaceDeletionRequest() {
        pendingNamespaceDeletionID = nil
    }

    func requestProjectDeletion(_ project: RepositoryProject) {
        pendingProjectDeletionID = project.id
    }

    func clearProjectDeletionRequest() {
        pendingProjectDeletionID = nil
    }

    func saveNamespace(name: String, editing namespace: RepositoryNamespace?, in modelContext: ModelContext) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            pendingErrorMessage = "Namespace name cannot be empty."
            return
        }

        if let namespace {
            guard !namespace.isDefault else {
                pendingErrorMessage = "The default namespace cannot be renamed."
                return
            }
            namespace.name = trimmedName
            namespace.updatedAt = .now
        } else {
            let namespace = RepositoryNamespace(
                name: trimmedName,
                sortOrder: nextNamespaceSortOrder(in: modelContext)
            )
            modelContext.insert(namespace)
            selectedNamespaceID = namespace.id
        }

        save(modelContext)
        dismissNamespaceEditor()
    }

    func saveProject(name: String, in namespace: RepositoryNamespace, editing project: RepositoryProject?, modelContext: ModelContext) {
        guard !namespace.isDefault else {
            pendingErrorMessage = "Projects are not available in the default namespace."
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            pendingErrorMessage = "Project name cannot be empty."
            return
        }

        if let project {
            project.name = trimmedName
            project.updatedAt = .now
        } else {
            let project = RepositoryProject(
                name: trimmedName,
                sortOrder: nextProjectSortOrder(in: namespace, modelContext: modelContext),
                namespace: namespace
            )
            modelContext.insert(project)
        }

        save(modelContext)
        dismissProjectEditor()
    }

    func deleteNamespace(_ namespace: RepositoryNamespace, in modelContext: ModelContext) {
        guard !namespace.isDefault else {
            pendingErrorMessage = "The default namespace cannot be deleted."
            return
        }

        let fallbackNamespace = defaultNamespace(in: modelContext)
        let namespaceRepositories = visibleRepositories(
            from: (try? modelContext.fetch(FetchDescriptor<ManagedRepository>())) ?? [],
            in: namespace
        )

        for repository in namespaceRepositories {
            repository.namespace = fallbackNamespace
            repository.project = nil
            repository.updatedAt = Date.now
        }

        for project in projects(in: namespace, modelContext: modelContext) {
            for repository in repositories(in: project, from: namespaceRepositories) {
                repository.namespace = fallbackNamespace
                repository.project = nil
                repository.updatedAt = Date.now
            }
            modelContext.delete(project)
        }

        if selectedNamespaceID == namespace.id {
            selectedNamespaceID = fallbackNamespace.id
        }

        modelContext.delete(namespace)
        save(modelContext)
        clearNamespaceDeletionRequest()
    }

    func deleteProject(_ project: RepositoryProject, in modelContext: ModelContext) {
        let fallbackNamespace = defaultNamespace(in: modelContext)
        let projectRepositories = repositories(
            in: project,
            from: (try? modelContext.fetch(FetchDescriptor<ManagedRepository>())) ?? []
        )

        for repository in projectRepositories {
            repository.namespace = fallbackNamespace
            repository.project = nil
            repository.updatedAt = Date.now
        }

        modelContext.delete(project)
        save(modelContext)
        clearProjectDeletionRequest()
    }

    func moveProject(_ project: RepositoryProject, to namespace: RepositoryNamespace, in modelContext: ModelContext) {
        guard !namespace.isDefault else {
            pendingErrorMessage = "Projects cannot be moved into the default namespace."
            return
        }

        project.namespace = namespace
        project.sortOrder = nextProjectSortOrder(in: namespace, modelContext: modelContext)
        project.updatedAt = .now

        let projectID = project.id
        let repositories = ((try? modelContext.fetch(FetchDescriptor<ManagedRepository>())) ?? []).filter {
            $0.project?.id == projectID
        }
        for repository in repositories {
            repository.namespace = namespace
            repository.project = project
            repository.updatedAt = .now
        }

        save(modelContext)
    }

    func assignRepository(
        _ repository: ManagedRepository,
        to namespace: RepositoryNamespace,
        project: RepositoryProject? = nil,
        in modelContext: ModelContext
    ) {
        guard project == nil || project?.namespace?.id == namespace.id else {
            pendingErrorMessage = "Project and namespace must match."
            return
        }

        repository.namespace = namespace
        repository.project = project
        repository.updatedAt = .now
        save(modelContext)

        if selectedNamespaceID == nil {
            selectedNamespaceID = namespace.id
        }
    }

    private func repositorySort(_ lhs: ManagedRepository, _ rhs: ManagedRepository) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private func projectSort(_ lhs: RepositoryProject, _ rhs: RepositoryProject) -> Bool {
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func namespaceSort(_ lhs: RepositoryNamespace, _ rhs: RepositoryNamespace) -> Bool {
        if lhs.isDefault != rhs.isDefault {
            return lhs.isDefault && !rhs.isDefault
        }
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func nextNamespaceSortOrder(in modelContext: ModelContext) -> Int {
        namespaces(in: modelContext).map(\.sortOrder).max().map { $0 + 1 } ?? 1
    }

    private func nextProjectSortOrder(in namespace: RepositoryNamespace, modelContext: ModelContext) -> Int {
        projects(in: namespace, modelContext: modelContext).map(\.sortOrder).max().map { $0 + 1 } ?? 0
    }
}
