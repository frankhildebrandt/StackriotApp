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
        .defaultSize(
            width: QuickIntentWindowGeometry.idealSize.width,
            height: QuickIntentWindowGeometry.idealSize.height
        )
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
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
    @FocusState private var focusedField: QuickIntentField?

    private enum QuickIntentField: Hashable {
        case branch
        case intent
    }

    var body: some View {
        let context = appModel.quickIntentRepositoryContext()
        let planningAgents = appModel.availablePlanningAgents()
        let executionAgents = appModel.installedAgentTools()
        let session = appModel.quickIntentSession
        let canCreate = context.repository != nil
            && !(session?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        ZStack {
            Color.clear

            VStack(spacing: 18) {
                header
                contextSection(namespace: context.namespace, repository: context.repository, worktree: context.worktree)

                ScrollView {
                    sessionSection
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                actionBar(
                    canCreate: canCreate,
                    planningAgents: planningAgents,
                    executionAgents: executionAgents
                )
            }
            .padding(24)
            .frame(
                minWidth: QuickIntentWindowGeometry.minimumContentSize.width,
                minHeight: QuickIntentWindowGeometry.minimumContentSize.height
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            )
            .shadow(color: .black.opacity(0.18), radius: 32, y: 20)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QuickIntentWindowAccessor(presentationID: session?.id))
        .onAppear {
            focusPrimaryFieldIfNeeded(for: session)
        }
        .onChange(of: session?.id) { _, _ in
            focusPrimaryFieldIfNeeded(for: appModel.quickIntentSession)
        }
    }

    @ViewBuilder
    private func contextSection(
        namespace: RepositoryNamespace?,
        repository: ManagedRepository?,
        worktree: WorktreeRecord?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Kontext", detail: "Der IdeaTree wird mit dem aktuell ausgewaehlten Repository und Worktree verknuepft.")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                contextChip(title: "Namespace", value: namespace?.name ?? "Nicht ausgewaehlt", isMissing: namespace == nil)
                contextChip(title: "Repository", value: repository?.displayName ?? "Nicht ausgewaehlt", isMissing: repository == nil)
                contextChip(title: "Worktree", value: worktree?.branchName ?? "Nicht ausgewaehlt", isMissing: worktree == nil)
            }

            if repository == nil {
                Label("Waehle im Hauptfenster zuerst ein Repository aus. Danach kann das Quick Intent einen IdeaTree anlegen.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var sessionSection: some View {
        if let session = appModel.quickIntentSession {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Eingang", detail: "Pruefe Branch, Ausgangsbasis und den eigentlichen Intent, bevor du den IdeaTree erstellst.")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quelle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("\(session.source.displayName) - \(session.sourceLabel)")
                            .font(.body.weight(.medium))
                    }

                    if let hint = session.accessibilityHint {
                        Label(hint, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Branch")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("feature/kurze-zusammenfassung", text: Binding(
                            get: { appModel.quickIntentSession?.branchName ?? "" },
                            set: { appModel.quickIntentSession?.branchName = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .branch)
                    }

                    Toggle("Sub-Worktree vom aktuellen Branch ableiten", isOn: Binding(
                        get: { appModel.quickIntentSession?.useCurrentWorktreeAsParent ?? false },
                        set: { appModel.quickIntentSession?.useCurrentWorktreeAsParent = $0 }
                    ))
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Intent")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Esc schliesst das Pop-up")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        TextEditor(text: Binding(
                            get: { appModel.quickIntentSession?.text ?? "" },
                            set: { appModel.quickIntentSession?.text = $0 }
                        ))
                        .font(.body)
                        .focused($focusedField, equals: .intent)
                        .frame(minHeight: 280)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.quaternary)
                        )
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                if session.isSummarizing || session.isPerformingAction {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(session.isSummarizing ? "Intent wird zusammengefasst ..." : "IdeaTree wird vorbereitet ...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
        } else {
            ContentUnavailableView(
                "Noch kein Quick Intent",
                systemImage: "bolt.badge.clock",
                description: Text("Loese den globalen Hotkey aus oder oeffne `stackriot://quick-intent?text=...`, um den Dialog vorzufuellen.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 48)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Quick Intent", systemImage: "bolt.circle.fill")
                    .font(.title2.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                Text("Rohtext aus Auswahl, Zwischenablage oder URL direkt in einen sauberen IdeaTree ueberfuehren.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(action: closeQuickIntent) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark")
                    Text("Schliessen")
                    Text("Esc")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial, in: Capsule())
            .keyboardShortcut(.cancelAction)
            .help("Quick Intent schliessen")
        }
    }

    private func actionBar(
        canCreate: Bool,
        planningAgents: [AIAgentTool],
        executionAgents: [AIAgentTool]
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Naechster Schritt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Zusammenfassen, direkt anlegen oder sofort mit einem Agenten weiterarbeiten.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button("Zusammenfassen") {
                Task {
                    await appModel.summarizeQuickIntent()
                    focusPrimaryFieldIfNeeded(for: appModel.quickIntentSession)
                }
            }
            .disabled(appModel.quickIntentSession?.isSummarizing == true || !canCreate)

            Menu {
                if planningAgents.isEmpty {
                    Text("Keine Planungs-Agenten installiert")
                } else {
                    ForEach(planningAgents) { tool in
                        Button(tool.displayName) {
                            Task {
                                await appModel.runQuickIntentCreateAction(planningAgent: tool)
                                closeIfSessionFinished()
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
                                closeIfSessionFinished()
                            }
                        }
                    }
                }
            } label: {
                Label("Mit Agent ausfuehren", systemImage: "sparkles")
            }
            .disabled(!canCreate || executionAgents.isEmpty || appModel.quickIntentSession?.isPerformingAction == true)

            ideaTreeCreateButton(canCreate: canCreate)
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func focusPrimaryFieldIfNeeded(for session: QuickIntentSession?) {
        guard session != nil else { return }
        DispatchQueue.main.async {
            focusedField = .intent
        }
    }

    private func closeQuickIntent() {
        appModel.dismissQuickIntentSession()
        dismiss()
    }

    private func closeIfSessionFinished() {
        guard appModel.quickIntentSession == nil else { return }
        dismiss()
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
                closeIfSessionFinished()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canCreate || appModel.quickIntentSession?.isPerformingAction == true)
    }
}

struct QuickIntentWindowGeometry {
    static let minimumContentSize = CGSize(width: 760, height: 620)
    static let idealSize = CGSize(width: 860, height: 680)
    private static let screenInset: CGFloat = 48

    static func frame(in visibleFrame: CGRect) -> CGRect {
        let availableWidth = max(visibleFrame.width - (screenInset * 2), 560)
        let availableHeight = max(visibleFrame.height - (screenInset * 2), 520)
        let width = min(idealSize.width, availableWidth)
        let height = min(idealSize.height, availableHeight)
        let origin = CGPoint(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.midY - (height / 2)
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height)).integral
    }
}

private struct QuickIntentWindowAccessor: NSViewRepresentable {
    let presentationID: UUID?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            configure(window)
        }
    }

    private func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.miniaturizable)

        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap(window.standardWindowButton)
            .forEach { $0.isHidden = true }

        guard let screen = targetScreen(for: window) else { return }
        let targetFrame = QuickIntentWindowGeometry.frame(in: screen.visibleFrame)
        guard window.frame != targetFrame else { return }
        window.setFrame(targetFrame, display: true, animate: true)
    }

    private func targetScreen(for window: NSWindow) -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let hovered = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return hovered
        }
        return window.screen ?? NSScreen.main ?? NSScreen.screens.first
    }
}
