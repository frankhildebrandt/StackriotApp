import SwiftData
import SwiftUI

struct TerminalTabStrip: View {
    @Environment(AppModel.self) private var appModel

    let repository: ManagedRepository
    let worktree: WorktreeRecord
    let tabs: [RunRecord]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs) { run in
                    TerminalTabChip(
                        run: run,
                        isSelected: appModel.selectedTab(for: worktree, in: repository)?.id == run.id,
                        isRunning: appModel.activeRunIDs.contains(run.id),
                        onSelect: {
                            appModel.selectTab(run)
                        },
                        onClose: {
                            appModel.closeTab(run)
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
    }
}

