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

                if draft.isLoadingCopilotModels {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading available Copilot models...")
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage = draft.modelDiscoveryErrorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Model discovery failed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
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

                    Text("`Auto` keeps Copilot's default routing. Selecting a concrete model adds `--model` to the run.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()

                    Button("Cancel") {
                        appModel.dismissPendingCopilotExecutionDraft()
                    }

                    if draft.modelDiscoveryErrorMessage != nil {
                        Button("Retry") {
                            Task {
                                await appModel.reloadPendingCopilotExecutionModels()
                            }
                        }
                    }

                    Button(primaryActionTitle(for: draft)) {
                        appModel.executePendingCopilotExecution(in: modelContext)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.isLoadingCopilotModels || draft.modelDiscoveryErrorMessage != nil)
                }
            } else {
                ContentUnavailableView("No Copilot Run", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        .padding(20)
        .frame(width: 460)
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
}
