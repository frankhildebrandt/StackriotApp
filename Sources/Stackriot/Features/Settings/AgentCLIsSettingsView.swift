import SwiftUI

struct AgentCLIsSettingsView: View {
    @State private var selectedCLI: AgentCLISettingsDestination = .copilot

    var body: some View {
        SettingsFormPage(category: .agentCLIs) {
            Section {
                Picker("CLI", selection: $selectedCLI) {
                    ForEach(AgentCLISettingsDestination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
            } footer: {
                Text("Stackriot keeps terminal-agent CLIs separate from the in-app AI provider configuration.")
            }

            switch selectedCLI {
            case .claude:
                ClaudeCLISettingsView()
            case .codex:
                CodexCLISettingsView()
            case .cursor:
                CursorCLISettingsView()
            case .copilot:
                CopilotCLISettingsView()
            case .openCode:
                OpenCodeCLISettingsView()
            }
        }
    }
}

private enum AgentCLISettingsDestination: String, CaseIterable, Identifiable {
    case claude
    case codex
    case cursor
    case copilot
    case openCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:
            "Claude Code"
        case .codex:
            "Codex"
        case .cursor:
            "Cursor"
        case .copilot:
            "GitHub Copilot"
        case .openCode:
            "OpenCode"
        }
    }
}

struct ClaudeCLISettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AgentACPMetadataSection(
            title: "Claude Code",
            snapshot: appModel.acpAgentSnapshotsByTool[.claudeCode],
            emptyStateText: "No ACP metadata available yet for Claude Code.",
            refreshAction: { appModel.refreshLocalToolStatuses() }
        ) {}
    }
}

struct CodexCLISettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AgentACPMetadataSection(
            title: "Codex",
            snapshot: appModel.acpAgentSnapshotsByTool[.codex],
            emptyStateText: "No ACP metadata available yet for Codex.",
            refreshAction: { appModel.refreshLocalToolStatuses() }
        ) {}
    }
}

struct CursorCLISettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AgentACPMetadataSection(
            title: "Cursor",
            snapshot: appModel.acpAgentSnapshotsByTool[.cursorCLI],
            emptyStateText: "No ACP metadata available yet for Cursor.",
            refreshAction: { appModel.refreshLocalToolStatuses() }
        ) {}
    }
}

struct OpenCodeCLISettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AgentACPMetadataSection(
            title: "OpenCode",
            snapshot: snapshot,
            emptyStateText: "OpenCode did not publish ACP metadata yet.",
            refreshAction: { appModel.refreshLocalToolStatuses() },
            footer: "Stackriot reads OpenCode's ACP handshake to show the live model catalog, auth hint, and advertised session modes."
        ) {
            if let modelOption {
                Picker("Default model", selection: Binding(
                    get: {
                        AppPreferences.defaultACPConfigValue(for: .openCode, configOption: modelOption)
                    },
                    set: { newValue in
                        AppPreferences.setDefaultACPConfigValue(newValue, for: .openCode, configOption: modelOption)
                    }
                )) {
                    ForEach(modelOption.flatOptions) { option in
                        Text(option.displayName).tag(option.value)
                    }
                }
            }
        }
    }

    private var snapshot: ACPAgentSnapshot? {
        appModel.acpAgentSnapshotsByTool[.openCode]
    }

    private var modelOption: ACPDiscoveredConfigOption? {
        guard let snapshot, snapshot.models.isEmpty == false else { return nil }
        let options = snapshot.models.map {
            ACPDiscoveredConfigValue(value: $0.id, displayName: $0.displayName, description: $0.description)
        }
        return ACPDiscoveredConfigOption(
            id: "model",
            displayName: "Model",
            description: "ACP-discovered OpenCode model catalog.",
            rawCategory: ACPDiscoveredConfigSemanticCategory.model.rawValue,
            currentValue: snapshot.currentModelID ?? options[0].value,
            groups: [ACPDiscoveredConfigValueGroup(groupID: nil, displayName: nil, options: options)]
        )
    }
}

private struct AgentACPMetadataSection<Content: View>: View {
    let title: String
    let snapshot: ACPAgentSnapshot?
    let emptyStateText: String
    let footer: String?
    let content: Content
    let refreshAction: () -> Void

    init(
        title: String,
        snapshot: ACPAgentSnapshot?,
        emptyStateText: String,
        refreshAction: @escaping () -> Void,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.snapshot = snapshot
        self.emptyStateText = emptyStateText
        self.footer = footer
        self.content = content()
        self.refreshAction = refreshAction
    }

    var body: some View {
        Section {
            if let snapshot {
                ACPAgentSnapshotSummary(snapshot: snapshot)
                content
            } else {
                Text(emptyStateText)
                    .foregroundStyle(.secondary)
            }

            Button("Refresh ACP metadata") {
                refreshAction()
            }
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}
