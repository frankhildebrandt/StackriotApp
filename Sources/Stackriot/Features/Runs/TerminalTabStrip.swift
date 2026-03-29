import SwiftData
import SwiftUI

struct TerminalTabStrip: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let repository: ManagedRepository
    let worktree: WorktreeRecord
    let tabs: [RunRecord]

    var body: some View {
        let isPlanSelected = appModel.isPlanTabSelected(for: worktree)
            || (worktree.isDefaultBranchWorkspace && tabs.isEmpty)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // Plan chip — always first, never closable
                planChip(isPlanSelected: isPlanSelected)

                ForEach(tabs) { run in
                    TerminalTabChip(
                        run: run,
                        isSelected: !isPlanSelected && appModel.selectedTab(for: worktree, in: repository)?.id == run.id,
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

    // MARK: - Plan Chip

    private func planChip(isPlanSelected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: worktree.isDefaultBranchWorkspace ? "book.closed" : "doc.text")
                .font(.caption.weight(.semibold))
            Text(worktree.isDefaultBranchWorkspace ? "README" : "Plan")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isPlanSelected ? Color(nsColor: .underPageBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isPlanSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .frame(height: isPlanSelected ? 2 : 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appModel.selectPlanTab(for: worktree, in: repository)
        }
    }
}
