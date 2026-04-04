import SwiftUI

struct PendingCopilotExecutionSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 16) {
            if let draft = appModel.pendingCopilotExecutionDraft {
                Text(draft.activatesTerminalTab ? draft.purpose.title : draft.purpose.backgroundTitle)
                    .font(.title3.weight(.semibold))

                Text(executionDescription(for: draft))
                    .foregroundStyle(.secondary)

                Picker("Model", selection: Binding(
                    get: { appModel.pendingCopilotExecutionDraft?.selectedCopilotModelID ?? CopilotModelOption.auto.id },
                    set: { newValue in
                        appModel.pendingCopilotExecutionDraft?.selectedCopilotModelID = newValue
                    }
                )) {
                    ForEach(draft.availableCopilotModels) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)

                if !draft.availableCopilotRepoAgents.isEmpty {
                    Picker("Agent", selection: Binding(
                        get: { appModel.pendingCopilotExecutionDraft?.selectedCopilotRepoAgentID },
                        set: { newValue in
                            appModel.pendingCopilotExecutionDraft?.selectedCopilotRepoAgentID = newValue
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
                        appModel.dismissPendingCopilotExecutionDraft()
                    }

                    Button(primaryActionTitle(for: draft)) {
                        appModel.executePendingCopilotExecution(in: modelContext)
                    }
                    .keyboardShortcut(.defaultAction)
                    .commandEnterAction {
                        appModel.executePendingCopilotExecution(in: modelContext)
                    }
                }
            } else {
                ContentUnavailableView("No Copilot Run", systemImage: "chevron.left.forwardslash.chevron.right")
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
                return "Run the current \(sourceTitle) with GitHub Copilot."
            }
            return "Run the current \(sourceTitle) with GitHub Copilot in the background while keeping the plan open."
        case .planning:
            return "Create an implementation plan from the current \(sourceTitle) with GitHub Copilot."
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
        var parts = [
            "`Auto` keeps Copilot's default routing. Selecting a concrete model adds `--model` to the run."
        ]
        if !draft.availableCopilotRepoAgents.isEmpty {
            parts.append("`Repository default` keeps the CLI default. Selecting a repo agent from `.github/agents` adds `--agent`.")
        }
        parts.append("Manage the available models in Settings > Agents & CLIs.")
        return parts.joined(separator: " ")
    }
}
