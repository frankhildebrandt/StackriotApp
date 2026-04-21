import Foundation
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
                HStack(alignment: .center, spacing: 10) {
                    runConsoleLeadingToolbar(for: run)

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

    @ViewBuilder
    private func runConsoleLeadingToolbar(for run: RunRecord) -> some View {
        let isRunning = activeRunIDs.contains(run.id)
        let supportsRuntime = appModel.supportsRunConsoleRuntimeTools(for: run)
        let supportsRecorder = appModel.supportsSessionRecorder(for: run)
        let isRecording = appModel.isSessionRecordingActive(for: run)
        let logURL = appModel.sessionRecorderLogFileURL(for: run)
        let logExists = logURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        if supportsRuntime {
            HStack(spacing: 6) {
                Button {
                    appModel.cancelRun(run, in: modelContext)
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isRunning)
                .help("Stop the running process (graceful terminal cancel / SIGTERM).")

                Button {
                    appModel.startRunConfigurationAgain(run, in: modelContext)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunning || !supportsRuntime)
                .help("Start this run configuration again in a new tab (when not running).")

                Button {
                    appModel.rerunRunConfiguration(run, in: modelContext)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!supportsRuntime)
                .help("Re-run: send Ctrl+C, wait, force kill if still running, then start again in a new tab.")
            }
        }

        if supportsRecorder {
            HStack(spacing: 6) {
                Button {
                    appModel.startRunSessionRecording(run, in: modelContext)
                } label: {
                    Image(systemName: "record.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRecording)
                .help("Append terminal output to a session log under the documentation repository (session-logs/…).")

                Button {
                    appModel.stopRunSessionRecording(run)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isRecording)
                .help("Stop recording and close the session log file.")

                Button {
                    appModel.openRunSessionRecording(run)
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!logExists)
                .help("Open the session log in the default app.")
            }
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
