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
            case .copilot:
                CopilotCLISettingsView()
            case .openCode:
                OpenCodeCLISettingsView()
            }
        }
    }
}

private enum AgentCLISettingsDestination: String, CaseIterable, Identifiable {
    case copilot
    case openCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copilot:
            "GitHub Copilot"
        case .openCode:
            "OpenCode"
        }
    }
}

struct OpenCodeCLISettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Section {
            if let snapshot {
                ACPAgentSnapshotSummary(snapshot: snapshot)

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
            } else {
                Text("OpenCode did not publish ACP metadata yet.")
                    .foregroundStyle(.secondary)
            }

            Button("Refresh ACP metadata") {
                appModel.refreshLocalToolStatuses()
            }
        } header: {
            Text("OpenCode")
        } footer: {
            Text("Stackriot reads OpenCode's ACP handshake to show the live model catalog, auth hint, and advertised session modes.")
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
