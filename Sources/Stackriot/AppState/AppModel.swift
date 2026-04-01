import AppKit
import Observation
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
    var selectedRepositoryID: UUID?
    var selectedWorktreeIDsByRepository: [UUID: UUID] = [:]
    var cloneDraft = CloneRepositoryDraft()
    var worktreeDraft = WorktreeDraft()
    var pullRequestCheckoutDraft = PullRequestCheckoutDraft()
    var namespaceEditorDraft: NamespaceEditorDraft?
    var projectEditorDraft: ProjectEditorDraft?
    var pendingErrorMessage: String?
    var worktreeStatuses: [UUID: WorktreeStatus] = [:]
    var pullRequestUpstreamStatuses: [UUID: PullRequestUpstreamStatus] = [:]
    var worktreePendingMergeOfferID: UUID?
    var pendingIntegrationConflict: IntegrationConflictDraft?
    var syncLogs: [UUID: String] = [:]
    var activeRunIDs: Set<UUID> = []
    var refreshingRepositoryIDs: Set<UUID> = []
    var isCloneSheetPresented = false
    var isWorktreeSheetPresented = false
    var isPullRequestCheckoutSheetPresented = false
    var isDiffInspectorPresented = false
    var remoteManagementRepositoryID: UUID?
    var pendingRepositoryDeletionID: UUID?
    var pendingNamespaceDeletionID: UUID?
    var pendingProjectDeletionID: UUID?
    var pendingTerminalCloseConfirmation: TerminalCloseConfirmationDraft?
    var publishDraft = PublishBranchDraft()
    var integrationDraft = IntegrationDraft()
    var nodeRuntimeStatus = NodeRuntimeStatusSnapshot(
        runtimeRootPath: AppPaths.nodeRuntimeRoot.path,
        npmCachePath: AppPaths.npmCacheDirectory.path
    )
    var availableAgents: Set<AIAgentTool> = []
    var runningAgentWorktreeIDs: Set<UUID> = []
    var terminalTabs = TerminalTabBookkeeping()
    var summarizingRunIDs: Set<UUID> = []
    var dismissedAISummaryRunIDs: Set<UUID> = []
    var agentPlanDraftsByWorktreeID: [UUID: AgentPlanDraft] = [:]
    var pendingRunFixesByAgentRunID: [UUID: RunFixRequest] = [:]
    var activeAgentPlanDraftWorktreeID: UUID?
    var pendingCopilotExecutionDraft: PendingAgentExecutionDraft?
    var quickIntentSession: QuickIntentSession?
    var pendingQuickIntentActivationID: UUID?
    var intentContentVersionsByWorktreeID: [UUID: Int] = [:]
    var implementationPlanContentVersionsByWorktreeID: [UUID: Int] = [:]
    var devContainerStatesByWorktreeID: [UUID: DevContainerWorkspaceState] = [:]
    var mcpServerStatus = MCPServerStatus.idle()
    var mcpLogEntries: [MCPLogEntry] = []
    /// When set, `RootView` opens `WindowGroup(id: "cursor-agent-markdown")` with this payload.
    var pendingAgentMarkdownWindowPayload: AgentMarkdownWindowPayload?

    let services: AppServices
    var runningProcesses: [UUID: RunningProcess] = [:]
    @ObservationIgnored
    var terminalSessions: [UUID: AgentTerminalSession] = [:]
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
    @ObservationIgnored
    var deliveredCursorAgentMarkdownSnapshotRunIDs: Set<UUID> = []
    var storedModelContext: ModelContext?
    var autoRefreshTask: Task<Void, Never>?
    var nodeRuntimeRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    var worktreeStatusPollingTask: Task<Void, Never>?
    @ObservationIgnored
    var lastWorktreeStatusPollAt: Date?

    init(
        services: AppServices = .production,
        userDefaults: UserDefaults = .standard
    ) {
        self.services = services
        self.userDefaults = userDefaults
        selectedNamespaceID = userDefaults.string(forKey: AppPreferences.selectedNamespaceIDKey)
            .flatMap(UUID.init(uuidString:))
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
            Task {
                nodeRuntimeStatus = await services.nodeRuntimeManager.statusSnapshot()
                await services.nodeRuntimeManager.refreshDefaultRuntimeIfNeeded(force: false)
                nodeRuntimeStatus = await services.nodeRuntimeManager.statusSnapshot()
                await refreshAllRepositories(force: false)
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
        }
    }

    func selectWorktree(_ worktree: WorktreeRecord, in repository: ManagedRepository) {
        selectedWorktreeIDsByRepository[repository.id] = worktree.id
        terminalTabs.selectPlanTab(for: worktree.id)
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
        terminalTabs.deselectPlanTab(for: worktreeID)
        terminalTabs.activate(runID: run.id, worktreeID: worktreeID)
    }

    func navigateToRun(_ run: RunRecord) {
        guard let repository = run.repository else { return }

        if let namespaceID = repository.namespace?.id {
            selectedNamespaceID = namespaceID
        }
        selectedRepositoryID = repository.id

        guard run.worktree != nil else { return }
        selectTab(run)
    }

    func closeTab(_ run: RunRecord) {
        guard !activeRunIDs.contains(run.id) else { return }
        cancelAutoHide(for: run.id)
        terminalTabs.hide(runID: run.id)
        terminalSessions[run.id]?.terminate()
        terminalSessions[run.id] = nil
    }

    func clearPendingTerminalCloseConfirmation() {
        pendingTerminalCloseConfirmation = nil
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
        case .gitOperation:
            "Git Operation"
        case .runConfiguration:
            "Run Configuration"
        }
    }
}
