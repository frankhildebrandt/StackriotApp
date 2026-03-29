import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class AppModel: @unchecked Sendable {
    static let defaultNamespaceName = "Default Namespace"

    var selectedNamespaceID: UUID?
    var selectedRepositoryID: UUID?
    var selectedWorktreeIDsByRepository: [UUID: UUID] = [:]
    var cloneDraft = CloneRepositoryDraft()
    var worktreeDraft = WorktreeDraft()
    var namespaceEditorDraft: NamespaceEditorDraft?
    var projectEditorDraft: ProjectEditorDraft?
    var pendingErrorMessage: String?
    var worktreeStatuses: [UUID: WorktreeStatus] = [:]
    var worktreePendingMergeOfferID: UUID?
    var pendingIntegrationConflict: IntegrationConflictDraft?
    var activeRunIDs: Set<UUID> = []
    var refreshingRepositoryIDs: Set<UUID> = []
    var isCloneSheetPresented = false
    var isWorktreeSheetPresented = false
    var isDiffInspectorPresented = false
    var remoteManagementRepositoryID: UUID?
    var pendingRepositoryDeletionID: UUID?
    var pendingNamespaceDeletionID: UUID?
    var pendingProjectDeletionID: UUID?
    var publishDraft = PublishBranchDraft()
    var integrationDraft = IntegrationDraft()
    var nodeRuntimeStatus = NodeRuntimeStatusSnapshot(
        runtimeRootPath: AppPaths.nodeRuntimeRoot.path,
        npmCachePath: AppPaths.npmCacheDirectory.path
    )
    var availableAgents: Set<AIAgentTool> = []
    var runningAgentWorktreeIDs: Set<UUID> = []
    var terminalTabs = TerminalTabBookkeeping()

    let services: AppServices
    var runningProcesses: [UUID: RunningProcess] = [:]
    @ObservationIgnored
    var terminalSessions: [UUID: AgentTerminalSession] = [:]
    @ObservationIgnored
    var terminalTabAutoHideTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored
    var prMonitoringTasks: [UUID: Task<Void, Never>] = [:]
    var storedModelContext: ModelContext?
    var autoRefreshTask: Task<Void, Never>?
    var nodeRuntimeRefreshTask: Task<Void, Never>?

    init(services: AppServices = .production) {
        self.services = services
    }

    func configure(modelContext: ModelContext) {
        if storedModelContext == nil {
            storedModelContext = modelContext
            migrateLegacyRepositoriesIfNeeded(in: modelContext)
            startAutoRefreshLoopIfNeeded()
            startNodeRuntimeRefreshLoopIfNeeded()
            Task {
                nodeRuntimeStatus = await services.nodeRuntimeManager.statusSnapshot()
                await services.nodeRuntimeManager.refreshDefaultRuntimeIfNeeded(force: false)
                nodeRuntimeStatus = await services.nodeRuntimeManager.statusSnapshot()
                await refreshAllRepositories(force: false)
                restoreAllPRMonitoring(in: modelContext)
            }
        }
    }

    func selectInitialNamespace(from namespaces: [RepositoryNamespace]) {
        let preferred = namespaces.first(where: { $0.id == selectedNamespaceID })
        let fallback = namespaces.first(where: \.isDefault) ?? namespaces.first
        selectedNamespaceID = preferred?.id ?? fallback?.id
    }

    func selectInitialRepository(from repositories: [ManagedRepository]) {
        let currentSelectionVisible = repositories.contains(where: { $0.id == selectedRepositoryID })
        selectedRepositoryID = currentSelectionVisible ? selectedRepositoryID : repositories.first?.id
    }

    func namespace(for namespaces: [RepositoryNamespace]) -> RepositoryNamespace? {
        namespaces.first(where: { $0.id == selectedNamespaceID })
            ?? namespaces.first(where: \.isDefault)
            ?? namespaces.first
    }

    func repository(for repositories: [ManagedRepository]) -> ManagedRepository? {
        repositories.first(where: { $0.id == selectedRepositoryID }) ?? repositories.first
    }

    func selectedRepository() -> ManagedRepository? {
        guard let repositoryID = selectedRepositoryID else { return nil }
        return repositoryRecord(with: repositoryID)
    }

    func namespaceRecord(with id: UUID) -> RepositoryNamespace? {
        guard let modelContext = storedModelContext else { return nil }
        let descriptor = FetchDescriptor<RepositoryNamespace>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    func projectRecord(with id: UUID) -> RepositoryProject? {
        guard let modelContext = storedModelContext else { return nil }
        let descriptor = FetchDescriptor<RepositoryProject>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    func repositoryRecord(with id: UUID) -> ManagedRepository? {
        guard let modelContext = storedModelContext else { return nil }
        let descriptor = FetchDescriptor<ManagedRepository>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    func worktreeRecord(with id: UUID) -> WorktreeRecord? {
        guard let modelContext = storedModelContext else { return nil }
        let descriptor = FetchDescriptor<WorktreeRecord>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    func worktrees(for repository: ManagedRepository) -> [WorktreeRecord] {
        let worktrees: [WorktreeRecord]
        if let modelContext = storedModelContext {
            let repositoryID = repository.id
            let descriptor = FetchDescriptor<WorktreeRecord>(
                predicate: #Predicate { $0.repository?.id == repositoryID }
            )
            worktrees = (try? modelContext.fetch(descriptor)) ?? []
        } else {
            worktrees = repository.worktrees
        }

        return worktrees.sorted { lhs, rhs in
            if lhs.isDefaultBranchWorkspace != rhs.isDefaultBranchWorkspace {
                return lhs.isDefaultBranchWorkspace
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func selectedWorktreeID(for repository: ManagedRepository) -> UUID? {
        if let selectedID = selectedWorktreeIDsByRepository[repository.id] {
            return selectedID
        }

        return worktrees(for: repository).first?.id
    }

    func selectedWorktree(for repository: ManagedRepository) -> WorktreeRecord? {
        if let selectedID = selectedWorktreeID(for: repository) {
            return worktreeRecord(with: selectedID)
        }
        return nil
    }

    func ensureSelectedWorktree(in repository: ManagedRepository) {
        guard let selectedID = selectedWorktreeID(for: repository) else {
            selectedWorktreeIDsByRepository.removeValue(forKey: repository.id)
            return
        }

        if selectedWorktreeIDsByRepository[repository.id] != selectedID {
            selectedWorktreeIDsByRepository[repository.id] = selectedID
        }
    }

    func selectWorktree(_ worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectedWorktreeIDsByRepository[repository.id] = worktree.id
    }

    func visibleTabs(for worktree: WorktreeRecord, in repository: ManagedRepository) -> [RunRecord] {
        let runsByID = Dictionary(uniqueKeysWithValues: repository.runs.map { ($0.id, $0) })
        return terminalTabs.visibleRunIDs(for: worktree.id).compactMap { runsByID[$0] }
    }

    func selectedTab(for worktree: WorktreeRecord, in repository: ManagedRepository) -> RunRecord? {
        let runsByID = Dictionary(uniqueKeysWithValues: repository.runs.map { ($0.id, $0) })
        if let selectedID = terminalTabs.selectedVisibleRunID(for: worktree.id) {
            return runsByID[selectedID]
        }
        return visibleTabs(for: worktree, in: repository).first
    }

    func selectTab(_ run: RunRecord) {
        guard let worktreeID = run.worktree?.id else { return }
        cancelAutoHide(for: run.id)
        if let repositoryID = run.repository?.id {
            selectedWorktreeIDsByRepository[repositoryID] = worktreeID
        }
        terminalTabs.activate(runID: run.id, worktreeID: worktreeID)
    }

    func closeTab(_ run: RunRecord) {
        guard !activeRunIDs.contains(run.id) else { return }
        cancelAutoHide(for: run.id)
        terminalTabs.hide(runID: run.id)
    }

    func reopenTab(_ run: RunRecord) {
        guard let worktreeID = run.worktree?.id else { return }
        if let repositoryID = run.repository?.id {
            selectedWorktreeIDsByRepository[repositoryID] = worktreeID
        }
        terminalTabs.activate(runID: run.id, worktreeID: worktreeID)
        if !activeRunIDs.contains(run.id), run.status != .running {
            scheduleAutoHideIfNeeded(for: run.id)
        }
    }

    func tabState(for run: RunRecord) -> TerminalTabState? {
        terminalTabs.tabState(for: run.id)
    }

    func presentCloneSheet() {
        cloneDraft = CloneRepositoryDraft()
        isCloneSheetPresented = true
    }

    func presentWorktreeSheet(for repository: ManagedRepository) {
        worktreeDraft = WorktreeDraft(sourceBranch: repository.defaultBranch)
        isWorktreeSheetPresented = true
    }

    func presentWorktreeSheetForSelection() {
        guard let repository = selectedRepository() else {
            pendingErrorMessage = "Select a repository before creating a worktree."
            return
        }

        presentWorktreeSheet(for: repository)
    }

    func presentRemoteManagement(for repository: ManagedRepository) {
        remoteManagementRepositoryID = repository.id
    }

    func dismissRemoteManagement() {
        remoteManagementRepositoryID = nil
    }

    func requestRepositoryDeletion(_ repository: ManagedRepository) {
        pendingRepositoryDeletionID = repository.id
    }

    func clearRepositoryDeletionRequest() {
        pendingRepositoryDeletionID = nil
    }

    func presentPublishSheet(for repository: ManagedRepository, worktree: WorktreeRecord) {
        publishDraft = PublishBranchDraft(
            repositoryID: repository.id,
            worktreeID: worktree.id,
            remoteName: resolvedDefaultRemote(for: repository)?.name ?? ""
        )
    }

    func dismissPublishSheet() {
        publishDraft = PublishBranchDraft()
    }

    func runs(forWorktreeID worktreeID: UUID, in repository: ManagedRepository) -> [RunRecord] {
        repository.runs
            .filter { $0.worktreeID == worktreeID }
            .sorted(by: { $0.startedAt > $1.startedAt })
    }

    func defaultBranchWorkspace(for repository: ManagedRepository) -> WorktreeRecord? {
        worktrees(for: repository).first(where: \.isDefaultBranchWorkspace)
    }
}
