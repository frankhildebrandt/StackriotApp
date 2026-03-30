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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // Plan chip — always first, never closable
                primaryContextChip(isPrimaryContextSelected: isPrimaryContextSelected)

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
    }

    // MARK: - Primary Context Chip

    private func primaryContextChip(isPrimaryContextSelected: Bool) -> some View {
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
}
