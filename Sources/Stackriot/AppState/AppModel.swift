import AppKit
import Foundation
import Observation
import OSLog
import SwiftData
import SwiftUI

@MainActor
@Observable
final class AppModel: @unchecked Sendable {
    static let defaultNamespaceName = "Default Namespace"

    @ObservationIgnored
    private let userDefaults: UserDefaults

    var selectedNamespaceID: UUID? {
        didSet {
            persistSelectedNamespaceID()
        }
    }
    var selectedRepositoryID: UUID? {
        didSet {
            guard selectedRepositoryID != oldValue else { return }
            beginRepositorySelectionTrace()
            primeSelectedRepositoryCachesIfNeeded()
        }
    }
    var selectedWorktreeIDsByRepository: [UUID: UUID] = [:]
    var repositoryCreationDraft = RepositoryCreationDraft()
    var worktreeDraft = WorktreeDraft()
    var pullRequestCheckoutDraft = PullRequestCheckoutDraft()
    var namespaceEditorDraft: NamespaceEditorDraft?
    var projectEditorDraft: ProjectEditorDraft?
    var projectDocumentationSourceDraft: ProjectDocumentationSourceDraft?
    var pendingErrorMessage: String?
    var worktreeStatuses: [UUID: WorktreeStatus] = [:]
    var pullRequestUpstreamStatuses: [UUID: PullRequestUpstreamStatus] = [:]
    var syncLogs: [UUID: String] = [:]
    var activeRunIDs: Set<UUID> = []
    var refreshingRepositoryIDs: Set<UUID> = []
    var isRepositoryCreationSheetPresented = false
    var isWorktreeSheetPresented = false
    var isPullRequestCheckoutSheetPresented = false
    var isDiffInspectorPresented = false
    var remoteManagementRepositoryID: UUID?
    var publishDraft = PublishBranchDraft()
    var integrationDraft = IntegrationDraft()
    var nodeRuntimeStatus = NodeRuntimeStatusSnapshot(
        runtimeRootPath: AppPaths.nodeRuntimeRoot.path,
        npmCachePath: AppPaths.npmCacheDirectory.path
    )
    var localToolStatuses: [AppManagedToolStatus] = []
    var availableAgents: Set<AIAgentTool> = []
    var acpAgentSnapshotsByTool: [AIAgentTool: ACPAgentSnapshot] = [:]
    var runningAgentWorktreeIDs: Set<UUID> = []
    var terminalTabs = TerminalTabBookkeeping()
    var summarizingRunIDs: Set<UUID> = []
    var dismissedAISummaryRunIDs: Set<UUID> = []
    var agentPlanDraftsByWorktreeID: [UUID: AgentPlanDraft] = [:]
    var pendingRunFixesByAgentRunID: [UUID: RunFixRequest] = [:]
    var activeAgentPlanDraftWorktreeID: UUID?
    var pendingAgentExecutionDraft: PendingAgentExecutionDraft?
    var quickIntentSession: QuickIntentSession?
    var pendingQuickIntentActivationID: UUID?
    var intentContentVersionsByWorktreeID: [UUID: Int] = [:]
    var implementationPlanContentVersionsByWorktreeID: [UUID: Int] = [:]
    @ObservationIgnored
    var intentContentsByWorktreeID: [UUID: String] = [:]
    @ObservationIgnored
    var implementationPlanContentsByWorktreeID: [UUID: String] = [:]
    @ObservationIgnored
    var implementationPlanPresenceByWorktreeID: [UUID: Bool] = [:]
    @ObservationIgnored
    var runConfigurationsByWorktreeID: [UUID: [RunConfiguration]] = [:]
    @ObservationIgnored
    var runConfigurationWorkspacePathsByWorktreeID: [UUID: String] = [:]
    @ObservationIgnored
    var dependencyActionAvailabilityByWorktreeID: [UUID: Bool] = [:]
    @ObservationIgnored
    var runConfigurationRefreshTasksByWorktreeID: [UUID: Task<[RunConfiguration], Never>] = [:]
    var worktreeDiscoverySnapshotsByID: [UUID: WorktreeDiscoverySnapshot] = [:]
    var devContainerStatesByWorktreeID: [UUID: DevContainerWorkspaceState] = [:]
    var repositorySidebarSnapshotsByID: [UUID: RepositorySidebarSnapshot] = [:]
    var repositoryDetailSnapshotsByID: [UUID: RepositoryDetailSnapshot] = [:]
    var mcpServerStatus = MCPServerStatus.idle()
    var mcpLogEntries: [MCPLogEntry] = []
    /// When set, `RootView` opens `WindowGroup(id: "cursor-agent-markdown")` with this payload.
    var pendingAgentMarkdownWindowPayload: AgentMarkdownWindowPayload?

