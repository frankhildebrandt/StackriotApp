import SwiftData
import SwiftUI

struct TerminalTabStrip: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let repository: ManagedRepository
    let worktree: WorktreeRecord
    let tabs: [RunRecord]

    var body: some View {
        let isPrimaryContextSelected = appModel.isPrimaryContextTabSelected(for: worktree)
            || (worktree.isDefaultBranchWorkspace && tabs.isEmpty)
        let selectedPane = appModel.primaryPane(for: worktree)
        let discovery = appModel.cachedWorktreeDiscoverySnapshot(for: worktree)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                if worktree.primaryContextTabKind == .readme {
                    readmePrimaryChip(isPrimaryContextSelected: isPrimaryContextSelected)
                } else {
                    primaryPaneChip(
                        title: "Intent",
                        systemImage: "text.alignleft",
                        isSelected: isPrimaryContextSelected && selectedPane == .intent
                    ) {
                        appModel.selectPrimaryPane(.intent, for: worktree, in: repository)
                    }
                    if appModel.hasImplementationPlanContent(for: worktree.id) {
                        primaryPaneChip(
                            title: "Plan",
                            systemImage: "doc.text",
                            isSelected: isPrimaryContextSelected && selectedPane == .implementationPlan
                        ) {
                            appModel.selectPrimaryPane(.implementationPlan, for: worktree, in: repository)
                        }
                    }
                    if worktree.resolvedPrimaryContext != nil {
                        primaryPaneChip(
                            title: "Browser",
                            systemImage: worktree.primaryContextTabSystemImage,
                            isSelected: isPrimaryContextSelected && selectedPane == .browser
                        ) {
                            appModel.selectPrimaryPane(.browser, for: worktree, in: repository)
                        }
                    }
                    if discovery.hasDevContainerConfiguration {
                        primaryPaneChip(
                            title: "Devcontainer Logs",
                            systemImage: "shippingbox",
                            isSelected: isPrimaryContextSelected && selectedPane == .devContainerLogs
                        ) {
                            appModel.selectPrimaryPane(.devContainerLogs, for: worktree, in: repository)
                        }
                    }
                }

                ForEach(tabs) { run in
                    TerminalTabChip(
                        run: run,
                        isSelected: !isPrimaryContextSelected && appModel.selectedTab(for: worktree, in: repository)?.id == run.id,
                        isRunning: appModel.activeRunIDs.contains(run.id),
                        usesCloseActionWhileRunning: appModel.terminalSession(for: run) != nil,
                        onSelect: {
                            appModel.selectTab(run)
                        },
                        onClose: {
                            appModel.requestCloseTab(run, in: modelContext)
                        },
                        onCancel: {
                            appModel.cancelRun(run, in: modelContext)
                        }
                    )
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 1)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: worktree.id) {
            await Task.yield()
            appModel.recordSelectionPhase(
                repositoryID: repository.id,
                worktreeID: worktree.id,
                phase: "terminal-tab-strip-visible",
                metadata: [
                    "tabCount": tabs.count,
                    "repositoryRunCount": repository.runs.count,
                    "selectedPane": appModel.primaryPane(for: worktree).rawValue,
                    "hasDevContainerConfiguration": discovery.hasDevContainerConfiguration
                ]
            )
        }
    }

    // MARK: - Primary Context Chips

    private func readmePrimaryChip(isPrimaryContextSelected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: worktree.primaryContextTabSystemImage)
                .font(.caption.weight(.semibold))
            Text(worktree.primaryContextTabTitle)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isPrimaryContextSelected ? Color(nsColor: .underPageBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isPrimaryContextSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .frame(height: isPrimaryContextSelected ? 2 : 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appModel.selectPrimaryContextTab(for: worktree, in: repository)
        }
    }

    private func primaryPaneChip(
        title: String,
        systemImage: String,
        isSelected: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color(nsColor: .underPageBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .frame(height: isSelected ? 2 : 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
