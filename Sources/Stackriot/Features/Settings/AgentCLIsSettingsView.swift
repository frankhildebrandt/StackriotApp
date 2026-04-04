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
            }
        }
    }
}

private enum AgentCLISettingsDestination: String, CaseIterable, Identifiable {
    case copilot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copilot:
            "GitHub Copilot"
        }
    }
}
