import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class AppModel: @unchecked Sendable {
    var selectedRepositoryID: UUID?
    var selectedRunID: UUID?
    var cloneDraft = CloneRepositoryDraft()
    var worktreeDraft = WorktreeDraft()
    var isCloneSheetPresented = false
    var isWorktreeSheetPresented = false
    var pendingErrorMessage: String?
    var activeRunIDs: Set<UUID> = []

    private let repositoryManager = RepositoryManager()
    private let worktreeManager = WorktreeManager()
    private let ideManager = IDEManager()
    private let nodeTooling = NodeToolingService()
    private let makeTooling = MakeToolingService()
    private var runningProcesses: [UUID: RunningProcess] = [:]
    private var storedModelContext: ModelContext?

    func configure(modelContext: ModelContext) {
        if storedModelContext == nil {
            storedModelContext = modelContext
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

    func run(for runs: [RunRecord]) -> RunRecord? {
        runs.first(where: { $0.id == selectedRunID }) ?? runs.first
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

    func cloneRepository(in modelContext: ModelContext) async {
        do {
            guard let remoteURL = URL(string: cloneDraft.remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DevVaultError.invalidRemoteURL
            }

            let info = try await repositoryManager.cloneBareRepository(
                remoteURL: remoteURL,
                preferredName: cloneDraft.displayName
            )

            let repository = ManagedRepository(
                displayName: info.displayName,
                remoteURL: info.remoteURL.absoluteString,
                bareRepositoryPath: info.bareRepositoryPath.path,
                defaultBranch: info.defaultBranch
            )

            repository.actionTemplates = defaultTemplates(for: repository)
            modelContext.insert(repository)
            try modelContext.save()

            selectedRepositoryID = repository.id
            isCloneSheetPresented = false
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func refresh(_ repository: ManagedRepository, in modelContext: ModelContext) {
        let status = repositoryManager.refreshStatus(for: URL(fileURLWithPath: repository.bareRepositoryPath))
        repository.status = status
        repository.updatedAt = .now

        do {
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func refreshSelectedRepository() {
        guard
            let repository = selectedRepository(),
            let modelContext = storedModelContext
        else {
            pendingErrorMessage = "No repository is currently selected."
            return
        }

        refresh(repository, in: modelContext)
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

            isWorktreeSheetPresented = false
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func removeWorktree(_ worktree: WorktreeRecord, in modelContext: ModelContext) async {
        do {
            guard let repository = worktree.repository else {
                throw DevVaultError.unsupportedRepositoryPath
            }

            try await worktreeManager.removeWorktree(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                worktreePath: URL(fileURLWithPath: worktree.path)
            )

            modelContext.delete(worktree)
            repository.updatedAt = .now
            try modelContext.save()
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
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id
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
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id
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
        runningProcesses[run.id]?.cancel()
        run.status = .cancelled
        run.endedAt = .now
        activeRunIDs.remove(run.id)
        do {
            try modelContext.save()
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
        let commandLine = ([descriptor.executable] + descriptor.arguments).joined(separator: " ")
        let run = RunRecord(
            actionKind: descriptor.actionKind,
            title: descriptor.title,
            commandLine: commandLine,
            status: .running,
            repository: repository,
            worktree: worktree
        )
        run.outputText = "$ \(commandLine)\n"
        repository.runs.append(run)
        modelContext.insert(run)

        do {
            try modelContext.save()
            let runID = run.id

            let handle = try CommandRunner.start(
                executable: descriptor.executable,
                arguments: descriptor.arguments,
                currentDirectoryURL: descriptor.currentDirectoryURL,
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
            activeRunIDs.insert(runID)
            selectedRunID = runID
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
        selectedRunID = runID
    }

    private func handleRunTermination(runID: UUID, exitCode: Int32, wasCancelled: Bool) {
        guard let run = runRecord(with: runID), let modelContext = storedModelContext else { return }
        run.endedAt = .now
        run.exitCode = Int(exitCode)
        run.status = wasCancelled ? .cancelled : (exitCode == 0 ? .succeeded : .failed)
        activeRunIDs.remove(runID)
        runningProcesses.removeValue(forKey: runID)

        do {
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    private func runRecord(with id: UUID) -> RunRecord? {
        guard let modelContext = storedModelContext else { return nil }
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    private func repositoryRecord(with id: UUID) -> ManagedRepository? {
        guard let modelContext = storedModelContext else { return nil }
        let descriptor = FetchDescriptor<ManagedRepository>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
