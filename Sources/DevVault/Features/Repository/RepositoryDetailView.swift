import SwiftData
import SwiftUI

struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let repository: ManagedRepository
    @State private var worktreePendingRemoval: WorktreeRemovalDraft?
    @State private var isRefreshingStatuses = false
    @State private var hoveredWorktreeID: UUID?
    @State private var isIntegrationSheetPresented = false
    @State private var integrationTargetWorktree: WorktreeRecord?
    @AppStorage("hasSeenWorktreeOnboarding") private var hasSeenWorktreeOnboarding = false

    var body: some View {
        let worktrees = appModel.worktrees(for: repository)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                worktreeSection(worktrees: worktrees)

                if selectedWorktree == nil {
                    emptyWorktreeState
                }
            }
            .padding(24)
        }
        .navigationTitle(repository.displayName)
        .task(id: repository.id) {
            _ = await appModel.ensureDefaultBranchWorkspace(for: repository, in: modelContext)
            appModel.ensureSelectedWorktree(in: repository)
            await appModel.refreshWorktreeStatuses(for: repository)
            appModel.restoreAllPRMonitoring(in: modelContext)
        }
        .sheet(isPresented: $isIntegrationSheetPresented) {
            if let worktree = integrationTargetWorktree {
                IntegrateWorktreeSheet(worktree: worktree, repository: repository)
            }
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
        .confirmationDialog("Merge-Konflikte auflösen", isPresented: Binding(
            get: { appModel.pendingIntegrationConflict != nil },
            set: { newValue in
                if !newValue {
                    appModel.pendingIntegrationConflict = nil
                }
            }
        ), presenting: appModel.pendingIntegrationConflict) { draft in
            ForEach(availableAgents) { tool in
                Button("Mit \(tool.displayName)") {
                    appModel.launchConflictResolutionAgent(tool, for: draft, in: modelContext)
                }
            }
            Button("Abbrechen", role: .cancel) {
                appModel.pendingIntegrationConflict = nil
            }
        } message: { draft in
            Text("""
            Beim Integrieren von \(draft.sourceBranch) in \(draft.defaultBranch) sind Konflikte entstanden.
            Wähle einen Agenten, der die Konflikte löst und den Commit `\(draft.commitMessage)` erstellt.
            """)
        }
    }

    private func worktreeSection(worktrees: [WorktreeRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Worktrees")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    isRefreshingStatuses = true
                    Task {
                        await appModel.refreshWorktreeStatuses(for: repository)
                        isRefreshingStatuses = false
                    }
                } label: {
                    if isRefreshingStatuses {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshingStatuses)
                Button {
                    appModel.presentWorktreeSheet(for: repository)
                } label: {
                    Label("Create Worktree", systemImage: "plus")
                }
            }

            // Einmaliger Onboarding-Hinweis
            if !hasSeenWorktreeOnboarding {
                onboardingBanner
            }

            if worktrees.isEmpty {
                Text("No worktrees yet. Create one from the bare repository to start development.")
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(worktrees) { worktree in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                Rectangle()
                                    .fill(selectedWorktree?.id == worktree.id ? Color.accentColor : Color.clear)
                                    .frame(width: 2)
                                    .padding(.vertical, 4)

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(worktreeTitle(for: worktree))
                                            .font(.headline)
                                        if worktree.isDefaultBranchWorkspace {
                                            Text(repository.defaultBranch)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(.regularMaterial, in: Capsule())
                                            if let defaultRemote = appModel.resolvedDefaultRemote(for: repository) {
                                                Text(defaultRemote.name)
                                                    .font(.caption.weight(.medium))
                                                    .foregroundStyle(.blue)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(.blue.opacity(0.12), in: Capsule())
                                            }
                                        }
                                        if appModel.isAgentRunning(for: worktree) {
                                            AgentActivityDot()
                                        }
                                    }
                                    Text(worktree.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    worktreeStatusRow(for: worktree)
                                    worktreeLifecycleIndicator(for: worktree)

                                    if let issueContext = worktree.issueContext {
                                        Label(issueContext, systemImage: "number")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if !worktree.isDefaultBranchWorkspace {
                                    Button {
                                        appModel.integrationDraft = IntegrationDraft(
                                            prTitle: worktree.branchName
                                        )
                                        integrationTargetWorktree = worktree
                                        isIntegrationSheetPresented = true
                                    } label: {
                                        Image(systemName: worktree.lifecycleState == .integrating
                                            ? "arrow.up.circle"
                                            : "arrow.up.circle.fill")
                                            .foregroundStyle(worktree.lifecycleState == .integrating ? .orange : .secondary)
                                            .imageScale(.large)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(worktree.lifecycleState == .integrating)
                                    .help("In \(repository.defaultBranch) integrieren")
                                }
                            }

                            if worktree.isDefaultBranchWorkspace {
                                defaultBranchIndicatorRow(for: worktree)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selectedWorktree?.id == worktree.id
                                ? Color.accentColor.opacity(0.10)
                                : (hoveredWorktreeID == worktree.id ? Color.primary.opacity(0.04) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appModel.selectWorktree(worktree, in: repository)
                        }
                        .onHover { isHovering in
                            hoveredWorktreeID = isHovering ? worktree.id : nil
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
                            if !worktree.isDefaultBranchWorkspace {
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
                                Button("In Main/Default integrieren") {
                                    appModel.integrationDraft = IntegrationDraft(
                                        prTitle: worktree.branchName
                                    )
                                    integrationTargetWorktree = worktree
                                    isIntegrationSheetPresented = true
                                }
                                Button("Publish Branch") {
                                    appModel.presentPublishSheet(for: repository, worktree: worktree)
                                }
                            }
                            Divider()
                            if !worktree.isDefaultBranchWorkspace {
                                Button("Remove Worktree", role: .destructive) {
                                    worktreePendingRemoval = WorktreeRemovalDraft(id: worktree.id, path: worktree.path)
                                }
                            }
                        }

                        if worktree.id != worktrees.last?.id {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )

                // Motivations-Hinweis: nur wenn kein Feature-Worktree vorhanden
                let featureWorktrees = worktrees.filter { !$0.isDefaultBranchWorkspace }
                if featureWorktrees.isEmpty {
                    featureWorktreeMotivationCard
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

    private var availableAgents: [AIAgentTool] {
        AIAgentTool.allCases.filter { tool in
            tool != .none && appModel.availableAgents.contains(tool)
        }
    }

    private func worktreeTitle(for worktree: WorktreeRecord) -> String {
        worktree.isDefaultBranchWorkspace ? "Main/Default" : worktree.branchName
    }

    // MARK: - Lifecycle Indicator

    @ViewBuilder
    private func worktreeLifecycleIndicator(for worktree: WorktreeRecord) -> some View {
        switch worktree.lifecycleState {
        case .active:
            EmptyView()
        case .integrating:
            HStack(spacing: 6) {
                Label("PR offen", systemImage: "arrow.triangle.merge")
                    .font(.caption)
                    .foregroundStyle(.blue)
                if let urlString = worktree.prURL, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
        case .merged:
            Label("Merged", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    // MARK: - Motivational UX

    private var featureWorktreeMotivationCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Einen Worktree pro Feature")
                    .font(.subheadline.weight(.medium))
                Text("Paralleles Arbeiten, saubere Isolation. Starte einen neuen Worktree für den nächsten Task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                appModel.presentWorktreeSheet(for: repository)
            } label: {
                Label("Neuer Worktree", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var onboardingBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 3) {
                Text("Feature-Workflow mit Worktrees")
                    .font(.caption.weight(.semibold))
                Text("Erstelle für jedes Feature einen eigenen Worktree. Der ↑-Button auf jeder Karte startet den Integrations-Workflow — lokal oder als GitHub PR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Verstanden") {
                hasSeenWorktreeOnboarding = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.yellow.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func defaultBranchIndicatorRow(for worktree: WorktreeRecord) -> some View {
        let status = appModel.worktreeStatuses[worktree.id]
        let ahead = status?.aheadCount ?? 0
        let behind = status?.behindCount ?? 0

        HStack(spacing: 10) {
            if let defaultRemote = appModel.resolvedDefaultRemote(for: repository) {
                Text("Basis von \(defaultRemote.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Keine Default-Remote-Konfiguration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
            } label: {
                Label(behind == 0 ? "Pull" : "Pull \(behind)", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(true)
            .opacity(behind > 0 ? 1 : 0.6)
            .help("Nur Anzeige: Der Default-Branch wird beim Refresh vom Default Remote aktualisiert.")

            Button {
            } label: {
                Label(ahead == 0 ? "Push" : "Push \(ahead)", systemImage: "arrow.up.to.line")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(true)
            .opacity(ahead > 0 ? 1 : 0.6)
            .help("Nur Anzeige: Lokale Commits im Default-Branch müssten publiziert werden.")
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func worktreeStatusRow(for worktree: WorktreeRecord) -> some View {
        let status = appModel.worktreeStatuses[worktree.id]
        let ahead = worktree.isDefaultBranchWorkspace ? 0 : (status?.aheadCount ?? 0)
        let behind = worktree.isDefaultBranchWorkspace ? 0 : (status?.behindCount ?? 0)
        let added = status?.addedLines ?? 0
        let deleted = status?.deletedLines ?? 0
        let hasChanges = status?.hasUncommittedChanges ?? false

        if ahead > 0 || behind > 0 || hasChanges {
            HStack(spacing: 8) {
                if behind > 0 {
                    Label("\(behind)", systemImage: "arrow.down")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }
                if ahead > 0 {
                    Label("\(ahead)", systemImage: "arrow.up")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if hasChanges {
                    if ahead > 0 || behind > 0 {
                        Divider()
                            .frame(height: 10)
                    }
                    Text("+\(added)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)
                    Text("-\(deleted)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
