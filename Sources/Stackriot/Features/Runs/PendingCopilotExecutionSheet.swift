import SwiftUI

struct PendingAgentExecutionSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 16) {
            if let draft = appModel.pendingAgentExecutionDraft {
                Text(draft.activatesTerminalTab ? draft.purpose.title(for: draft.tool) : draft.purpose.backgroundTitle(for: draft.tool))
                    .font(.title3.weight(.semibold))

                Text(executionDescription(for: draft))
                    .foregroundStyle(.secondary)

                if draft.purpose == .execution, !draft.availableModes.isEmpty {
                    Picker("Mode", selection: Binding(
                        get: { appModel.pendingAgentExecutionDraft?.selectedModeID },
                        set: { newValue in
                            appModel.pendingAgentExecutionDraft?.selectedModeID = newValue
                        }
                    )) {
                        ForEach(draft.availableModes) { mode in
                            Text(mode.displayName).tag(Optional(mode.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                ForEach(draft.availableConfigOptions) { option in
                    Picker(option.displayName, selection: Binding(
                        get: { appModel.pendingAgentExecutionDraft?.selectedConfigValues[option.id] ?? option.currentValue },
                        set: { newValue in
                            appModel.pendingAgentExecutionDraft?.selectedConfigValues[option.id] = newValue
                        }
                    )) {
                        ForEach(option.flatOptions) { value in
                            Text(value.displayName).tag(value.value)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if !draft.availableCopilotRepoAgents.isEmpty {
                    Picker("Agent", selection: Binding(
                        get: { appModel.pendingAgentExecutionDraft?.selectedCopilotRepoAgentID },
                        set: { newValue in
                            appModel.pendingAgentExecutionDraft?.selectedCopilotRepoAgentID = newValue
                        }
                    )) {
                        Text("Repository default").tag(Optional<String>.none)
                        ForEach(draft.availableCopilotRepoAgents) { agent in
                            Text(agent.displayName).tag(Optional(agent.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Text(configurationFootnote(for: draft))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()

                    Button("Cancel") {
                        appModel.dismissPendingAgentExecutionDraft()
                    }

                    Button(primaryActionTitle(for: draft)) {
                        appModel.executePendingAgentExecution(in: modelContext)
                    }
                    .keyboardShortcut(.defaultAction)
                    .commandEnterAction {
                        appModel.executePendingAgentExecution(in: modelContext)
                    }
                }
            } else {
                ContentUnavailableView("No Agent Run", systemImage: "sparkles")
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func executionDescription(for draft: PendingAgentExecutionDraft) -> String {
        let sourceTitle = draft.promptSourceTitle.lowercased()
        switch draft.purpose {
        case .execution:
            if draft.activatesTerminalTab {
                return "Run the current \(sourceTitle) with \(draft.tool.displayName)."
            }
            return "Run the current \(sourceTitle) with \(draft.tool.displayName) in the background while keeping the plan open."
        case .planning:
            return "Create an implementation plan from the current \(sourceTitle) with \(draft.tool.displayName)."
        }
    }

    private func primaryActionTitle(for draft: PendingAgentExecutionDraft) -> String {
        switch draft.purpose {
        case .execution:
            draft.activatesTerminalTab ? "Execute" : "Send to Background"
        case .planning:
            "Create Plan"
        }
    }

    private func configurationFootnote(for draft: PendingAgentExecutionDraft) -> String {
        var parts: [String] = []
        if draft.availableConfigOptions.contains(where: { $0.id == "model" }) && draft.tool == .githubCopilot {
            parts.append("`Auto` keeps Copilot's default routing. Selecting a concrete model adds `--model` to the run.")
        }
        if draft.availableConfigOptions.contains(where: { $0.semanticCategory == .thoughtLevel || $0.id == "reasoning_effort" }) {
            parts.append("Reasoning effort is discovered via ACP and maps to the CLI's effort flag when supported.")
        }
        if !draft.availableModes.isEmpty {
            parts.append("Available modes are discovered via ACP and only launchable modes are offered here.")
        }
        if !draft.availableCopilotRepoAgents.isEmpty {
            parts.append("`Repository default` keeps the CLI default. Selecting a repo agent from `.github/agents` adds `--agent`.")
        }
        parts.append("Discovered models, modes, and capabilities are shown in Settings > Agents & CLIs.")
        return parts.joined(separator: " ")
    }
}