    let services: AppServices
    var runningProcesses: [UUID: RunningProcess] = [:]
    @ObservationIgnored
    var terminalSessions: [UUID: AgentTerminalSession] = [:]
    @ObservationIgnored
    var acpRunSessionsByRunID: [UUID: ACPAgentRunSession] = [:]
    @ObservationIgnored
    var terminalTabAutoHideTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored
    var forceClosingTerminalRunIDs: Set<UUID> = []
    @ObservationIgnored
    var delegatedAgentRunIDs: Set<UUID> = []
    @ObservationIgnored
    var prMonitoringCoordinatorTask: Task<Void, Never>?
    @ObservationIgnored
    var lastForegroundLightRefreshAt: Date?
    @ObservationIgnored
    var pendingRunOutputBuffer: [UUID: String] = [:]
    @ObservationIgnored
    var runOutputFlushTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored
    var devContainerLogProcessesByWorktreeID: [UUID: RunningProcess] = [:]
    @ObservationIgnored
    var devContainerStateRefreshTasksByWorktreeID: [UUID: Task<DevContainerWorkspaceSnapshot, Never>] = [:]
    @ObservationIgnored
    var rawLogDiskBuffer: [UUID: String] = [:]
    @ObservationIgnored
    var rawLogFlushTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored
    let incomingRunOutputThrottle = RunOutputThrottle()
    @ObservationIgnored
    let rawLogAppendCoordinator = RawLogAppendCoordinator()
    @ObservationIgnored
    var rawLogFileURLsByRunID: [UUID: URL] = [:]
    @ObservationIgnored
    var structuredOutputParsersByRunID: [UUID: any StructuredAgentOutputParsing] = [:]
    @ObservationIgnored
    var rawLogRecordIDsByRunID: [UUID: UUID] = [:]
    var agentRunSegmentsByRunID: [UUID: [AgentRunSegment]] = [:]
    var pendingACPPermissionRequestsByRunID: [UUID: ACPPermissionRequestState] = [:]
    @ObservationIgnored
    var deliveredCursorAgentMarkdownSnapshotRunIDs: Set<UUID> = []
    var storedModelContext: ModelContext?
    var autoRefreshTask: Task<Void, Never>?
    var nodeRuntimeRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    var worktreeStatusPollingTask: Task<Void, Never>?
    @ObservationIgnored
    var lastWorktreeStatusPollAt: Date?
    @ObservationIgnored
    var worktreeStatusRefreshTasksByRepositoryID: [UUID: Task<WorktreeStatusRefreshResult, Never>] = [:]
    @ObservationIgnored
    var pendingWorktreeStatusRefreshRepositoryIDs: Set<UUID> = []
    @ObservationIgnored
    var worktreeStatusRefreshGenerationByRepositoryID: [UUID: Int] = [:]
    @ObservationIgnored
    var repositoryWorktreeMonitoringByRepositoryID: [UUID: RepositoryWorktreeMonitor] = [:]
    @ObservationIgnored
    var repositoryWorktreeReconcileTasksByRepositoryID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored
    var pendingRepositoryWorktreeReconcileRepositoryIDs: Set<UUID> = []
    @ObservationIgnored
    var autoRebasingRepositoryIDs: Set<UUID> = []
    @ObservationIgnored
    var pendingAutoRebaseRepositoryIDs: Set<UUID> = []
    @ObservationIgnored
    var devContainerMonitoringTask: Task<Void, Never>?
    @ObservationIgnored
    let selectionPerformanceMonitor = SelectionPerformanceMonitor()

    init(
        services: AppServices = .production,
        userDefaults: UserDefaults = .standard
    ) {
        self.services = services
        self.userDefaults = userDefaults
        selectedNamespaceID = userDefaults.string(forKey: AppPreferences.selectedNamespaceIDKey)
            .flatMap(UUID.init(uuidString:))
    }

    var pendingCopilotExecutionDraft: PendingAgentExecutionDraft? {
        get { pendingAgentExecutionDraft }
        set { pendingAgentExecutionDraft = newValue }
    }

