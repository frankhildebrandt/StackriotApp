import SwiftData
import SwiftUI

struct RunConsoleView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let run: RunRecord?
    let activeRunIDs: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let run {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                    }
                    Spacer()
                    if activeRunIDs.contains(run.id) {
                        Button("Cancel", role: .destructive) {
                            appModel.cancelRun(run, in: modelContext)
                        }
                    } else {
                        Button("Close") {
                            appModel.closeTab(run)
                        }
                    }
                }

                if let session = appModel.terminalSession(for: run) {
                    if appModel.shouldShowAISummary(for: run) {
                        AgentRunSummaryWindow(
                            run: run,
                            isSummarizing: appModel.summarizingRunIDs.contains(run.id),
                            onClose: { appModel.dismissAISummary(for: run) }
                        )
                    } else {
                        TerminalSessionView(session: session)
                            .id(session.runID)
                            .background(.black.opacity(0.92))
                            .clipShape(Rectangle())
                            .padding(.bottom, 12)
                    }
                } else {
                    if appModel.shouldShowAISummary(for: run) {
                        AgentRunSummaryWindow(
                            run: run,
                            isSummarizing: appModel.summarizingRunIDs.contains(run.id),
                            onClose: { appModel.dismissAISummary(for: run) }
                        )
                    } else {
                        TextEditor(text: .constant(run.outputText))
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .background(.black.opacity(0.9))
                            .clipShape(Rectangle())
                            .foregroundStyle(.white)
                            .padding(.bottom, 12)
                    }
                }
            } else {
                ContentUnavailableView("No Tab Selected", systemImage: "terminal", description: Text("Select a tab to inspect logs and exit state."))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
