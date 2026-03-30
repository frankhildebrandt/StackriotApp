import SwiftData
import SwiftUI

@main
struct StackriotApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("Stackriot", id: "main") {
            RootView()
                .environment(appModel)
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
