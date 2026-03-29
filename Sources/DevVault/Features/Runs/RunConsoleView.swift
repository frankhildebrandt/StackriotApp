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
                        Text(run.title)
                            .font(.title3.weight(.semibold))
                        Text(run.commandLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    TerminalSessionView(session: session)
                        .id(session.runID)
                        .background(.black.opacity(0.92))
                        .clipShape(Rectangle())
                        .padding(.bottom, 12)
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
            } else {
                ContentUnavailableView("No Tab Selected", systemImage: "terminal", description: Text("Select a tab to inspect logs and exit state."))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