    func configure(modelContext: ModelContext) {
        if storedModelContext == nil {
            storedModelContext = modelContext
            prepareNotificationsIfNeeded()
            configureQuickIntentHotKey()
            migrateLegacyRepositoriesIfNeeded(in: modelContext)
            migrateWorktreePrimaryContextsIfNeeded(in: modelContext)
            startAutoRefreshLoopIfNeeded()
            startNodeRuntimeRefreshLoopIfNeeded()
            startWorktreeStatusPollingIfNeeded()
            startDevContainerMonitoringLoopIfNeeded()
            Task {
                nodeRuntimeStatus = await services.nodeRuntimeManager.statusSnapshot()
                await services.nodeRuntimeManager.refreshDefaultRuntimeIfNeeded(force: false)
                nodeRuntimeStatus = await services.nodeRuntimeManager.statusSnapshot()
                localToolStatuses = await services.localToolManager.allStatuses()
                availableAgents = await services.agentManager.checkAvailability()
                acpAgentSnapshotsByTool = await services.acpDiscoveryService.snapshots(
                    for: availableAgents,
                    workingDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                )
                await refreshAllRepositories(force: false)
                await refreshAllDevContainerStates()
                restoreAllPRMonitoring(in: modelContext)
                await configureMCPServer()
            }
        }
    }

    func selectInitialNamespace(from namespaces: [RepositoryNamespace]) {
        let preferred = namespaces.first(where: { $0.id == selectedNamespaceID })
        let fallback = namespaces.first(where: \.isDefault) ?? namespaces.first
        selectedNamespaceID = preferred?.id ?? fallback?.id
    }

