import SwiftData
import SwiftUI

struct RunConsoleColumn: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let repository: ManagedRepository

    @State private var showLogDrawer = false

    var body: some View {
        let worktree = appModel.selectedWorktree(for: repository)
        let worktreeDiscovery = worktree.map { appModel.cachedWorktreeDiscoverySnapshot(for: $0) }
        let _ = {
            guard let worktree else { return }
            appModel.recordSelectionPhase(
                repositoryID: repository.id,
                worktreeID: worktree.id,
                phase: "run-console-column-body",
                metadata: [
                    "hasDevContainerConfiguration": worktreeDiscovery?.hasDevContainerConfiguration == true
                ]
            )
        }()

        VStack(alignment: .leading, spacing: 0) {
            if let worktree {
                // Worktree-Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(worktree.isDefaultBranchWorkspace ? "Main/Default" : worktree.branchName)
                        .font(.title3.weight(.semibold))
                    if let displayPath = worktree.displayPath {
                        Text(worktree.isIdeaTree ? "IdeaTree · \(displayPath)" : displayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if worktree.isIdeaTree {
                        Text("IdeaTree · not materialized yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, worktree.isDefaultBranchWorkspace ? 8 : 10)

                // Action Toolbar
                WorktreeActionBar(worktree: worktree, repository: repository)

                if worktreeDiscovery?.hasDevContainerConfiguration == true {
                    DevContainerConsolePanel(worktree: worktree)
                }

                Divider()

                // Terminal Tabs + Console
                let tabs = appModel.visibleTabs(for: worktree, in: repository)
                let isPlanSelected = appModel.isPrimaryContextTabSelected(for: worktree)
                    || (worktree.isDefaultBranchWorkspace && tabs.isEmpty)
                let selectedTab = isPlanSelected ? nil : appModel.selectedTab(for: worktree, in: repository)

                TerminalTabStrip(repository: repository, worktree: worktree, tabs: tabs)

                if isPlanSelected {
                    WorktreePrimaryContextView(worktree: worktree, repository: repository)
                } else if tabs.isEmpty {
                    ContentUnavailableView(
                        "No Tabs for This Worktree",
                        systemImage: "rectangle.stack",
                        description: Text("Start a command or reopen a previous run from history to create a terminal tab.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RunConsoleView(
                        run: selectedTab,
                        activeRunIDs: appModel.activeRunIDs
                    )
                }
            } else {
                ContentUnavailableView(
                    "No Worktree Selected",
                    systemImage: "terminal",
                    description: Text("Select a worktree to inspect its terminal tabs.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(worktree?.id ?? repository.id)
        .task(id: worktree?.id) {
            guard let worktree else { return }
            await Task.yield()
            let tabs = appModel.visibleTabs(for: worktree, in: repository)
            let isPlanSelected = appModel.isPrimaryContextTabSelected(for: worktree)
                || (worktree.isDefaultBranchWorkspace && tabs.isEmpty)
            let selectedTab = isPlanSelected ? nil : appModel.selectedTab(for: worktree, in: repository)
            appModel.recordSelectionPhase(
                repositoryID: repository.id,
                worktreeID: worktree.id,
                phase: "run-console-column-visible",
                metadata: [
                    "tabCount": tabs.count,
                    "isPlanSelected": isPlanSelected,
                    "selectedTabID": selectedTab?.id.uuidString ?? "",
                    "selectedTabOutputLength": selectedTab?.outputText.count ?? 0
                ]
            )
            appModel.markRunConsoleVisible(for: repository.id, worktreeID: worktree.id)
        }
        .navigationTitle("Run Console")
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.06), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            if showLogDrawer, let drawerWorktree = worktree {
                logDrawer(worktree: drawerWorktree)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: worktree?.id) {
            guard let worktree, worktreeDiscovery?.hasDevContainerConfiguration == true else { return }
            while !Task.isCancelled {
                if appModel.shouldRefreshDevContainerImmediately(for: worktree) {
                    await appModel.refreshDevContainerState(for: worktree)
                }
                let interval = appModel.consoleDevContainerPollInterval(for: worktree)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                guard appModel.shouldActivelyPollDevContainer(for: worktree) else { continue }
            }
        }
        .onDisappear {
            if let worktree {
                appModel.stopDevContainerLogStreaming(for: worktree.id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        showLogDrawer.toggle()
                    }
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .disabled(worktree == nil)
                .help("Run-History anzeigen")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appModel.isDiffInspectorPresented.toggle()
                } label: {
                    Label("Diff", systemImage: "sidebar.right")
                }
                .disabled(worktree == nil)
                .help("Uncommitted Diff anzeigen")
            }
        }
    }

    // MARK: – Log Drawer

    @ViewBuilder
    private func logDrawer(worktree: WorktreeRecord) -> some View {
        let runs = appModel.runs(forWorktreeID: worktree.id, in: repository)

        VStack(spacing: 0) {
            HStack {
                Text("Run History")
                    .font(.subheadline.weight(.semibold))
                if !runs.isEmpty {
                    Text("\(runs.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        showLogDrawer = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if runs.isEmpty {
                Text("No runs recorded for this worktree yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                runHistoryTable(runs: Array(runs.prefix(30)))
            }
        }
        .frame(height: 280)
        .background(.regularMaterial)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    // MARK: – Run History Table

    @ViewBuilder
    private func runHistoryTable(runs: [RunRecord]) -> some View {
        ScrollView {
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

                Divider()

                ForEach(runs) { run in
                    Button {
                        appModel.reopenTab(run)
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            showLogDrawer = false
                        }
                    } label: {
                        HStack(spacing: 0) {
                            if appModel.activeRunIDs.contains(run.id) {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 28)
                            } else {
                                Circle()
                                    .fill(statusColor(for: run.status))
                                    .frame(width: 7, height: 7)
                                    .frame(width: 28)
                            }

                            Text(run.title)
                                .font(.subheadline)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(run.commandLine)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 180, alignment: .leading)

                            Text(run.startedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)

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

                    if run.id != runs.last?.id {
                        Divider().padding(.leading, 28)
                    }
                }
            }
        }
    }

    // MARK: – Helpers

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

    private func statusColor(for status: RunStatusKind) -> Color {
        switch status {
        case .pending, .running: .orange
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .gray
        }
    }
}
