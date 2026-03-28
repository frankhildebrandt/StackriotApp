import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ManagedRepository.displayName) private var repositories: [ManagedRepository]
    @Query(sort: \RunRecord.startedAt, order: .reverse) private var runs: [RunRecord]

    var body: some View {
        @Bindable var appModel = appModel

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
            if let repository = appModel.repository(for: repositories) {
                RepositoryDetailView(repository: repository)
            } else {
                ContentUnavailableView("No Repositories", systemImage: "shippingbox", description: Text("Clone a bare repository to start creating worktrees and actions."))
            }
        } detail: {
            RunConsoleView(run: appModel.run(for: runs), activeRunIDs: appModel.activeRunIDs)
                .navigationSplitViewColumnWidth(min: 360, ideal: 420)
        }
        .task {
            appModel.configure(modelContext: modelContext)
            appModel.selectInitialRepository(from: repositories)
            await appModel.checkAgentAvailability()
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

private struct SidebarView: View {
    let repositories: [ManagedRepository]
    @Binding var selectedRepositoryID: UUID?
    let refreshingRepositoryIDs: Set<UUID>
    let isAgentRunningForRepository: (ManagedRepository) -> Bool
    let onAddRepository: () -> Void
    let onRefreshRepository: (ManagedRepository) -> Void
    let onRevealRepository: (ManagedRepository) -> Void
    let onManageRemotes: (ManagedRepository) -> Void
    let onDeleteRepository: (ManagedRepository) -> Void

    var body: some View {
        List(selection: $selectedRepositoryID) {
            Section("Repositories") {
                ForEach(repositories) { repository in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(repository.displayName)
                                .font(.headline)
                            if isAgentRunningForRepository(repository) {
                                AgentActivityDot()
                            }
                        }
                        Text(repository.primaryRemote?.url ?? repository.remoteURL ?? "No remote configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(repository.bareRepositoryPath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Label(repository.status.rawValue.capitalized, systemImage: statusSymbol(for: repository.status))
                                .font(.caption)
                                .foregroundStyle(repository.status == .ready ? .green : .orange)
                            if refreshingRepositoryIDs.contains(repository.id) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .tag(repository.id)
                    .contextMenu {
                        Button("Show in Finder") {
                            onRevealRepository(repository)
                        }
                        Button("Refresh") {
                            onRefreshRepository(repository)
                        }
                        Button("Manage Remotes") {
                            onManageRemotes(repository)
                        }
                        Button("Delete Repository", role: .destructive) {
                            onDeleteRepository(repository)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    onAddRepository()
                } label: {
                    Label("Clone Bare Repo", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle("DevVault")
    }

    private func statusSymbol(for status: RepositoryHealth) -> String {
        switch status {
        case .ready:
            "checkmark.circle.fill"
        case .missing:
            "exclamationmark.triangle.fill"
        case .broken:
            "xmark.octagon.fill"
        }
    }
}

private struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let repository: ManagedRepository
    @State private var selectedWorktreeID: UUID?
    @State private var worktreePendingRemoval: WorktreeRecord?
    @State private var pendingMakeTarget: String?
    @State private var pendingScript: String?
    @State private var pendingDependencyMode: DependencyInstallMode?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                repositoryHeader
                worktreeSection

                if let worktree = selectedWorktree {
                    actionSection(for: worktree)
                    runHistorySection
                } else {
                    emptyWorktreeState
                }
            }
            .padding(24)
        }
        .navigationTitle(repository.displayName)
        .task(id: repository.id) {
            selectedWorktreeID = repository.worktrees.sorted(by: { $0.createdAt > $1.createdAt }).first?.id
        }
        .confirmationDialog("Remove worktree?", item: $worktreePendingRemoval) { worktree in
            Button("Remove", role: .destructive) {
                Task {
                    await appModel.removeWorktree(worktree, in: modelContext)
                }
            }
        } message: { worktree in
            Text(worktree.path)
        }
        .confirmationDialog("Run make target?", isPresented: Binding(
            get: { pendingMakeTarget != nil },
            set: { if !$0 { pendingMakeTarget = nil } }
        )) {
            Button("Run") {
                if let worktree = selectedWorktree, let target = pendingMakeTarget {
                    appModel.runMakeTarget(target, in: worktree, repository: repository, modelContext: modelContext)
                    pendingMakeTarget = nil
                }
            }
        } message: {
            Text(pendingMakeTarget.map { "Execute \($0) in \(selectedWorktree?.branchName ?? "")?" } ?? "")
        }
        .confirmationDialog("Run npm script?", isPresented: Binding(
            get: { pendingScript != nil },
            set: { if !$0 { pendingScript = nil } }
        )) {
            Button("Run") {
                if let worktree = selectedWorktree, let script = pendingScript {
                    appModel.runNPMScript(script, in: worktree, repository: repository, modelContext: modelContext)
                    pendingScript = nil
                }
            }
        } message: {
            Text(pendingScript.map { "Execute npm run \($0)?" } ?? "")
        }
        .confirmationDialog("Manage dependencies?", isPresented: Binding(
            get: { pendingDependencyMode != nil },
            set: { if !$0 { pendingDependencyMode = nil } }
        )) {
            Button(pendingDependencyMode?.displayName ?? "Run") {
                if let worktree = selectedWorktree, let mode = pendingDependencyMode {
                    appModel.installDependencies(mode: mode, in: worktree, repository: repository, modelContext: modelContext)
                    pendingDependencyMode = nil
                }
            }
        } message: {
            Text("This action may modify lockfiles and installed dependencies.")
        }
    }

    private var repositoryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(repository.primaryRemote?.url ?? repository.remoteURL ?? "No remote configured")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(repository.bareRepositoryPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Spacer()
                HStack(spacing: 10) {
                    Button("Refresh") {
                        Task {
                            await appModel.refresh(repository, in: modelContext)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Manage Remotes") {
                        appModel.presentRemoteManagement(for: repository)
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 12) {
                StatChip(title: "Default Branch", value: repository.defaultBranch)
                StatChip(title: "Remotes", value: "\(repository.remotes.count)")
                StatChip(title: "Worktrees", value: "\(repository.worktrees.count)")
                StatChip(title: "Runs", value: "\(repository.runs.count)")
                StatChip(title: "Last Fetch", value: repository.lastFetchedAt.map { Self.relativeDateFormatter.localizedString(for: $0, relativeTo: .now) } ?? "Never")
            }

            if let error = repository.lastErrorMessage?.nilIfBlank {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "sparkles")
                .font(.title2)
                .padding(16)
                .foregroundStyle(.secondary)
        }
    }

    private var worktreeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Worktrees")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    appModel.presentWorktreeSheet(for: repository)
                } label: {
                    Label("Create Worktree", systemImage: "plus")
                }
            }

            if repository.worktrees.isEmpty {
                Text("No worktrees yet. Create one from the bare repository to start development.")
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(repository.worktrees.sorted(by: { $0.createdAt > $1.createdAt })) { worktree in
                        Button {
                            selectedWorktreeID = worktree.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(worktree.branchName)
                                            .font(.headline)
                                        if appModel.isAgentRunning(for: worktree) {
                                            AgentActivityDot()
                                        }
                                    }
                                    Text(worktree.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let issueContext = worktree.issueContext {
                                        Label(issueContext, systemImage: "number")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedWorktreeID == worktree.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                selectedWorktreeID == worktree.id ? .regularMaterial : .thinMaterial,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open in Cursor") {
                                Task {
                                    await appModel.openIDE(.cursor, for: worktree, in: modelContext)
                                }
                            }
                            Button("Open in VS Code") {
                                Task {
                                    await appModel.openIDE(.vscode, for: worktree, in: modelContext)
                                }
                            }
                            Button("Publish Branch") {
                                appModel.presentPublishSheet(for: repository, worktree: worktree)
                            }
                            Button("Remove Worktree", role: .destructive) {
                                worktreePendingRemoval = worktree
                            }
                        }
                    }
                }
            }
        }
    }

    private func actionSection(for worktree: WorktreeRecord) -> some View {
        let makeTargets = appModel.availableMakeTargets(for: worktree)
        let npmScripts = appModel.availableNPMScripts(for: worktree)

        return VStack(alignment: .leading, spacing: 16) {
            Text("Actions")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 14) {
                AgentAssignmentRow(
                    worktree: worktree,
                    availableAgents: appModel.availableAgents,
                    isRunning: appModel.isAgentRunning(for: worktree),
                    onLaunch: { tool in
                        appModel.launchAgent(tool, for: worktree, in: modelContext)
                    }
                )

                HStack(spacing: 12) {
                    Button("Open Cursor") {
                        Task {
                            await appModel.openIDE(.cursor, for: worktree, in: modelContext)
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open VS Code") {
                        Task {
                            await appModel.openIDE(.vscode, for: worktree, in: modelContext)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Install Dependencies") {
                        pendingDependencyMode = .install
                    }
                    .buttonStyle(.bordered)

                    Button("Publish Branch") {
                        appModel.presentPublishSheet(for: repository, worktree: worktree)
                    }
                    .buttonStyle(.bordered)
                }

                if !makeTargets.isEmpty {
                    ActionPillGroup(title: "Make Targets", items: makeTargets) { target in
                        pendingMakeTarget = target
                    }
                }

                if !npmScripts.isEmpty {
                    ActionPillGroup(title: "NPM Scripts", items: npmScripts) { script in
                        pendingScript = script
                    }
                }

                if makeTargets.isEmpty && npmScripts.isEmpty {
                    Text("No Makefile or package.json scripts detected in this worktree yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var runHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run History")
                .font(.title3.weight(.semibold))

            let recentRuns = repository.runs.sorted(by: { $0.startedAt > $1.startedAt }).prefix(8)
            if recentRuns.isEmpty {
                Text("No runs recorded for this repository yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(recentRuns)) { run in
                        Button {
                            appModel.selectedRunID = run.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(run.title)
                                        .font(.headline)
                                    Text(run.commandLine)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(run.status.rawValue.capitalized)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(statusColor(for: run.status).opacity(0.18), in: Capsule())
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyWorktreeState: some View {
        ContentUnavailableView("Select a Worktree", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Choose or create a worktree to launch editors, run Make targets, and execute npm scripts."))
            .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var selectedWorktree: WorktreeRecord? {
        repository.worktrees.first(where: { $0.id == selectedWorktreeID }) ??
            repository.worktrees.sorted(by: { $0.createdAt > $1.createdAt }).first
    }

    private func statusColor(for status: RunStatusKind) -> Color {
        switch status {
        case .pending, .running:
            .orange
        case .succeeded:
            .green
        case .failed:
            .red
        case .cancelled:
            .gray
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct AgentAssignmentRow: View {
    let worktree: WorktreeRecord
    let availableAgents: Set<AIAgentTool>
    let isRunning: Bool
    let onLaunch: (AIAgentTool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI Agents")
                .font(.headline)

            if installedAgents.isEmpty {
                Text("No supported local agent CLI was detected.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ForEach(installedAgents) { tool in
                        if tool == worktree.assignedAgent {
                            Button {
                                onLaunch(tool)
                            } label: {
                                Label(tool.displayName, systemImage: icon(for: tool))
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                onLaunch(tool)
                            } label: {
                                Label(tool.displayName, systemImage: icon(for: tool))
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if isRunning {
                        Label("Running", systemImage: "terminal.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        AgentActivityDot()
                    }

                    Spacer()
                }
            }
        }
    }

    private var installedAgents: [AIAgentTool] {
        AIAgentTool.allCases.filter { tool in
            tool != .none && availableAgents.contains(tool)
        }
    }

    private func icon(for tool: AIAgentTool) -> String {
        switch tool {
        case .none:
            "circle"
        case .claudeCode:
            "sparkles.rectangle.stack"
        case .codex:
            "terminal"
        case .githubCopilot:
            "chevron.left.forwardslash.chevron.right"
        case .cursorCLI:
            "cursorarrow.click.2"
        }
    }
}

private struct AgentActivityDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.purple)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing ? 1.35 : 0.85)
            .opacity(pulsing ? 1.0 : 0.5)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

private struct RunConsoleView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var pendingInput = ""

    let run: RunRecord?
    let activeRunIDs: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let run {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(run.title)
                            .font(.title3.weight(.semibold))
                        Text(run.commandLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if activeRunIDs.contains(run.id) {
                        Button("Cancel", role: .destructive) {
                            appModel.cancelRun(run, in: modelContext)
                        }
                    }
                }

                VStack(spacing: 12) {
                    TextEditor(text: .constant(run.outputText))
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(.white)

                    if activeRunIDs.contains(run.id) {
                        HStack(spacing: 12) {
                            TextField("Send input to session", text: $pendingInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    submitInput(for: run)
                                }

                            Button("Send") {
                                submitInput(for: run)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(pendingInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            } else {
                ContentUnavailableView("No Run Selected", systemImage: "terminal", description: Text("Select a run from the repository history to inspect logs and exit state."))
            }
        }
        .padding(24)
        .navigationTitle("Run Console")
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.06), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func submitInput(for run: RunRecord) {
        let text = pendingInput
        pendingInput = ""
        appModel.sendInput(text, to: run)
    }
}

private struct CloneRepositorySheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 18) {
            Text("Clone Bare Repository")
                .font(.title2.weight(.semibold))

            TextField("Remote URL", text: $appModel.cloneDraft.remoteURLString)
                .textFieldStyle(.roundedBorder)
            TextField("Display Name (optional)", text: $appModel.cloneDraft.displayName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Clone") {
                    Task {
                        await appModel.cloneRepository(in: modelContext)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.cloneDraft.remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(.regularMaterial)
    }
}

private struct CreateWorktreeSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let repository: ManagedRepository

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 18) {
            Text("Create Worktree")
                .font(.title2.weight(.semibold))

            TextField("Branch Name", text: $appModel.worktreeDraft.branchName)
                .textFieldStyle(.roundedBorder)
            TextField("Issue / Context (optional)", text: $appModel.worktreeDraft.issueContext)
                .textFieldStyle(.roundedBorder)
            TextField("Source Branch", text: $appModel.worktreeDraft.sourceBranch)
                .textFieldStyle(.roundedBorder)

            Text("Bare repository: \(repository.bareRepositoryPath)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Create") {
                    Task {
                        await appModel.createWorktree(for: repository, in: modelContext)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.worktreeDraft.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(.regularMaterial)
    }
}

private struct RemoteManagementSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StoredSSHKey.displayName) private var sshKeys: [StoredSSHKey]

    let repository: ManagedRepository
    @State private var editingRemote: RepositoryRemote?
    @State private var remotePendingRemoval: RepositoryRemote?
    @State private var isEditorPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Manage Remotes")
                        .font(.title2.weight(.semibold))
                    Text(repository.displayName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }

            if repository.remotes.isEmpty {
                ContentUnavailableView("No Remotes", systemImage: "network", description: Text("Add a remote to enable refreshes and publishing."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List {
                    ForEach(repository.remotes.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { remote in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(remote.name)
                                    .font(.headline)
                                if !remote.fetchEnabled {
                                    Text("Fetch Off")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.thinMaterial, in: Capsule())
                                }
                                Spacer()
                                Button("Edit") {
                                    editingRemote = remote
                                    isEditorPresented = true
                                }
                                Button("Remove", role: .destructive) {
                                    remotePendingRemoval = remote
                                }
                            }
                            Text(remote.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(remote.sshKey?.displayName ?? "No SSH key assigned")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(minHeight: 260)
            }

            HStack {
                Button {
                    editingRemote = nil
                    isEditorPresented = true
                } label: {
                    Label("Add Remote", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if sshKeys.isEmpty {
                    Text("SSH keys are managed in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 700, height: 520)
        .sheet(isPresented: $isEditorPresented) {
            RemoteEditorSheet(repository: repository, remote: editingRemote)
                .environment(appModel)
        }
        .confirmationDialog("Remove remote?", item: $remotePendingRemoval) { remote in
            Button("Remove", role: .destructive) {
                Task {
                    await appModel.removeRemote(remote, from: repository, in: modelContext)
                }
            }
        } message: { remote in
            Text("Remove \(remote.name) from \(repository.displayName)?")
        }
    }
}

private struct RemoteEditorSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StoredSSHKey.displayName) private var sshKeys: [StoredSSHKey]

    let repository: ManagedRepository
    let remote: RepositoryRemote?

    @State private var name = ""
    @State private var url = ""
    @State private var fetchEnabled = true
    @State private var selectedSSHKeyID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(remote == nil ? "Add Remote" : "Edit Remote")
                .font(.title2.weight(.semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("URL", text: $url)
                .textFieldStyle(.roundedBorder)
            Toggle("Use this remote during refresh", isOn: $fetchEnabled)

            Picker("SSH Key", selection: $selectedSSHKeyID) {
                Text("None").tag(nil as UUID?)
                ForEach(sshKeys) { key in
                    Text(key.displayName).tag(Optional(key.id))
                }
            }

            if let key = sshKeys.first(where: { $0.id == selectedSSHKeyID }) {
                Text(key.publicKey)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    Task {
                        let key = sshKeys.first(where: { $0.id == selectedSSHKeyID })
                        await appModel.saveRemote(
                            name: name,
                            url: url,
                            fetchEnabled: fetchEnabled,
                            sshKey: key,
                            for: repository,
                            editing: remote,
                            in: modelContext
                        )
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(.regularMaterial)
        .task {
            name = remote?.name ?? ""
            url = remote?.url ?? ""
            fetchEnabled = remote?.fetchEnabled ?? true
            selectedSSHKeyID = remote?.sshKey?.id
        }
    }
}

private struct PublishBranchSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let repository: ManagedRepository
    let worktree: WorktreeRecord

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 18) {
            Text("Publish Branch")
                .font(.title2.weight(.semibold))

            Text(worktree.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Picker("Remote", selection: $appModel.publishDraft.remoteName) {
                ForEach(repository.remotes.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { remote in
                    Text("\(remote.name) (\(remote.url))").tag(remote.name)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Publish") {
                    Task {
                        await appModel.publishSelectedBranch(in: modelContext)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.publishDraft.remoteName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(.regularMaterial)
    }
}

private struct StatChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct ActionPillGroup: View {
    let title: String
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            FlowLayout(items: items) { item in
                Button(item) {
                    action(item)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct FlowLayout<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let items: Data
    let content: (Data.Element) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let rows = rows(for: Array(items))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    ForEach(row, id: \.self) { item in
                        content(item)
                    }
                    Spacer()
                }
            }
        }
    }

    private func rows(for values: [Data.Element]) -> [[Data.Element]] {
        var rows: [[Data.Element]] = [[]]
        for item in values {
            if rows[rows.count - 1].count == 4 {
                rows.append([item])
            } else {
                rows[rows.count - 1].append(item)
            }
        }
        return rows
    }
}

private extension View {
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
