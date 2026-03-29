import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Query private var namespaceProjects: [RepositoryProject]
    @Query private var namespaces: [RepositoryNamespace]
    @Query(sort: \ManagedRepository.displayName) private var repositories: [ManagedRepository]

    var body: some View {
        @Bindable var appModel = appModel
        let selectedNamespace = appModel.namespace(for: namespaces)
        let visibleRepositories = appModel.visibleRepositories(from: repositories, in: selectedNamespace)
        let selectedRepository = appModel.repository(for: visibleRepositories)
        let selectedWorktree = selectedRepository.flatMap { appModel.selectedWorktree(for: $0) }

        NavigationSplitView {
            SidebarView(
                namespaces: namespaces,
                projects: namespaceProjects,
                currentNamespace: selectedNamespace,
                repositories: visibleRepositories,
                selectedNamespaceID: $appModel.selectedNamespaceID,
                selectedRepositoryID: $appModel.selectedRepositoryID,
                refreshingRepositoryIDs: appModel.refreshingRepositoryIDs,
                isAgentRunningForRepository: appModel.isAgentRunning(forRepository:),
                onSelectNamespace: appModel.selectNamespace,
                onCreateNamespace: {
                    appModel.presentNamespaceEditor()
                },
                onEditNamespace: appModel.presentNamespaceEditor,
                onDeleteNamespace: appModel.requestNamespaceDeletion,
                onCreateProject: { namespace in
                    appModel.presentProjectEditor(in: namespace)
                },
                onEditProject: { project in
                    if let namespace = project.namespace {
                        appModel.presentProjectEditor(in: namespace, project: project)
                    }
                },
                onMoveProject: { project, namespace in
                    appModel.moveProject(project, to: namespace, in: modelContext)
                },
                onDeleteProject: appModel.requestProjectDeletion,
                onAssignRepository: { repository, namespace, project in
                    appModel.assignRepository(repository, to: namespace, project: project, in: modelContext)
                },
                onAddRepository: appModel.presentCloneSheet,
                onRefreshRepository: { repository in
                    Task {
                        await appModel.refresh(repository, in: modelContext)
                    }
                },
                onRevealRepository: { repository in
                    Task {
                        await appModel.revealRepositoryInFinder(repository)
                    }
                },
                onManageRemotes: appModel.presentRemoteManagement,
                onDeleteRepository: appModel.requestRepositoryDeletion
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } content: {
            if let repository = selectedRepository {
                RepositoryDetailView(repository: repository)
            } else {
                ContentUnavailableView("No Repositories", systemImage: "shippingbox", description: Text("Clone a bare repository to start creating worktrees and actions."))
            }
        } detail: {
            if let repository = selectedRepository {
                RunConsoleColumn(repository: repository)
                    .navigationSplitViewColumnWidth(min: 360, ideal: 420)
            } else {
                ContentUnavailableView("No Console", systemImage: "terminal", description: Text("Select a repository and worktree to inspect terminal tabs."))
                    .navigationSplitViewColumnWidth(min: 360, ideal: 420)
            }
        }
        .task {
            appModel.configure(modelContext: modelContext)
            await appModel.checkAgentAvailability()
        }
        .task(id: namespaces.map(\.id)) {
            appModel.selectInitialNamespace(from: namespaces)
        }
        .task(id: visibleRepositories.map(\.id)) {
            appModel.selectInitialRepository(from: visibleRepositories)
        }
        .inspector(isPresented: $appModel.isDiffInspectorPresented) {
            if let repository = selectedRepository, let worktree = selectedWorktree {
                DiffInspectorView(repository: repository, worktree: worktree)
                    .environment(appModel)
                    .inspectorColumnWidth(min: 320, ideal: 420, max: 720)
            } else {
                ContentUnavailableView("No Diff", systemImage: "doc.text.magnifyingglass", description: Text("Select a workspace to inspect uncommitted changes."))
                    .inspectorColumnWidth(min: 320, ideal: 420, max: 720)
            }
        }
        .sheet(isPresented: $appModel.isCloneSheetPresented) {
            CloneRepositorySheet()
        }
        .sheet(item: $appModel.namespaceEditorDraft) { draft in
            NamespaceEditorSheet(draft: draft)
        }
        .sheet(item: $appModel.projectEditorDraft) { draft in
            ProjectEditorSheet(draft: draft)
        }
        .sheet(isPresented: $appModel.isWorktreeSheetPresented) {
            if let repository = appModel.repository(for: visibleRepositories) {
                CreateWorktreeSheet(repository: repository)
            }
        }
        .sheet(isPresented: Binding(
            get: { appModel.remoteManagementRepositoryID != nil },
            set: { newValue in
                if !newValue {
                    appModel.dismissRemoteManagement()
                }
            }
        )) {
            if
                let repositoryID = appModel.remoteManagementRepositoryID,
                let repository = appModel.repositoryRecord(with: repositoryID)
            {
                RemoteManagementSheet(repository: repository)
                    .environment(appModel)
            }
        }
        .sheet(isPresented: Binding(
            get: { appModel.publishDraft.repositoryID != nil && appModel.publishDraft.worktreeID != nil },
            set: { newValue in
                if !newValue {
                    appModel.dismissPublishSheet()
                }
            }
        )) {
            if
                let repositoryID = appModel.publishDraft.repositoryID,
                let worktreeID = appModel.publishDraft.worktreeID,
                let repository = appModel.repositoryRecord(with: repositoryID),
                let worktree = appModel.worktreeRecord(with: worktreeID)
            {
                PublishBranchSheet(repository: repository, worktree: worktree)
                    .environment(appModel)
            }
        }
        .confirmationDialog("Delete repository?", isPresented: Binding(
            get: { appModel.pendingRepositoryDeletionID != nil },
            set: { newValue in
                if !newValue {
                    appModel.clearRepositoryDeletionRequest()
                }
            }
        )) {
            if
                let repositoryID = appModel.pendingRepositoryDeletionID,
                let repository = appModel.repositoryRecord(with: repositoryID)
            {
                Button("Delete Repository", role: .destructive) {
                    Task {
                        await appModel.deleteRepository(repository, in: modelContext)
                    }
                }
            }
        } message: {
            if
                let repositoryID = appModel.pendingRepositoryDeletionID,
                let repository = appModel.repositoryRecord(with: repositoryID)
            {
                Text("This removes the bare repository and all associated worktrees for \(repository.displayName).")
            }
        }
        .confirmationDialog("Delete namespace?", isPresented: Binding(
            get: { appModel.pendingNamespaceDeletionID != nil },
            set: { newValue in
                if !newValue {
                    appModel.clearNamespaceDeletionRequest()
                }
            }
        )) {
            if
                let namespaceID = appModel.pendingNamespaceDeletionID,
                let namespace = appModel.namespaceRecord(with: namespaceID)
            {
                Button("Delete Namespace", role: .destructive) {
                    appModel.deleteNamespace(namespace, in: modelContext)
                }
            }
        } message: {
            if
                let namespaceID = appModel.pendingNamespaceDeletionID,
                let namespace = appModel.namespaceRecord(with: namespaceID)
            {
                Text("Projects in \(namespace.name) are removed and all contained repositories move to \(AppModel.defaultNamespaceName).")
            }
        }
        .confirmationDialog("Delete project?", isPresented: Binding(
            get: { appModel.pendingProjectDeletionID != nil },
            set: { newValue in
                if !newValue {
                    appModel.clearProjectDeletionRequest()
                }
            }
        )) {
            if
                let projectID = appModel.pendingProjectDeletionID,
                let project = appModel.projectRecord(with: projectID)
            {
                Button("Delete Project", role: .destructive) {
                    appModel.deleteProject(project, in: modelContext)
                }
            }
        } message: {
            if
                let projectID = appModel.pendingProjectDeletionID,
                let project = appModel.projectRecord(with: projectID)
            {
                Text("Repositories in \(project.name) move to \(AppModel.defaultNamespaceName) without a project.")
            }
        }
        .confirmationDialog(
            appModel.pendingTerminalCloseConfirmation?.title ?? "Terminal schließen?",
            isPresented: Binding(
                get: { appModel.pendingTerminalCloseConfirmation != nil },
                set: { newValue in
                    if !newValue {
                        appModel.clearPendingTerminalCloseConfirmation()
                    }
                }
            )
        ) {
            Button("Force Close", role: .destructive) {
                appModel.confirmPendingTerminalClose(in: modelContext)
            }
            Button("Cancel", role: .cancel) {
                appModel.clearPendingTerminalCloseConfirmation()
            }
        } message: {
            Text(appModel.pendingTerminalCloseConfirmation?.message ?? "")
        }
        .alert("Stackriot", isPresented: Binding(
            get: { appModel.pendingErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    appModel.pendingErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                appModel.pendingErrorMessage = nil
            }
        } message: {
            Text(appModel.pendingErrorMessage ?? "")
        }
    }
}
extension View {
    func confirmationDialog<Item: Identifiable>(
        _ title: String,
        item: Binding<Item?>,
        @ViewBuilder actions: @escaping (Item) -> some View,
        @ViewBuilder message: @escaping (Item) -> some View
    ) -> some View {
        confirmationDialog(title, isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        ), presenting: item.wrappedValue, actions: actions, message: message)
    }
}
