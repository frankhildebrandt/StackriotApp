import SwiftData
import SwiftUI

struct RunConsoleColumn: View {
    @Environment(AppModel.self) private var appModel

    let repository: ManagedRepository

    var body: some View {
        let worktree = appModel.selectedWorktree(for: repository)
        let selectedRunID = worktree.flatMap { appModel.selectedTab(for: $0, in: repository)?.id }

        VStack(alignment: .leading, spacing: 0) {
            if let worktree {
                // Worktree-Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(worktree.branchName)
                        .font(.title3.weight(.semibold))
                    Text(worktree.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 10)

                // Action Toolbar
                WorktreeActionBar(worktree: worktree, repository: repository)

                Divider()

                // Terminal Tabs + Console
                let tabs = appModel.visibleTabs(for: worktree, in: repository)
                if tabs.isEmpty {
                    ContentUnavailableView(
                        "No Tabs for This Worktree",
                        systemImage: "rectangle.stack",
                        description: Text("Start a command or reopen a previous run from history to create a terminal tab.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TerminalTabStrip(repository: repository, worktree: worktree, tabs: tabs)
                    RunConsoleView(
                        run: appModel.selectedTab(for: worktree, in: repository),
                        activeRunIDs: appModel.activeRunIDs
                    )
                    .id(selectedRunID ?? worktree.id)
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
