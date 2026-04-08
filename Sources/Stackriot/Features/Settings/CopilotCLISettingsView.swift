import SwiftUI

struct CopilotCLISettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Section {
            if let snapshot {
                ACPAgentSnapshotSummary(snapshot: snapshot)

                if let modelOption {
                    Picker("Default model", selection: Binding(
                        get: {
                            AppPreferences.defaultACPConfigValue(
                                for: .githubCopilot,
                                configOption: modelOption,
                                fallbackValue: AppPreferences.defaultCopilotModelID
                            )
                        },
                        set: { newValue in
                            AppPreferences.setDefaultACPConfigValue(newValue, for: .githubCopilot, configOption: modelOption)
                            AppPreferences.setDefaultCopilotModelID(newValue)
                        }
                    )) {
                        ForEach(modelOption.flatOptions) { option in
                            Text(option.displayName).tag(option.value)
                        }
                    }
                }

                if let reasoningOption {
                    Picker("Default reasoning effort", selection: Binding(
                        get: {
                            AppPreferences.defaultACPConfigValue(for: .githubCopilot, configOption: reasoningOption)
                        },
                        set: { newValue in
                            AppPreferences.setDefaultACPConfigValue(newValue, for: .githubCopilot, configOption: reasoningOption)
                        }
                    )) {
                        ForEach(reasoningOption.flatOptions) { option in
                            Text(option.displayName).tag(option.value)
                        }
                    }
                }
            } else {
                Text("No ACP metadata available yet.")
                    .foregroundStyle(.secondary)
            }

            Button("Refresh ACP metadata") {
                appModel.refreshLocalToolStatuses()
            }
        } header: {
            Text("GitHub Copilot")
        } footer: {
            Text("When Copilot exposes ACP metadata, Stackriot uses it to show live models, modes, auth hints, and other session configuration surfaced by the CLI.")
        }
    }

    private var snapshot: ACPAgentSnapshot? {
        appModel.acpAgentSnapshotsByTool[.githubCopilot]
    }

    private var modelOption: ACPDiscoveredConfigOption? {
        snapshot?.configOptions.first(where: { $0.id == "model" || $0.semanticCategory == .model }).map { option in
            let autoOption = ACPDiscoveredConfigValue(value: CopilotModelOption.auto.id, displayName: CopilotModelOption.auto.displayName, description: nil)
            let options = ([autoOption] + option.flatOptions).reduce(into: [ACPDiscoveredConfigValue]()) { partialResult, candidate in
                if partialResult.contains(where: { $0.value == candidate.value }) == false {
                    partialResult.append(candidate)
                }
            }
            return ACPDiscoveredConfigOption(
                id: "model",
                displayName: option.displayName,
                description: option.description,
                rawCategory: ACPDiscoveredConfigSemanticCategory.model.rawValue,
                currentValue: option.currentValue,
                groups: [ACPDiscoveredConfigValueGroup(groupID: nil, displayName: nil, options: options)]
            )
        }
    }

    private var reasoningOption: ACPDiscoveredConfigOption? {
        snapshot?.configOptions.first {
            $0.id == "reasoning_effort" || $0.semanticCategory == .thoughtLevel
        }
    }
}

struct ACPAgentSnapshotSummary: View {
    let snapshot: ACPAgentSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agentInfo = snapshot.agentInfo {
                LabeledContent("Version") {
                    Text(agentInfo.version ?? "Unknown")
                }
            }

            if snapshot.authMethods.isEmpty == false {
                LabeledContent("Auth") {
                    Text(snapshot.authMethods.map(\.name).joined(separator: ", "))
                }
            }

            if snapshot.modes.isEmpty == false {
                LabeledContent("ACP modes") {
                    Text(snapshot.modes.map(\.displayName).joined(separator: ", "))
                }
            }

            let capabilitySummary = [
                snapshot.loadSession ? "load-session" : nil,
                snapshot.supportsSessionList ? "session-list" : nil,
                snapshot.promptSupportsEmbeddedContext ? "embedded-context" : nil,
                snapshot.promptSupportsImage ? "image-prompts" : nil,
                snapshot.mcpSupportsHTTP ? "mcp-http" : nil,
                snapshot.mcpSupportsSSE ? "mcp-sse" : nil,
            ].compactMap { $0 }

            if capabilitySummary.isEmpty == false {
                LabeledContent("Capabilities") {
                    Text(capabilitySummary.joined(separator: ", "))
                }
            }
        }
        .font(.callout)
    }
}