    private func persistSelectedNamespaceID() {
        if let selectedNamespaceID {
            userDefaults.set(selectedNamespaceID.uuidString, forKey: AppPreferences.selectedNamespaceIDKey)
        } else {
            userDefaults.removeObject(forKey: AppPreferences.selectedNamespaceIDKey)
        }
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
        repository.worktrees.sorted { lhs, rhs in
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

    func selectedWorktreeID(for repository: ManagedRepository) -> UUID? {
        if let selectedID = selectedWorktreeIDsByRepository[repository.id] {
            return selectedID
        }

        return worktrees(for: repository).first?.id
    }

    func selectedWorktree(for repository: ManagedRepository) -> WorktreeRecord? {
        if let selectedID = selectedWorktreeID(for: repository) {
            return worktrees(for: repository).first(where: { $0.id == selectedID })
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
            terminalTabs.selectPlanTab(for: selectedID)
            beginWorktreeSelectionTrace(repositoryID: repository.id, worktreeID: selectedID)
        }
        refreshRepositoryDetailSnapshot(for: repository)
    }

    func selectWorktree(_ worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectedWorktreeIDsByRepository[repository.id] = worktree.id
        terminalTabs.selectPlanTab(for: worktree.id)
        beginWorktreeSelectionTrace(repositoryID: repository.id, worktreeID: worktree.id)
        _ = ensureWorktreeDiscoverySnapshot(for: worktree)
        _ = refreshAvailableDevToolsCache(for: worktree)
        Task {
            await refreshAvailableRunConfigurationsCache(for: worktree)
        }
        refreshRepositoryDetailSnapshot(for: repository)
    }

    func visibleTabs(for worktree: WorktreeRecord, in repository: ManagedRepository) -> [RunRecord] {
        measureSelectionPhase(
            repositoryID: repository.id,
            worktreeID: worktree.id,
            phase: "resolve-visible-tabs",
            metadata: ["repositoryRunCount": repository.runs.count]
        ) {
            let runsByID = Dictionary(uniqueKeysWithValues: repository.runs.map { ($0.id, $0) })
            return terminalTabs.visibleRunIDs(for: worktree.id).compactMap { runsByID[$0] }
        }
    }

    func selectedTab(for worktree: WorktreeRecord, in repository: ManagedRepository) -> RunRecord? {
        measureSelectionPhase(
            repositoryID: repository.id,
            worktreeID: worktree.id,
            phase: "resolve-selected-tab",
            metadata: ["repositoryRunCount": repository.runs.count]
        ) {
            let runsByID = Dictionary(uniqueKeysWithValues: repository.runs.map { ($0.id, $0) })
            if let selectedID = terminalTabs.selectedVisibleRunID(for: worktree.id) {
                return runsByID[selectedID]
            }
            return visibleTabs(for: worktree, in: repository).first
        }
    }

    func selectTab(_ run: RunRecord) {
        guard let worktreeID = run.worktreeID else { return }
        cancelAutoHide(for: run.id)
        if let repositoryID = run.repositoryID {
            selectedWorktreeIDsByRepository[repositoryID] = worktreeID
        }
        terminalTabs.deselectPlanTab(for: worktreeID)
        terminalTabs.activate(runID: run.id, worktreeID: worktreeID)
    }

    func navigateToRun(_ run: RunRecord) {
        guard let repository = run.repository else { return }

        openRepository(repository)

        guard run.worktree != nil else { return }
        selectTab(run)
    }

    func openRepository(_ repository: ManagedRepository) {
        if let namespaceID = repository.namespace?.id {
            selectedNamespaceID = namespaceID
        }
        selectedRepositoryID = repository.id
    }

    func closeTab(_ run: RunRecord) {
        guard !activeRunIDs.contains(run.id) else { return }
        cancelAutoHide(for: run.id)
        terminalTabs.hide(runID: run.id)
        terminalSessions[run.id]?.terminate()
        terminalSessions[run.id] = nil
    }

    func reopenTab(_ run: RunRecord) {
        guard let worktreeID = run.worktreeID else { return }
        if let repositoryID = run.repositoryID {
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

    func beginRepositorySelectionTrace() {
        guard let repositoryID = selectedRepositoryID else { return }
        selectionPerformanceMonitor.beginRepositorySelection(repositoryID: repositoryID)
    }

    func beginWorktreeSelectionTrace(repositoryID: UUID, worktreeID: UUID) {
        selectionPerformanceMonitor.beginWorktreeSelection(
            repositoryID: repositoryID,
            worktreeID: worktreeID
        )
    }

    func markWorktreeListVisible(for repositoryID: UUID) {
        selectionPerformanceMonitor.markWorktreeListVisible(repositoryID: repositoryID)
    }

    func markRepositoryDetailVisible(for repositoryID: UUID) {
        selectionPerformanceMonitor.markRepositoryDetailVisible(repositoryID: repositoryID)
    }

    func markRunConsoleVisible(for repositoryID: UUID, worktreeID: UUID) {
        selectionPerformanceMonitor.markRunConsoleVisible(
            repositoryID: repositoryID,
            worktreeID: worktreeID
        )
    }

    func recordWorktreeStatusRefreshStart(for repositoryID: UUID) {
        selectionPerformanceMonitor.recordWorktreeStatusRefreshStart(repositoryID: repositoryID)
    }

    func recordDevContainerRefreshStart(for worktreeID: UUID) {
        selectionPerformanceMonitor.recordDevContainerRefreshStart(worktreeID: worktreeID)
    }

    func recordDevContainerConfigurationProbe(for worktreeID: UUID) {
        selectionPerformanceMonitor.recordDevContainerConfigurationProbe(for: worktreeID)
    }

    func recordDevToolDiscovery(for worktreeID: UUID) {
        selectionPerformanceMonitor.recordDevToolDiscovery(for: worktreeID)
    }

    func recordSelectionPhase(
        repositoryID: UUID,
        worktreeID: UUID? = nil,
        phase: String,
        durationMS: Int? = nil,
        metadata: [String: Any] = [:]
    ) {
        selectionPerformanceMonitor.recordPhase(
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            phase: phase,
            durationMS: durationMS,
            metadata: metadata
        )
    }

    func measureSelectionPhase<T>(
        repositoryID: UUID,
        worktreeID: UUID? = nil,
        phase: String,
        metadata: [String: Any] = [:],
        operation: () -> T
    ) -> T {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = operation()
        let durationMS = selectionPerformanceMonitor.milliseconds(from: startedAt, to: clock.now)
        recordSelectionPhase(
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            phase: phase,
            durationMS: durationMS,
            metadata: metadata
        )
        return result
    }

    func primeSelectedRepositoryCachesIfNeeded() {
        guard let repositoryID = selectedRepositoryID else { return }
        let repository = measureSelectionPhase(
            repositoryID: repositoryID,
            phase: "selected-repository-fetch"
        ) {
            selectedRepository()
        }
        guard let repository else { return }
        measureSelectionPhase(
            repositoryID: repositoryID,
            phase: "prime-worktree-configuration-snapshots",
            metadata: ["worktreeCount": repository.worktrees.count]
        ) {
            primeWorktreeConfigurationSnapshots(for: repository)
        }
        measureSelectionPhase(
            repositoryID: repositoryID,
            phase: "refresh-repository-sidebar-snapshot"
        ) {
            refreshRepositorySidebarSnapshot(for: repository)
        }
        if let selectedWorktreeID = selectedWorktreeID(for: repository),
           let selectedWorktree = worktrees(for: repository).first(where: { $0.id == selectedWorktreeID })
        {
            Task {
                await refreshAvailableRunConfigurationsCache(for: selectedWorktree)
            }
        }
    }

    func presentRepositoryCreationSheet(initialMode: RepositoryCreationMode = .cloneRemote) {
        repositoryCreationDraft = RepositoryCreationDraft(mode: initialMode)
        isRepositoryCreationSheetPresented = true
    }

    func performanceDebugArtifactURL() -> URL {
        AppPaths.performanceDebugArtifactFile
    }

    func revealPerformanceDebugArtifact() async {
        do {
            let url = performanceDebugArtifactURL()
            try FileManager.default.createDirectory(at: AppPaths.diagnosticsDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url)
            }
            try await services.ideManager.revealInFinder(path: url)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func clearPerformanceDebugArtifact() {
        do {
            let url = performanceDebugArtifactURL()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            selectionPerformanceMonitor.resetArtifactSession()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func copyPerformanceDebugArtifactToPasteboard() {
        do {
            let url = performanceDebugArtifactURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                pendingErrorMessage = "No performance debug artifact exists yet."
                return
            }

            let contents = try String(contentsOf: url, encoding: .utf8)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(contents, forType: .string)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func presentWorktreeSheet(for repository: ManagedRepository) {
        worktreeDraft = WorktreeDraft(
            sourceBranch: repository.defaultBranch,
            creationMode: .ideaTree
        )
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

@MainActor
final class SelectionPerformanceMonitor {
    private struct ActiveTrace {
        let repositoryID: UUID
        var worktreeID: UUID?
        let startedAt: ContinuousClock.Instant
        var worktreeListVisibleAt: ContinuousClock.Instant?
        var repositoryDetailVisibleAt: ContinuousClock.Instant?
        var runConsoleVisibleAt: ContinuousClock.Instant?
        var devToolDiscoveryCount = 0
        var devContainerConfigurationProbeCount = 0
        var worktreeStatusRefreshCount = 0
        var devContainerRefreshCount = 0
    }

    private let logger = Logger(subsystem: "Stackriot", category: "selection-performance")
    private let clock = ContinuousClock()
    private let artifactRecorder = PerformanceDebugArtifactRecorder()
    private var activeTrace: ActiveTrace?

    func beginRepositorySelection(repositoryID: UUID) {
        activeTrace = ActiveTrace(
            repositoryID: repositoryID,
            worktreeID: nil,
            startedAt: clock.now
        )
        logger.debug("selection-begin repository=\(repositoryID.uuidString, privacy: .public)")
        artifactRecorder.record(
            kind: "selection-begin",
            payload: [
                "selectionKind": "repository",
                "repositoryID": repositoryID.uuidString
            ]
        )
    }

    func beginWorktreeSelection(repositoryID: UUID, worktreeID: UUID) {
        activeTrace = ActiveTrace(
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            startedAt: clock.now
        )
        logger.debug(
            "selection-begin repository=\(repositoryID.uuidString, privacy: .public) worktree=\(worktreeID.uuidString, privacy: .public)"
        )
        artifactRecorder.record(
            kind: "selection-begin",
            payload: [
                "selectionKind": "worktree",
                "repositoryID": repositoryID.uuidString,
                "worktreeID": worktreeID.uuidString
            ]
        )
    }

    func markWorktreeListVisible(repositoryID: UUID) {
        guard var trace = activeTrace, trace.repositoryID == repositoryID else { return }
        trace.worktreeListVisibleAt = trace.worktreeListVisibleAt ?? clock.now
        activeTrace = trace
        artifactRecorder.record(
            kind: "selection-step",
            payload: tracePayload(for: trace, extra: [
                "step": "worktree-list-visible",
                "elapsedMS": milliseconds(from: trace.startedAt, to: trace.worktreeListVisibleAt ?? clock.now)
            ])
        )
        maybeLogCompletion()
    }

    func markRepositoryDetailVisible(repositoryID: UUID) {
        guard var trace = activeTrace, trace.repositoryID == repositoryID else { return }
        trace.repositoryDetailVisibleAt = trace.repositoryDetailVisibleAt ?? clock.now
        activeTrace = trace
        artifactRecorder.record(
            kind: "selection-step",
            payload: tracePayload(for: trace, extra: [
                "step": "repository-detail-visible",
                "elapsedMS": milliseconds(from: trace.startedAt, to: trace.repositoryDetailVisibleAt ?? clock.now)
            ])
        )
        maybeLogCompletion()
    }

    func markRunConsoleVisible(repositoryID: UUID, worktreeID: UUID) {
        guard var trace = activeTrace, trace.repositoryID == repositoryID else { return }
        trace.worktreeID = trace.worktreeID ?? worktreeID
        trace.runConsoleVisibleAt = trace.runConsoleVisibleAt ?? clock.now
        activeTrace = trace
        artifactRecorder.record(
            kind: "selection-step",
            payload: tracePayload(for: trace, extra: [
                "step": "run-console-visible",
                "elapsedMS": milliseconds(from: trace.startedAt, to: trace.runConsoleVisibleAt ?? clock.now)
            ])
        )
        maybeLogCompletion()
    }

    func recordWorktreeStatusRefreshStart(repositoryID: UUID) {
        guard activeTrace?.repositoryID == repositoryID else { return }
        activeTrace?.worktreeStatusRefreshCount += 1
        if let trace = activeTrace {
            artifactRecorder.record(
                kind: "refresh-start",
                payload: tracePayload(for: trace, extra: [
                    "refreshKind": "worktree-status",
                    "count": trace.worktreeStatusRefreshCount
                ])
            )
        }
    }

    func recordDevContainerRefreshStart(worktreeID: UUID) {
        guard activeTrace?.worktreeID == worktreeID else { return }
        activeTrace?.devContainerRefreshCount += 1
        if let trace = activeTrace {
            artifactRecorder.record(
                kind: "refresh-start",
                payload: tracePayload(for: trace, extra: [
                    "refreshKind": "devcontainer-state",
                    "count": trace.devContainerRefreshCount
                ])
            )
        }
    }

    func recordDevContainerConfigurationProbe(for worktreeID: UUID) {
        guard activeTrace?.worktreeID == worktreeID else { return }
        activeTrace?.devContainerConfigurationProbeCount += 1
        if let trace = activeTrace {
            artifactRecorder.record(
                kind: "discovery",
                payload: tracePayload(for: trace, extra: [
                    "discoveryKind": "devcontainer-config",
                    "count": trace.devContainerConfigurationProbeCount
                ])
            )
        }
    }

    func recordDevToolDiscovery(for worktreeID: UUID) {
        guard activeTrace?.worktreeID == worktreeID else { return }
        activeTrace?.devToolDiscoveryCount += 1
        if let trace = activeTrace {
            artifactRecorder.record(
                kind: "discovery",
                payload: tracePayload(for: trace, extra: [
                    "discoveryKind": "devtool",
                    "count": trace.devToolDiscoveryCount
                ])
            )
        }
    }

    func recordPhase(
        repositoryID: UUID,
        worktreeID: UUID? = nil,
        phase: String,
        durationMS: Int? = nil,
        metadata: [String: Any] = [:]
    ) {
        guard let trace = activeTrace, trace.repositoryID == repositoryID else { return }
        var payload = tracePayload(for: trace, extra: metadata.merging(["phase": phase]) { _, new in new })
        if let worktreeID {
            payload["worktreeID"] = worktreeID.uuidString
        }
        if let durationMS {
            payload["durationMS"] = durationMS
        }
        artifactRecorder.record(kind: "selection-phase", payload: payload)
        logger.debug(
            "selection-phase repository=\(repositoryID.uuidString, privacy: .public) phase=\(phase, privacy: .public) durationMS=\(durationMS ?? -1)"
        )
    }

    func resetArtifactSession() {
        artifactRecorder.resetSession()
    }

    private func maybeLogCompletion() {
        guard
            let trace = activeTrace,
            let worktreeListVisibleAt = trace.worktreeListVisibleAt,
            let repositoryDetailVisibleAt = trace.repositoryDetailVisibleAt,
            let runConsoleVisibleAt = trace.runConsoleVisibleAt
        else {
            return
        }

        let worktreeListMS = milliseconds(from: trace.startedAt, to: worktreeListVisibleAt)
        let repositoryDetailMS = milliseconds(from: trace.startedAt, to: repositoryDetailVisibleAt)
        let runConsoleMS = milliseconds(from: trace.startedAt, to: runConsoleVisibleAt)

        logger.debug(
            """
            selection-complete repository=\(trace.repositoryID.uuidString, privacy: .public) \
            worktree=\(trace.worktreeID?.uuidString ?? "-", privacy: .public) \
            worktreeListMS=\(worktreeListMS) detailMS=\(repositoryDetailMS) runConsoleMS=\(runConsoleMS) \
            devToolDiscoveryCount=\(trace.devToolDiscoveryCount) \
            devContainerConfigProbeCount=\(trace.devContainerConfigurationProbeCount) \
            worktreeStatusRefreshCount=\(trace.worktreeStatusRefreshCount) \
            devContainerRefreshCount=\(trace.devContainerRefreshCount)
            """
        )
        artifactRecorder.record(
            kind: "selection-complete",
            payload: tracePayload(for: trace, extra: [
                "worktreeListMS": worktreeListMS,
                "detailMS": repositoryDetailMS,
                "runConsoleMS": runConsoleMS,
                "devToolDiscoveryCount": trace.devToolDiscoveryCount,
                "devContainerConfigProbeCount": trace.devContainerConfigurationProbeCount,
                "worktreeStatusRefreshCount": trace.worktreeStatusRefreshCount,
                "devContainerRefreshCount": trace.devContainerRefreshCount
            ])
        )
        activeTrace = nil
    }

    func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: end)
        let secondsMS = Double(duration.components.seconds) * 1_000
        let attosecondsMS = Double(duration.components.attoseconds) / 1_000_000_000_000_000
        return Int(secondsMS + attosecondsMS)
    }

    private func tracePayload(for trace: ActiveTrace, extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = [
            "repositoryID": trace.repositoryID.uuidString
        ]
        if let worktreeID = trace.worktreeID {
            payload["worktreeID"] = worktreeID.uuidString
        }
        for (key, value) in extra {
            payload[key] = value
        }
        return payload
    }
}

private final class PerformanceDebugArtifactRecorder {
    private var sessionID: UUID?
    private let dateFormatter = ISO8601DateFormatter()

    func resetSession() {
        sessionID = nil
    }

    func record(kind: String, payload: [String: Any]) {
        guard AppPreferences.performanceDebugModeEnabled else { return }
        do {
            try FileManager.default.createDirectory(at: AppPaths.diagnosticsDirectory, withIntermediateDirectories: true)
            let fileURL = AppPaths.performanceDebugArtifactFile
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }

            let sessionID = try ensureSession()
            var record = payload
            record["kind"] = kind
            record["recordedAt"] = dateFormatter.string(from: .now)
            record["sessionID"] = sessionID.uuidString

            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            guard var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let encoded = line.data(using: .utf8) {
                try handle.write(contentsOf: encoded)
            }
        } catch {
            Logger(subsystem: "Stackriot", category: "selection-performance").error(
                "performance-artifact-write-failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func ensureSession() throws -> UUID {
        if let sessionID {
            return sessionID
        }
        let newSessionID = UUID()
        sessionID = newSessionID
        try writeSessionHeader(sessionID: newSessionID)
        return newSessionID
    }

    private func writeSessionHeader(sessionID: UUID) throws {
        let bundleInfo = Bundle.main.infoDictionary ?? [:]
        let payload: [String: Any] = [
            "kind": "session-header",
            "recordedAt": dateFormatter.string(from: .now),
            "sessionID": sessionID.uuidString,
            "appVersion": bundleInfo["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildNumber": bundleInfo["CFBundleVersion"] as? String ?? "unknown",
            "performanceDebugModeEnabled": AppPreferences.performanceDebugModeEnabled,
            "artifactPath": AppPaths.performanceDebugArtifactFile.path
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        let fileURL = AppPaths.performanceDebugArtifactFile
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let encoded = line.data(using: .utf8) {
            try handle.write(contentsOf: encoded)
        }
    }
}

extension AppModel {
    func configureQuickIntentHotKey() {
        services.globalHotKeyManager.register(AppPreferences.quickIntentHotkeyConfiguration) { [weak self] in
            guard let self else { return }
            self.presentQuickIntentFromSystemTrigger()
        }
    }

    func presentQuickIntentFromSystemTrigger() {
        let capture = services.quickIntentContextService.captureCurrentContext()
        presentQuickIntent(capture)
    }

    func presentQuickIntentFromURL(_ url: URL) {
        do {
            let capture = try services.quickIntentContextService.captureContext(from: url)
            presentQuickIntent(capture)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func dismissQuickIntentSession() {
        quickIntentSession = nil
    }

    func quickIntentRepositoryContext() -> (namespace: RepositoryNamespace?, repository: ManagedRepository?, worktree: WorktreeRecord?) {
        let repository = selectedRepository()
        let worktree = repository.flatMap { selectedWorktree(for: $0) }
        let namespace = selectedNamespaceID.flatMap(namespaceRecord(with:))
        return (namespace, repository, worktree)
    }

    private func presentQuickIntent(_ capture: QuickIntentCapture) {
        let normalizedText = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedBranch = WorktreeManager.normalizedWorktreeName(
            from: normalizedText
                .components(separatedBy: .newlines)
                .first ?? ""
        )
        quickIntentSession = QuickIntentSession(
            source: capture.source,
            sourceLabel: capture.sourceLabel,
            text: capture.text,
            branchName: generatedBranch,
            useCurrentWorktreeAsParent: false,
            accessibilityAvailable: capture.accessibilityAvailable,
            accessibilityHint: capture.accessibilityHint
        )
        pendingQuickIntentActivationID = UUID()
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppModel {
    func prepareNotificationsIfNeeded() {
        let notificationService = services.notificationService
        Task {
            _ = await notificationService.prepareAuthorization()
        }
    }

    func notifyRunCompletionIfNeeded(_ run: RunRecord, failureMessage: String? = nil) {
        guard run.status != .cancelled else { return }
        if run.status == .succeeded, run.actionKind == .gitOperation, run.title == "git push" {
            return
        }

        let context = runNotificationContext(for: run)
        let body: String
        let kind: AppNotificationKind

        switch run.status {
        case .succeeded:
            kind = .success
            body = context.map { "Completed successfully in \($0)." } ?? "Completed successfully."
        case .failed:
            kind = .failure
            if let failureMessage = failureMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                body = context.map { "Failed in \($0): \(failureMessage)" } ?? "Failed: \(failureMessage)"
            } else if let exitCode = run.exitCode {
                body = context.map { "Failed in \($0) with exit code \(exitCode)." } ?? "Failed with exit code \(exitCode)."
            } else {
                body = context.map { "Failed in \($0)." } ?? "Failed."
            }
        case .pending, .running, .cancelled:
            return
        }

        deliverNotification(
            AppNotificationRequest(
                identifier: "run-\(run.id.uuidString)-\(run.status.rawValue)",
                title: run.title,
                subtitle: run.actionKind.notificationSubtitle,
                body: body,
                userInfo: [
                    "runID": run.id.uuidString,
                    "status": run.status.rawValue,
                ],
                kind: kind
            )
        )
    }

    func notifyDevContainerOperationCompletion(
        _ operation: DevContainerOperation,
        worktree: WorktreeRecord,
        snapshot: DevContainerWorkspaceSnapshot
    ) {
        let runtimeText = snapshot.runtimeStatus.displayName.lowercased()
        let repositoryName = worktree.repository?.displayName ?? worktree.branchName
        deliverNotification(
            AppNotificationRequest(
                identifier: "devcontainer-\(worktree.id.uuidString)-\(operation.rawValue)-success",
                title: "Dev Container \(operation.title) finished",
                subtitle: repositoryName,
                body: "\(worktree.branchName) is now \(runtimeText).",
                userInfo: [
                    "worktreeID": worktree.id.uuidString,
                    "operation": operation.rawValue,
                ],
                kind: .success
            )
        )
    }

    func notifyDevContainerOperationFailure(
        _ operation: DevContainerOperation,
        worktree: WorktreeRecord,
        message: String
    ) {
        deliverNotification(
            AppNotificationRequest(
                identifier: "devcontainer-\(worktree.id.uuidString)-\(operation.rawValue)-failure",
                title: "Dev Container \(operation.title) failed",
                subtitle: worktree.repository?.displayName,
                body: "\(worktree.branchName): \(message)",
                userInfo: [
                    "worktreeID": worktree.id.uuidString,
                    "operation": operation.rawValue,
                ],
                kind: .failure
            )
        )
    }

    func notifyOperationSuccess(
        title: String,
        subtitle: String? = nil,
        body: String,
        userInfo: [String: String] = [:]
    ) {
        deliverNotification(
            AppNotificationRequest(
                title: title,
                subtitle: subtitle,
                body: body,
                userInfo: userInfo,
                kind: .success
            )
        )
    }

    func notifyOperationFailure(
        title: String,
        subtitle: String? = nil,
        body: String,
        userInfo: [String: String] = [:]
    ) {
        deliverNotification(
            AppNotificationRequest(
                title: title,
                subtitle: subtitle,
                body: body,
                userInfo: userInfo,
                kind: .failure
            )
        )
    }

    private func deliverNotification(_ request: AppNotificationRequest) {
        let notificationService = services.notificationService
        Task {
            _ = await notificationService.deliver(request)
        }
    }

    private func runNotificationContext(for run: RunRecord) -> String? {
        let parts = [
            run.repository?.displayName,
            run.worktree?.branchName,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }
}

private extension ActionKind {
    var notificationSubtitle: String {
        switch self {
        case .openIDE:
            "Open IDE"
        case .makeTarget:
            "Make Target"
        case .npmScript:
            "npm Script"
        case .installDependencies:
            "Dependency Install"
        case .aiAgent:
            "AI Agent"
        case .devContainer:
            "Devcontainer"
        case .gitOperation:
            "Git Operation"
        case .runConfiguration:
            "Run Configuration"
        }
    }
}
