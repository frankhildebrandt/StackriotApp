import SwiftData
import SwiftUI

@main
struct StackriotApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("Stackriot", id: "main") {
            RootView()
                .environment(appModel)
                .onOpenURL { url in
                    appModel.presentQuickIntentFromURL(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task {
                        await appModel.handleAppDidBecomeActive()
                    }
                }
        }
        .defaultSize(width: 1480, height: 920)
        .modelContainer(for: StackriotModelContainer.persistentModelTypes)
        .commands {
            StackriotAppCommands(appModel: appModel)
        }

        Settings {
            SettingsRootView()
                .environment(appModel)
        }
        .defaultSize(width: 1040, height: 680)
        .modelContainer(for: StackriotModelContainer.persistentModelTypes)

        Window("About Stackriot", id: "about") {
            AboutView()
        }

        Window("RAW Logs", id: "raw-logs") {
            RawLogBrowserWindow()
                .environment(appModel)
        }
        .defaultSize(width: 1480, height: 920)
        .modelContainer(for: StackriotModelContainer.persistentModelTypes)

        Window("Quick Intent", id: "quick-intent") {
            QuickIntentWindow()
                .environment(appModel)
        }
        .defaultSize(width: 760, height: 560)
        .modelContainer(for: StackriotModelContainer.persistentModelTypes)

        WindowGroup("Antwort", id: "cursor-agent-markdown", for: AgentMarkdownWindowPayload.self) { $payload in
            if let payload {
                AgentMarkdownReadOnlyWindow(payload: payload)
                    .environment(appModel)
            }
        }
        .defaultSize(width: 560, height: 720)
    }
}

private struct AgentMarkdownReadOnlyWindow: View {
    let payload: AgentMarkdownWindowPayload

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(payload.title)
                    .font(.headline)
                agentMarkdownText(payload.markdown)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func agentMarkdownText(_ raw: String) -> Text {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if let attributed = try? AttributedString(
            markdown: normalized,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            return Text(attributed)
        }
        return Text(normalized)
    }
}

private struct QuickIntentWindow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let context = appModel.quickIntentRepositoryContext()
        let planningAgents = appModel.availablePlanningAgents()
        let executionAgents = appModel.installedAgentTools()
        let canCreate = context.repository != nil
            && !(appModel.quickIntentSession?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick Intent")
                        .font(.title2.weight(.semibold))
                    Text("Rohtext aus Markierung, Clipboard oder URL sofort in einen IdeaTree ueberfuehren.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Schliessen") {
                    appModel.dismissQuickIntentSession()
                    dismiss()
                }
            }

            contextSection(namespace: context.namespace, repository: context.repository, worktree: context.worktree)
            sessionSection

            Spacer()

            HStack {
                Button("Zusammenfassen") {
                    Task {
                        await appModel.summarizeQuickIntent()
                    }
                }
                .disabled(appModel.quickIntentSession?.isSummarizing == true || !canCreate)

                Spacer()

                ideaTreeCreateButton(canCreate: canCreate)

                Menu {
                    if planningAgents.isEmpty {
                        Text("Keine Planungs-Agenten installiert")
                    } else {
                        ForEach(planningAgents) { tool in
                            Button(tool.displayName) {
                                Task {
                                    await appModel.runQuickIntentCreateAction(planningAgent: tool)
                                    dismiss()
                                }
                            }
                        }
                    }
                } label: {
                    Label("Plan starten", systemImage: "sparkles.rectangle.stack")
                }
                .disabled(!canCreate || planningAgents.isEmpty || appModel.quickIntentSession?.isPerformingAction == true)

                Menu {
                    if executionAgents.isEmpty {
                        Text("Keine Agenten installiert")
                    } else {
                        ForEach(executionAgents) { tool in
                            Button(tool.displayName) {
                                Task {
                                    await appModel.runQuickIntentCreateAction(executionAgent: tool)
                                    dismiss()
                                }
                            }
                        }
                    }
                } label: {
                    Label("Mit Agent ausfuehren", systemImage: "sparkles")
                }
                .disabled(!canCreate || executionAgents.isEmpty || appModel.quickIntentSession?.isPerformingAction == true)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 500)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func contextSection(
        namespace: RepositoryNamespace?,
        repository: ManagedRepository?,
        worktree: WorktreeRecord?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kontext")
                .font(.headline)

            HStack(spacing: 8) {
                contextChip(title: "Namespace", value: namespace?.name ?? "Nicht ausgewaehlt", isMissing: namespace == nil)
                contextChip(title: "Repository", value: repository?.displayName ?? "Nicht ausgewaehlt", isMissing: repository == nil)
                contextChip(title: "Worktree", value: worktree?.branchName ?? "Nicht ausgewaehlt", isMissing: worktree == nil)
            }

            if repository == nil {
                Label("Waehle im Hauptfenster zuerst ein Repository aus. Danach kann das Quick Intent einen IdeaTree anlegen.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        if let session = appModel.quickIntentSession {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quelle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(session.source.displayName) – \(session.sourceLabel)")
                        .font(.subheadline)
                }

                if let hint = session.accessibilityHint {
                    Label(hint, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Branch")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("feature/kurze-zusammenfassung", text: Binding(
                        get: { appModel.quickIntentSession?.branchName ?? "" },
                        set: { appModel.quickIntentSession?.branchName = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                Toggle("Sub-Worktree vom aktuellen Branch", isOn: Binding(
                    get: { appModel.quickIntentSession?.useCurrentWorktreeAsParent ?? false },
                    set: { appModel.quickIntentSession?.useCurrentWorktreeAsParent = $0 }
                ))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Intent")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { appModel.quickIntentSession?.text ?? "" },
                        set: { appModel.quickIntentSession?.text = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        } else {
            ContentUnavailableView(
                "Noch kein Quick Intent",
                systemImage: "bolt.badge.clock",
                description: Text("Loese den globalen Hotkey aus oder oeffne `stackriot://quick-intent?text=...`, um den Dialog vorzufuellen.")
            )
        }
    }

    private func contextChip(title: String, value: String, isMissing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isMissing ? .secondary : .primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func ideaTreeCreateButton(canCreate: Bool) -> some View {
        Button("IdeaTree anlegen") {
            Task {
                await appModel.runQuickIntentCreateAction()
                dismiss()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canCreate || appModel.quickIntentSession?.isPerformingAction == true)
    }
}
