import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class AppModel: @unchecked Sendable {
    var selectedRepositoryID: UUID?
    var selectedWorktreeIDsByRepository: [UUID: UUID] = [:]
    var cloneDraft = CloneRepositoryDraft()
    var worktreeDraft = WorktreeDraft()
    var pendingErrorMessage: String?
    var worktreeStatuses: [UUID: WorktreeStatus] = [:]
    var worktreePendingMergeOfferID: UUID?
    var activeRunIDs: Set<UUID> = []
    var refreshingRepositoryIDs: Set<UUID> = []
    var isCloneSheetPresented = false
    var isWorktreeSheetPresented = false
    var remoteManagementRepositoryID: UUID?
    var pendingRepositoryDeletionID: UUID?
    var publishDraft = PublishBranchDraft()
    var nodeRuntimeStatus = NodeRuntimeStatusSnapshot(
        runtimeRootPath: AppPaths.nodeRuntimeRoot.path,
        npmCachePath: AppPaths.npmCacheDirectory.path
    )
    var availableAgents: Set<AIAgentTool> = []
    var runningAgentWorktreeIDs: Set<UUID> = []
    var terminalTabs = TerminalTabBookkeeping()

    private let repositoryManager = RepositoryManager()
    private let worktreeManager = WorktreeManager()
    private let ideManager = IDEManager()
    private let sshKeyManager = SSHKeyManager()
    private let agentManager = AIAgentManager()
    private let nodeTooling = NodeToolingService()
    private let nodeRuntimeManager = NodeRuntimeManager()
    private let makeTooling = MakeToolingService()
    private let worktreeStatusService = WorktreeStatusService()
    private var runningProcesses: [UUID: RunningProcess] = [:]
    @ObservationIgnored
    private var terminalSessions: [UUID: AgentTerminalSession] = [:]
    @ObservationIgnored
    private var terminalTabAutoHideTasks: [UUID: Task<Void, Never>] = [:]
    private var storedModelContext: ModelContext?
    private var autoRefreshTask: Task<Void, Never>?
    private var nodeRuntimeRefreshTask: Task<Void, Never>?

    func configure(modelContext: ModelContext) {
        if storedModelContext == nil {
            storedModelContext = modelContext
            migrateLegacyRepositoriesIfNeeded(in: modelContext)
            startAutoRefreshLoopIfNeeded()
            startNodeRuntimeRefreshLoopIfNeeded()
            Task {
                nodeRuntimeStatus = await nodeRuntimeManager.statusSnapshot()
                await nodeRuntimeManager.refreshDefaultRuntimeIfNeeded(force: false)
                nodeRuntimeStatus = await nodeRuntimeManager.statusSnapshot()
                await refreshAllRepositories(force: false)
            }
        }

    }

    func selectInitialRepository(from repositories: [ManagedRepository]) {
        if selectedRepositoryID == nil {
            selectedRepositoryID = repositories.first?.id
        }
    }

    func repository(for repositories: [ManagedRepository]) -> ManagedRepository? {
        repositories.first(where: { $0.id == selectedRepositoryID }) ?? repositories.first
    }

    func selectedRepository() -> ManagedRepository? {
        guard let repositoryID = selectedRepositoryID else { return nil }
        return repositoryRecord(with: repositoryID)
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
        guard let modelContext = storedModelContext else {
            return repository.worktrees.sorted(by: { $0.createdAt > $1.createdAt })
        }

        let repositoryID = repository.id
        let descriptor = FetchDescriptor<WorktreeRecord>(
            predicate: #Predicate { $0.repository?.id == repositoryID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
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
        publishDraft = PublishBranchDraft(repositoryID: repository.id, worktreeID: worktree.id, remoteName: repository.primaryRemote?.name ?? "")
    }

    func dismissPublishSheet() {
        publishDraft = PublishBranchDraft()
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

            let info = try await repositoryManager.cloneBareRepository(
                remoteURL: remoteURL,
                preferredName: cloneDraft.displayName
            )

            let repository = ManagedRepository(
                displayName: info.displayName,
                remoteURL: rawRemote,
                bareRepositoryPath: info.bareRepositoryPath.path,
                defaultBranch: info.defaultBranch
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

        let status = repositoryManager.refreshStatus(for: URL(fileURLWithPath: repository.bareRepositoryPath))
        guard status == .ready else {
            repository.status = status
            repository.updatedAt = .now
            repository.lastErrorMessage = "Repository missing or invalid."
            save(modelContext)
            return
        }

        let contexts = repository.remotes.map(remoteExecutionContext(for:))
        let result = await repositoryManager.refreshRepository(
            bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
            remotes: contexts
        )

        repository.status = result.status
        repository.defaultBranch = result.defaultBranch
        repository.lastFetchedAt = result.fetchedAt ?? repository.lastFetchedAt
        repository.lastErrorMessage = result.errorMessage
        repository.updatedAt = .now
        save(modelContext)
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

    func createWorktree(for repository: ManagedRepository, in modelContext: ModelContext) async {
        do {
            let info = try await worktreeManager.createWorktree(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                repositoryName: repository.displayName,
                branchName: worktreeDraft.branchName,
                sourceBranch: worktreeDraft.sourceBranch.isEmpty ? repository.defaultBranch : worktreeDraft.sourceBranch
            )

            let worktree = WorktreeRecord(
                branchName: info.branchName,
                issueContext: worktreeDraft.issueContext.nilIfBlank,
                path: info.path.path,
                repository: repository
            )

            repository.worktrees.append(worktree)
            repository.updatedAt = .now
            modelContext.insert(worktree)
            try modelContext.save()

            selectedWorktreeIDsByRepository[repository.id] = worktree.id
            isWorktreeSheetPresented = false
            await refreshWorktreeStatuses(for: repository)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func removeWorktree(_ worktree: WorktreeRecord, in modelContext: ModelContext) async {
        do {
            guard let repository = worktree.repository else {
                throw DevVaultError.unsupportedRepositoryPath
            }

            let worktreeID = worktree.id
            let worktreePath = worktree.path
            let repositoryID = repository.id
            let bareRepositoryPath = repository.bareRepositoryPath
            let remainingWorktreeID = repository.worktrees
                .filter { $0.id != worktreeID }
                .sorted(by: { $0.createdAt > $1.createdAt })
                .first?
                .id
            let runIDsForWorktree = repository.runs
                .filter { $0.worktree?.id == worktreeID }
                .map(\.id)

            try await worktreeManager.removeWorktree(
                bareRepositoryPath: URL(fileURLWithPath: bareRepositoryPath),
                worktreePath: URL(fileURLWithPath: worktreePath)
            )

            modelContext.delete(worktree)
            repository.updatedAt = .now
            try modelContext.save()
            worktreeStatuses.removeValue(forKey: worktreeID)
            for runID in runIDsForWorktree {
                cancelAutoHide(for: runID)
            }
            terminalTabs.removeWorktree(worktreeID)
            if selectedWorktreeIDsByRepository[repositoryID] == worktreeID {
                selectedWorktreeIDsByRepository[repositoryID] = remainingWorktreeID
            }
            if worktreePendingMergeOfferID == worktreeID {
                worktreePendingMergeOfferID = nil
            }
            await refreshWorktreeStatuses(for: repository)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func refreshWorktreeStatuses(for repository: ManagedRepository) async {
        let defaultBranch = repository.defaultBranch
        var statuses: [UUID: WorktreeStatus] = [:]

        await withTaskGroup(of: (UUID, WorktreeStatus).self) { group in
            for worktree in repository.worktrees {
                let worktreeID = worktree.id
                let worktreePath = worktree.path
                group.addTask { [worktreeStatusService] in
                    let status = await worktreeStatusService.fetchStatus(
                        worktreePath: URL(fileURLWithPath: worktreePath),
                        defaultBranch: defaultBranch
                    )
                    return (worktreeID, status)
                }
            }

            for await (worktreeID, status) in group {
                statuses[worktreeID] = status
            }
        }

        for (worktreeID, status) in statuses {
            worktreeStatuses[worktreeID] = status
        }
    }

    func syncWorktreeFromMain(
        _ worktree: WorktreeRecord,
        repository: ManagedRepository,
        strategy: SyncStrategy,
        modelContext: ModelContext
    ) async {
        do {
            switch strategy {
            case .rebase:
                do {
                    try await worktreeStatusService.rebase(
                        worktreePath: URL(fileURLWithPath: worktree.path),
                        onto: repository.defaultBranch
                    )
                    worktreePendingMergeOfferID = nil
                } catch {
                    worktreePendingMergeOfferID = worktree.id
                    return
                }
            case .merge:
                try await worktreeStatusService.merge(
                    worktreePath: URL(fileURLWithPath: worktree.path),
                    from: repository.defaultBranch
                )
                worktreePendingMergeOfferID = nil
            }

            await refreshWorktreeStatuses(for: repository)
            _ = modelContext
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func deleteRepository(_ repository: ManagedRepository, in modelContext: ModelContext) async {
        do {
            for run in repository.runs {
                cancelAutoHide(for: run.id)
            }
            try await repositoryManager.deleteRepository(
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
            try await ideManager.revealInFinder(path: URL(fileURLWithPath: repository.bareRepositoryPath))
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func availableMakeTargets(for worktree: WorktreeRecord) -> [String] {
        makeTooling.discoverTargets(in: URL(fileURLWithPath: worktree.path))
    }

    func availableNPMScripts(for worktree: WorktreeRecord) -> [String] {
        nodeTooling.discoverScripts(in: URL(fileURLWithPath: worktree.path))
    }

    func openIDE(_ ide: SupportedIDE, for worktree: WorktreeRecord, in modelContext: ModelContext) async {
        do {
            try await ideManager.open(ide, path: URL(fileURLWithPath: worktree.path))
            worktree.lastOpenedAt = .now
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func checkAgentAvailability() async {
        availableAgents = await agentManager.checkAvailability()
    }

    func launchAgent(_ tool: AIAgentTool, for worktree: WorktreeRecord, in modelContext: ModelContext) {
        guard tool != .none else { return }

        do {
            worktree.assignedAgent = tool
            try modelContext.save()

            guard let repository = worktree.repository else {
                throw DevVaultError.worktreeUnavailable
            }

            let shell = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let loginShell = (shell?.isEmpty == false ? shell! : "/bin/zsh")
            let shellCommand = tool.launchCommand(in: worktree.path)
            let descriptor = CommandExecutionDescriptor(
                title: tool.displayName,
                actionKind: .aiAgent,
                executable: loginShell,
                arguments: ["-ilc", shellCommand],
                displayCommandLine: tool.launchCommand(in: worktree.path),
                currentDirectoryURL: URL(fileURLWithPath: worktree.path),
                repositoryID: repository.id,
                worktreeID: worktree.id,
                runtimeRequirement: nil
            )
            startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
            refreshRunningAgentWorktrees()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func assignAgent(_ tool: AIAgentTool, to worktree: WorktreeRecord, in modelContext: ModelContext) {
        worktree.assignedAgent = tool
        do {
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func isAgentRunning(for worktree: WorktreeRecord) -> Bool {
        runningAgentWorktreeIDs.contains(worktree.id)
    }

    func isAgentRunning(forRepository repository: ManagedRepository) -> Bool {
        repository.worktrees.contains { runningAgentWorktreeIDs.contains($0.id) }
    }

    func runMakeTarget(
        _ target: String,
        in worktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) {
        let descriptor = CommandExecutionDescriptor(
            title: "make \(target)",
            actionKind: .makeTarget,
            executable: "make",
            arguments: [target],
            displayCommandLine: nil,
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            runtimeRequirement: nil
        )
        startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
    }

    func runNPMScript(
        _ script: String,
        in worktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) {
        let descriptor = CommandExecutionDescriptor(
            title: "npm run \(script)",
            actionKind: .npmScript,
            executable: "npm",
            arguments: ["run", script],
            displayCommandLine: nil,
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            runtimeRequirement: nodeTooling.runtimeRequirement(for: URL(fileURLWithPath: worktree.path))
        )
        startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
    }

    func installDependencies(
        mode: DependencyInstallMode,
        in worktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) {
        let descriptor = nodeTooling.installDescriptor(for: worktree, mode: mode, repositoryID: repository.id)
        startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext)
    }

    func cancelRun(_ run: RunRecord, in modelContext: ModelContext) {
        if let session = terminalSessions[run.id] {
            session.terminate()
            return
        }
        runningProcesses[run.id]?.cancel()
        run.status = .cancelled
        run.endedAt = .now
        activeRunIDs.remove(run.id)
        save(modelContext)
    }

    func terminalSession(for run: RunRecord) -> AgentTerminalSession? {
        terminalSessions[run.id]
    }

    func runs(forWorktreeID worktreeID: UUID, in repository: ManagedRepository) -> [RunRecord] {
        repository.runs
            .filter { $0.worktreeID == worktreeID }
            .sorted(by: { $0.startedAt > $1.startedAt })
    }

    func saveRemote(
        name: String,
        url: String,
        fetchEnabled: Bool,
        sshKey: StoredSSHKey?,
        for repository: ManagedRepository,
        editing remote: RepositoryRemote?,
        in modelContext: ModelContext
    ) async {
        do {
            let canonicalURL = try canonicalRemoteURL(from: url)
            try ensureRemoteURLIsUnique(canonicalURL, excluding: remote?.id, modelContext: modelContext)

            if let remote {
                try await repositoryManager.updateRemote(
                    previousName: remote.name,
                    newName: name,
                    url: url,
                    bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath)
                )
                remote.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                remote.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
                remote.canonicalURL = canonicalURL
                remote.fetchEnabled = fetchEnabled
                remote.sshKey = sshKey
                remote.updatedAt = .now
            } else {
                try await repositoryManager.addRemote(
                    name: name,
                    url: url,
                    bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath)
                )
                let newRemote = RepositoryRemote(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                    canonicalURL: canonicalURL,
                    fetchEnabled: fetchEnabled,
                    repository: repository,
                    sshKey: sshKey
                )
                repository.remotes.append(newRemote)
                modelContext.insert(newRemote)
            }

            repository.updatedAt = .now
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func removeRemote(_ remote: RepositoryRemote, from repository: ManagedRepository, in modelContext: ModelContext) async {
        do {
            try await repositoryManager.removeRemote(
                name: remote.name,
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath)
            )
            modelContext.delete(remote)
            repository.updatedAt = .now
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func importSSHKey(from sourceURL: URL, in modelContext: ModelContext) async {
        do {
            let material = try await sshKeyManager.importKey(from: sourceURL, displayName: nil)
            try storeSSHKey(material, in: modelContext)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func generateSSHKey(displayName: String, comment: String, in modelContext: ModelContext) async {
        do {
            let material = try await sshKeyManager.generateKey(displayName: displayName, comment: comment)
            try storeSSHKey(material, in: modelContext)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func rebuildManagedNodeRuntime() {
        Task {
            await nodeRuntimeManager.rebuildManagedRuntime()
            nodeRuntimeStatus = await nodeRuntimeManager.statusSnapshot()
        }
    }

    func removeSSHKey(_ key: StoredSSHKey, in modelContext: ModelContext) {
        for remote in key.remotes {
            remote.sshKey = nil
            remote.updatedAt = .now
        }
        KeychainSSHKeyStore.delete(reference: key.privateKeyRef)
        modelContext.delete(key)
        save(modelContext)
    }

    func publishSelectedBranch(in modelContext: ModelContext) async {
        do {
            guard
                let repositoryID = publishDraft.repositoryID,
                let worktreeID = publishDraft.worktreeID,
                let repository = repositoryRecord(with: repositoryID),
                let worktree = worktreeRecord(with: worktreeID)
            else {
                throw DevVaultError.worktreeUnavailable
            }

            guard let remote = repository.remotes.first(where: { $0.name == publishDraft.remoteName }) else {
                throw DevVaultError.remoteNameRequired
            }

            let branch = try await repositoryManager.publishCurrentBranch(
                worktreePath: URL(fileURLWithPath: worktree.path),
                remote: remoteExecutionContext(for: remote)
            )
            pendingErrorMessage = "Published \(branch) to \(remote.name)."
            dismissPublishSheet()
            _ = modelContext
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    private func startRun(
        _ descriptor: CommandExecutionDescriptor,
        repository: ManagedRepository,
        worktree: WorktreeRecord?,
        modelContext: ModelContext
    ) {
        let commandLine = descriptor.displayCommandLine ?? ([descriptor.executable] + descriptor.arguments).joined(separator: " ")
        let run = RunRecord(
            actionKind: descriptor.actionKind,
            title: descriptor.title,
            commandLine: commandLine,
            status: .running,
            worktreeID: worktree?.id,
            repository: repository,
            worktree: worktree
        )
        run.outputText = "$ \(commandLine)\n"
        repository.runs.append(run)
        modelContext.insert(run)

        do {
            try modelContext.save()
            let runID = run.id
            activeRunIDs.insert(runID)
            if let worktree {
                terminalTabs.activate(runID: runID, worktreeID: worktree.id)
                selectedWorktreeIDsByRepository[repository.id] = worktree.id
            }
            Task { [weak self] in
                await self?.launchRun(runID: runID, descriptor: descriptor)
            }
        } catch {
            modelContext.delete(run)
            pendingErrorMessage = error.localizedDescription
        }
    }

    private func defaultTemplates(for repository: ManagedRepository) -> [ActionTemplateRecord] {
        [
            ActionTemplateRecord(kind: .openIDE, title: "Open in Cursor", payload: SupportedIDE.cursor.rawValue, repository: repository),
            ActionTemplateRecord(kind: .openIDE, title: "Open in VS Code", payload: SupportedIDE.vscode.rawValue, repository: repository),
            ActionTemplateRecord(kind: .installDependencies, title: "Install dependencies", payload: DependencyInstallMode.install.rawValue, repository: repository),
        ]
    }

    private func handleRunOutput(runID: UUID, chunk: String) {
        guard let run = runRecord(with: runID) else { return }
        run.outputText += chunk
        guard
            run.actionKind == .aiAgent,
            let repositoryID = run.repository?.id,
            let worktreeID = run.worktree?.id,
            selectedRepositoryID == repositoryID,
            selectedWorktreeIDsByRepository[repositoryID] == worktreeID
        else {
            return
        }

        terminalTabs.activate(runID: runID, worktreeID: worktreeID)
    }

    private func handleRunTermination(runID: UUID, exitCode: Int32, wasCancelled: Bool) {
        guard let run = runRecord(with: runID), let modelContext = storedModelContext else { return }
        run.endedAt = .now
        run.exitCode = Int(exitCode)
        run.status = wasCancelled ? .cancelled : (exitCode == 0 ? .succeeded : .failed)
        activeRunIDs.remove(runID)
        runningProcesses.removeValue(forKey: runID)
        terminalTabs.markCompleted(runID: runID)
        scheduleAutoHideIfNeeded(for: runID)
        refreshRunningAgentWorktrees()
        save(modelContext)
    }

    private func handleRunFailure(runID: UUID, message: String) {
        guard let run = runRecord(with: runID), let modelContext = storedModelContext else { return }
        run.outputText += "\n\(message)\n"
        run.endedAt = .now
        run.status = .failed
        activeRunIDs.remove(runID)
        runningProcesses.removeValue(forKey: runID)
        terminalTabs.markCompleted(runID: runID)
        scheduleAutoHideIfNeeded(for: runID)
        refreshRunningAgentWorktrees()
        save(modelContext)
    }

    private func runRecord(with id: UUID) -> RunRecord? {
        guard let modelContext = storedModelContext else { return nil }
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    private func migrateLegacyRepositoriesIfNeeded(in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<ManagedRepository>()
        guard let repositories = try? modelContext.fetch(descriptor) else { return }
        var didChange = false

        for repository in repositories where repository.remotes.isEmpty {
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
    }

    private func repository(withCanonicalRemoteURL canonicalURL: String, in modelContext: ModelContext) -> ManagedRepository? {
        let descriptor = FetchDescriptor<RepositoryRemote>(predicate: #Predicate { $0.canonicalURL == canonicalURL })
        return try? modelContext.fetch(descriptor).first?.repository
    }

    private func canonicalRemoteURL(from url: String) throws -> String {
        guard let canonicalURL = RepositoryManager.canonicalRemoteURL(from: url) else {
            throw DevVaultError.invalidRemoteURL
        }
        return canonicalURL
    }

    private func ensureRemoteURLIsUnique(_ canonicalURL: String, excluding remoteID: UUID?, modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<RepositoryRemote>(predicate: #Predicate { $0.canonicalURL == canonicalURL })
        let remotes = try modelContext.fetch(descriptor)
        if remotes.contains(where: { $0.id != remoteID }) {
            throw DevVaultError.duplicateRepository(canonicalURL)
        }
    }

    private func save(_ modelContext: ModelContext) {
        do {
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    private func storeSSHKey(_ material: SSHKeyMaterial, in modelContext: ModelContext) throws {
        let reference = UUID().uuidString
        try KeychainSSHKeyStore.store(privateKeyData: material.privateKeyData, reference: reference)
        let key = StoredSSHKey(
            displayName: material.displayName,
            kind: material.kind,
            publicKey: material.publicKey,
            privateKeyRef: reference
        )
        modelContext.insert(key)
        save(modelContext)
    }

    private func remoteExecutionContext(for remote: RepositoryRemote) -> RemoteExecutionContext {
        RemoteExecutionContext(
            name: remote.name,
            url: remote.url,
            fetchEnabled: remote.fetchEnabled,
            privateKeyRef: remote.sshKey?.privateKeyRef
        )
    }

    private func scheduleAutoHideIfNeeded(for runID: UUID) {
        cancelAutoHide(for: runID)

        let mode = AppPreferences.terminalTabRetentionMode
        switch mode {
        case .manualClose:
            return
        case .runningOnly:
            terminalTabs.hide(runID: runID)
        case .shortRetain:
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.terminalTabs.hide(runID: runID)
                    self?.terminalTabAutoHideTasks.removeValue(forKey: runID)
                }
            }
            terminalTabAutoHideTasks[runID] = task
        }
    }

    private func cancelAutoHide(for runID: UUID) {
        terminalTabAutoHideTasks[runID]?.cancel()
        terminalTabAutoHideTasks.removeValue(forKey: runID)
    }

    private func startAutoRefreshLoopIfNeeded() {
        guard autoRefreshTask == nil else { return }

        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = AppPreferences.autoRefreshInterval
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled {
                    return
                }
                await self.refreshAllRepositories(force: false)
            }
        }
    }

    private func startNodeRuntimeRefreshLoopIfNeeded() {
        guard nodeRuntimeRefreshTask == nil else { return }

        nodeRuntimeRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = AppPreferences.nodeAutoUpdateInterval
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled {
                    return
                }
                await self.nodeRuntimeManager.refreshDefaultRuntimeIfNeeded(force: false)
                self.nodeRuntimeStatus = await self.nodeRuntimeManager.statusSnapshot()
            }
        }
    }

    private func launchRun(runID: UUID, descriptor: CommandExecutionDescriptor) async {
        do {
            if descriptor.actionKind == .aiAgent {
                let environment = ProcessInfo.processInfo.environment.merging(
                    [
                        "PATH": await ShellEnvironment.loginShellPath(),
                        "TERM": "xterm-256color",
                        "COLORTERM": "truecolor",
                        "TERM_PROGRAM": "DevVault",
                    ]
                ) { _, new in new }
                let session = AgentTerminalSession(
                    runID: runID,
                    onData: { [weak self] chunk in
                        self?.handleRunOutput(runID: runID, chunk: chunk)
                    },
                    onTermination: { [weak self] exitCode, wasCancelled in
                        self?.handleRunTermination(runID: runID, exitCode: exitCode, wasCancelled: wasCancelled)
                    }
                )
                terminalSessions[runID] = session
                session.start(
                    executable: descriptor.executable,
                    arguments: descriptor.arguments,
                    environment: environment,
                    currentDirectory: descriptor.currentDirectoryURL?.path
                )
                return
            }

            if descriptor.runtimeRequirement != nil {
                handleRunOutput(runID: runID, chunk: "[devvault] Preparing managed Node runtime…\n")
            }

            let prepared = try await nodeRuntimeManager.prepareExecution(for: descriptor)
            nodeRuntimeStatus = await nodeRuntimeManager.statusSnapshot()

            let handle = try CommandRunner.start(
                executable: prepared.executable,
                arguments: prepared.arguments,
                currentDirectoryURL: descriptor.currentDirectoryURL,
                environment: prepared.environment,
                onOutput: { [weak self] chunk in
                    Task { @MainActor in
                        guard let self else { return }
                        self.handleRunOutput(runID: runID, chunk: chunk)
                    }
                },
                onTermination: { [weak self] exitCode, wasCancelled in
                    Task { @MainActor in
                        guard let self else { return }
                        self.handleRunTermination(runID: runID, exitCode: exitCode, wasCancelled: wasCancelled)
                    }
                }
            )

            runningProcesses[runID] = handle
        } catch {
            nodeRuntimeStatus = await nodeRuntimeManager.statusSnapshot()
            handleRunFailure(runID: runID, message: error.localizedDescription)
        }
    }

    private func refreshRunningAgentWorktrees() {
        runningAgentWorktreeIDs = Set(
            activeRunIDs.compactMap { runID in
                guard let run = runRecord(with: runID), run.actionKind == .aiAgent else {
                    return nil
                }
                return run.worktree?.id
            }
        )
    }
}

struct CloneRepositoryDraft {
    var remoteURLString = ""
    var displayName = ""
}

struct WorktreeDraft {
    var branchName = ""
    var issueContext = ""
    var sourceBranch = ""

    init(sourceBranch: String = "") {
        self.sourceBranch = sourceBranch
    }
}

struct PublishBranchDraft {
    var repositoryID: UUID?
    var worktreeID: UUID?
    var remoteName = ""
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
