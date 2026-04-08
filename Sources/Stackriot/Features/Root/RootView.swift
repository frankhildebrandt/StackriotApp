import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query private var namespaceProjects: [RepositoryProject]
    @Query private var namespaces: [RepositoryNamespace]
    @Query(sort: \ManagedRepository.displayName) private var repositories: [ManagedRepository]

    var body: some View {
        @Bindable var appModel = appModel
        let selectedNamespace = appModel.namespace(for: namespaces)
        let visibleRepositories = appModel.visibleRepositories(from: repositories, in: selectedNamespace)
        let selectedRepository = appModel.repository(for: visibleRepositories)
        let selectedWorktree = selectedRepository.flatMap { appModel.selectedWorktree(for: $0) }
        let sidebarSnapshots = Dictionary(
            uniqueKeysWithValues: visibleRepositories.map { repository in
                (repository.id, appModel.sidebarSnapshot(for: repository))
            }
        )
        let editProject: (RepositoryProject) -> Void = { project in
            guard let namespace = project.namespace else { return }
            appModel.presentProjectEditor(in: namespace, project: project)
        }

        NavigationSplitView {
            SidebarView(
                namespaces: namespaces,
                projects: namespaceProjects,
                currentNamespace: selectedNamespace,
                repositories: visibleRepositories,
                sidebarSnapshotsByRepositoryID: sidebarSnapshots,
                selectedNamespaceID: $appModel.selectedNamespaceID,
                selectedRepositoryID: $appModel.selectedRepositoryID,
                onSelectNamespace: appModel.selectNamespace,
                onCreateNamespace: {
                    appModel.presentNamespaceEditor()
                },
                onEditNamespace: appModel.presentNamespaceEditor,
                onDeleteNamespace: { namespace in
                    appModel.deleteNamespace(namespace, in: modelContext)
                },
                onCreateProject: { namespace in
                    appModel.presentProjectEditor(in: namespace)
                },
                onEditProject: editProject,
                onMoveProject: { project, namespace in
                    appModel.moveProject(project, to: namespace, in: modelContext)
                },
                onDeleteProject: { project in
                    appModel.deleteProject(project, in: modelContext)
                },
                onAssignRepository: { repository, namespace, project in
                    appModel.assignRepository(repository, to: namespace, project: project, in: modelContext)
                },
                onAddRepository: {
                    appModel.presentRepositoryCreationSheet()
                },
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
                availableDevTools: appModel.availableDevTools(for:),
                availableExternalTerminals: SupportedExternalTerminal.installedCases,
                onOpenRepositoryInDevTool: { repository, tool in
                    Task {
                        await appModel.openDevTool(tool, for: repository, in: modelContext)
                    }
                },
                onOpenRepositoryInTerminal: { repository, terminal in
                    Task {
                        await appModel.openExternalTerminal(terminal, for: repository, in: modelContext)
                    }
                },
                onManageRemotes: appModel.presentRemoteManagement,
                onDeleteRepository: { repository in
                    Task {
                        await appModel.deleteRepository(repository, in: modelContext)
                    }
                }
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } content: {
            if let repository = selectedRepository {
                RepositoryDetailView(repository: repository)
            } else {
                ContentUnavailableView("No Repositories", systemImage: "shippingbox", description: Text("Create or clone a repository to start creating worktrees and actions."))
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
        .onChange(of: appModel.pendingAgentMarkdownWindowPayload?.id) { _, _ in
            guard let payload = appModel.pendingAgentMarkdownWindowPayload else { return }
            openWindow(id: "cursor-agent-markdown", value: payload)
            appModel.pendingAgentMarkdownWindowPayload = nil
        }
        .onChange(of: appModel.pendingQuickIntentActivationID) { _, activationID in
            guard activationID != nil else { return }
            openWindow(id: "quick-intent")
            appModel.pendingQuickIntentActivationID = nil
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
        .sheet(isPresented: $appModel.isRepositoryCreationSheetPresented) {
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
        .sheet(isPresented: $appModel.isPullRequestCheckoutSheetPresented) {
            if let repositoryID = appModel.pullRequestCheckoutDraft.repositoryID,
               let repository = appModel.repositoryRecord(with: repositoryID)
            {
                CheckoutPullRequestSheet(repository: repository)
            } else if let repository = appModel.repository(for: visibleRepositories) {
                CheckoutPullRequestSheet(repository: repository)
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
        .sheet(isPresented: Binding(
            get: { appModel.pendingAgentExecutionDraft != nil },
            set: { newValue in
                if !newValue {
                    appModel.dismissPendingAgentExecutionDraft()
                }
            }
        )) {
            PendingAgentExecutionSheet()
                .environment(appModel)
        }
        .sheet(isPresented: Binding(
            get: { appModel.activeAgentPlanDraftWorktreeID != nil },
            set: { newValue in
                if !newValue {
                    appModel.dismissPresentedAgentPlanDraft()
                }
            }
        )) {
            if let worktreeID = appModel.activeAgentPlanDraftWorktreeID {
                AgentPlanDraftSheet(worktreeID: worktreeID)
                    .environment(appModel)
            }
        }
        .alert(isPresented: pendingErrorBinding) {
            Alert(
                title: Text("Stackriot"),
                message: Text(pendingErrorText),
                dismissButton: .cancel(Text("OK")) {
                    appModel.pendingErrorMessage = nil
                }
            )
        }
    }

    private var pendingErrorBinding: Binding<Bool> {
        Binding(
            get: { appModel.pendingErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    appModel.pendingErrorMessage = nil
                }
            }
        )
    }

    private var pendingErrorText: String {
        appModel.pendingErrorMessage ?? ""
    }
}
