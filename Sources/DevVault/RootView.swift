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
                isAgentRunningForRepository: appModel.isAgentRunning(forRepository:),
                onAddRepository: appModel.presentCloneSheet,
                onRefreshRepository: { repository in
                    appModel.refresh(repository, in: modelContext)
                }
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
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
        .alert("Operation Failed", isPresented: Binding(
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
    let isAgentRunningForRepository: (ManagedRepository) -> Bool
    let onAddRepository: () -> Void
    let onRefreshRepository: (ManagedRepository) -> Void

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
                        Text(repository.remoteURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Label(repository.status.rawValue.capitalized, systemImage: statusSymbol(for: repository.status))
                            .font(.caption)
                            .foregroundStyle(repository.status == .ready ? .green : .orange)
                    }
                    .padding(.vertical, 6)
                    .tag(repository.id)
                    .contextMenu {
                        Button("Refresh") {
                            onRefreshRepository(repository)
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
            Text(repository.remoteURL)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                StatChip(title: "Default Branch", value: repository.defaultBranch)
                StatChip(title: "Worktrees", value: "\(repository.worktrees.count)")
                StatChip(title: "Runs", value: "\(repository.runs.count)")
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
                    onAssign: { tool in
                        appModel.assignAgent(tool, to: worktree, in: modelContext)
                    },
                    onLaunch: {
                        appModel.launchAgent(for: worktree)
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
}

private struct AgentAssignmentRow: View {
    let worktree: WorktreeRecord
    let availableAgents: Set<AIAgentTool>
    let isRunning: Bool
    let onAssign: (AIAgentTool) -> Void
    let onLaunch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker(
                "AI Agent",
                selection: Binding(
                    get: { worktree.assignedAgent },
                    set: { onAssign($0) }
                )
            ) {
                ForEach(AIAgentTool.allCases) { tool in
                    Text(label(for: tool)).tag(tool)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220)

            if worktree.assignedAgent != .none {
                Button {
                    onLaunch()
                } label: {
                    Label(
                        isRunning ? "Running" : "Launch Agent",
                        systemImage: isRunning ? "terminal.fill" : "terminal"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)
                .tint(isRunning ? .purple : .accentColor)
            }

            if isRunning {
                AgentActivityDot()
            }

            Spacer()
        }
    }

    private func label(for tool: AIAgentTool) -> String {
        guard tool != .none else {
            return tool.displayName
        }

        if availableAgents.contains(tool) {
            return tool.displayName
        }

        return "\(tool.displayName) (not found)"
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

                TextEditor(text: .constant(run.outputText))
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(.white)
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
        let isPresented = Binding(
            get: { item.wrappedValue != nil },
            set: { newValue in
                if !newValue {
                    item.wrappedValue = nil
                }
            }
        )

        return confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            if let value = item.wrappedValue {
                actions(value)
            }
        } message: {
            if let value = item.wrappedValue {
                message(value)
            }
        }
    }
}
