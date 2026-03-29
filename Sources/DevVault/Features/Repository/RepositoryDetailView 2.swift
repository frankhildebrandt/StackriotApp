import SwiftData
import SwiftUI

struct LegacyRepositoryDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let repository: ManagedRepository
    @State private var worktreePendingRemoval: WorktreeRemovalDraft?
    @State private var showRunHistory = false

    var body: some View {
        let worktrees = appModel.worktrees(for: repository)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                repositoryHeader
                worktreeSection(worktrees: worktrees)

                if selectedWorktree != nil {
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
                            Divider()
                            Button("Mit \(repository.defaultBranch) synchronisieren") {
                                Task {
                                    await appModel.syncWorktreeFromMain(
                                        worktree,
                                        repository: repository,
                                        strategy: .rebase,
                                        modelContext: modelContext
                                    )
                                }
                            }
                            Button("Publish Branch") {
                                appModel.presentPublishSheet(for: repository, worktree: worktree)
                            }
                            Divider()
                            Button("Remove Worktree", role: .destructive) {
                                worktreePendingRemoval = WorktreeRemovalDraft(id: worktree.id, path: worktree.path)
                            }
                        }
                    }
                }
            }
        }
    }

    private var runHistorySection: some View {
        let recentRuns = selectedWorktreeID.map { appModel.runs(forWorktreeID: $0, in: repository) } ?? []

        return VStack(alignment: .leading, spacing: 10) {
            // Collapsible header button
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showRunHistory.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showRunHistory ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .animation(.easeInOut(duration: 0.18), value: showRunHistory)
                    Text("Run History")
                        .font(.title3.weight(.semibold))
                    if !recentRuns.isEmpty {
                        Text("\(recentRuns.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial, in: Capsule())
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if showRunHistory {
                if recentRuns.isEmpty {
                    Text("No runs recorded for this worktree yet.")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                } else {
                    runHistoryTable(runs: recentRuns)
                }
            }
        }
    }

    @ViewBuilder
    private func runHistoryTable(runs: [RunRecord]) -> some View {
        let displayRuns = Array(runs.prefix(30))

        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                Color.clear.frame(width: 28)
                Text("Title")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Command")
                    .frame(width: 180, alignment: .leading)
                Text("Gestartet")
                    .frame(width: 72, alignment: .trailing)
                Text("Dauer")
                    .frame(width: 60, alignment: .trailing)
                Color.clear.frame(width: 10)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.thinMaterial)

            Divider()

            ForEach(displayRuns) { run in
                Button {
                    appModel.reopenTab(run)
                } label: {
                    HStack(spacing: 0) {
                        // Status dot
                        Circle()
                            .fill(statusColor(for: run.status))
                            .frame(width: 7, height: 7)
                            .frame(width: 28)

                        // Title
                        Text(run.title)
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Command
                        Text(run.commandLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 180, alignment: .leading)

                        // Started
                        Text(run.startedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .trailing)

                        // Duration
                        Text(runDurationText(for: run))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)

                        Color.clear.frame(width: 10)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(Color.primary.opacity(0.0001))
                }
                .buttonStyle(.plain)

                if run.id != displayRuns.last?.id {
                    Divider().padding(.leading, 28)
                }
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func runDurationText(for run: RunRecord) -> String {
        guard let end = run.endedAt else {
            return run.status == .running ? "…" : "-"
        }
        let secs = Int(end.timeIntervalSince(run.startedAt))
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60
        let s = secs % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
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
