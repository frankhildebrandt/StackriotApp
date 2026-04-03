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
                    HStack(spacing: 8) {
                        if run.isFixableBuildFailure {
                            fixWithAIMenu(for: run)
                        }

                        if activeRunIDs.contains(run.id), appModel.terminalSession(for: run) == nil {
                            Button("Cancel", role: .destructive) {
                                appModel.cancelRun(run, in: modelContext)
                            }
                        } else {
                            Button("Close", role: activeRunIDs.contains(run.id) ? .destructive : nil) {
                                appModel.requestCloseTab(run, in: modelContext)
                            }
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
                    } else if appModel.hasStructuredFeed(for: run) {
                        AgentRunFeedView(run: run)
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
                }
            } else {
                ContentUnavailableView("No Tab Selected", systemImage: "terminal", description: Text("Select a tab to inspect logs and exit state."))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: run?.id) {
            guard let run,
                  let repositoryID = run.repositoryID,
                  let worktreeID = run.worktreeID
            else {
                return
            }
            await Task.yield()
            appModel.recordSelectionPhase(
                repositoryID: repositoryID,
                worktreeID: worktreeID,
                phase: "run-console-view-visible",
                metadata: [
                    "runID": run.id.uuidString,
                    "isActive": activeRunIDs.contains(run.id),
                    "hasTerminalSession": appModel.terminalSession(for: run) != nil,
                    "showsAISummary": appModel.shouldShowAISummary(for: run),
                    "hasStructuredFeed": appModel.hasStructuredFeed(for: run),
                    "outputLength": run.outputText.count
                ]
            )
        }
    }

    private func fixWithAIMenu(for run: RunRecord) -> some View {
        let installedAgents = appModel.installedAgentTools()
        return Menu {
            if installedAgents.isEmpty {
                Text("No agents installed")
            } else {
                ForEach(installedAgents) { tool in
                    Button("Fix with \(tool.displayName)") {
                        Task {
                            await appModel.launchFixWithAI(for: run, using: tool, in: modelContext)
                        }
                    }
                }
            }
        } label: {
            Label("Fix with AI", systemImage: "sparkles")
        }
        .disabled(installedAgents.isEmpty)
    }
}
