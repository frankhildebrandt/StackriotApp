import SwiftData
import SwiftUI

struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let repository: ManagedRepository
    @State private var worktreePendingRemoval: WorktreeRemovalDraft?
    @State private var pendingMakeTarget: String?
    @State private var pendingScript: String?
    @State private var pendingDependencyMode: DependencyInstallMode?

    var body: some View {
        let worktrees = appModel.worktrees(for: repository)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                repositoryHeader
                worktreeSection(worktrees: worktrees)

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
            appModel.ensureSelectedWorktree(in: repository)
            await appModel.refreshWorktreeStatuses(for: repository)
        }
        .confirmationDialog("Remove worktree?", item: $worktreePendingRemoval) { worktree in
            Button("Remove", role: .destructive) {
                worktreePendingRemoval = nil
                if let record = appModel.worktreeRecord(with: worktree.id) {
                    Task {
                        await appModel.removeWorktree(record, in: modelContext)
                    }
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
        .alert("Rebase fehlgeschlagen", isPresented: Binding(
            get: { appModel.worktreePendingMergeOfferID != nil },
            set: { newValue in
                if !newValue {
                    appModel.worktreePendingMergeOfferID = nil
                }
            }
        )) {
            Button("Merge versuchen") {
                if
                    let worktreeID = appModel.worktreePendingMergeOfferID,
                    let worktree = appModel.worktreeRecord(with: worktreeID)
                {
                    Task {
                        await appModel.syncWorktreeFromMain(
                            worktree,
                            repository: repository,
                            strategy: .merge,
                            modelContext: modelContext
                        )
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {
                appModel.worktreePendingMergeOfferID = nil
            }
        } message: {
            Text("Der Rebase von \(repository.defaultBranch) konnte nicht abgeschlossen werden. Möchtest du stattdessen einen Merge versuchen?")
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

    private func worktreeSection(worktrees: [WorktreeRecord]) -> some View {
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

            if worktrees.isEmpty {
                Text("No worktrees yet. Create one from the bare repository to start development.")
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(worktrees) { worktree in
                        HStack(alignment: .top, spacing: 12) {
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

                                worktreeStatusRow(for: worktree)

                                if let issueContext = worktree.issueContext {
                                    Label(issueContext, systemImage: "number")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if selectedWorktree?.id == worktree.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selectedWorktree?.id == worktree.id ? .regularMaterial : .thinMaterial,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onTapGesture {
                            appModel.selectWorktree(worktree, in: repository)
                        }
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
                                worktreePendingRemoval = WorktreeRemovalDraft(id: worktree.id, path: worktree.path)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func worktreeStatusRow(for worktree: WorktreeRecord) -> some View {
        if let status = appModel.worktreeStatuses[worktree.id] {
            HStack(spacing: 10) {
                Text("↑\(status.aheadCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(status.aheadCount > 0 ? .primary : .secondary)

                Text("↓\(status.behindCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(status.behindCount > 0 ? .orange : .secondary)

                if status.hasUncommittedChanges {
                    Text("+\(status.addedLines)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)
                    Text("-\(status.deletedLines)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                } else {
                    Text("clean")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                }

                Spacer(minLength: 8)

                Button {
                    Task {
                        await appModel.syncWorktreeFromMain(
                            worktree,
                            repository: repository,
                            strategy: .rebase,
                            modelContext: modelContext
                        )
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Mit \(repository.defaultBranch) synchronisieren")
            }
        } else {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Spacer()
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

            let recentRuns = selectedWorktreeID.map { appModel.runs(forWorktreeID: $0, in: repository) } ?? []
            if recentRuns.isEmpty {
                Text("No runs recorded for this worktree yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(recentRuns.prefix(8))) { run in
                        Button {
                            appModel.reopenTab(run)
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
        appModel.selectedWorktree(for: repository)
    }

    private var selectedWorktreeID: UUID? {
        appModel.selectedWorktreeID(for: repository)
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
