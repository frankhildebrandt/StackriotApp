import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ManagedRepository.displayName) private var repositories: [ManagedRepository]

    var body: some View {
        @Bindable var appModel = appModel
        let selectedRepository = appModel.repository(for: repositories)
        let selectedWorktree = selectedRepository.flatMap { appModel.selectedWorktree(for: $0) }

        NavigationSplitView {
            SidebarView(
                repositories: repositories,
                selectedRepositoryID: $appModel.selectedRepositoryID,
                refreshingRepositoryIDs: appModel.refreshingRepositoryIDs,
                isAgentRunningForRepository: appModel.isAgentRunning(forRepository:),
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
            appModel.selectInitialRepository(from: repositories)
            await appModel.checkAgentAvailability()
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
        .sheet(isPresented: $appModel.isWorktreeSheetPresented) {
            if let repository = appModel.repository(for: repositories) {
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
        .alert("DevVault", isPresented: Binding(
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
