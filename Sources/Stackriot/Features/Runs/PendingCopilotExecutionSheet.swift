import SwiftUI

struct PendingCopilotExecutionSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 16) {
            if let draft = appModel.pendingCopilotExecutionDraft {
                Text("Execute with GitHub Copilot")
                    .font(.title3.weight(.semibold))

                Text("Run the current \(draft.promptSourceTitle.lowercased()) with GitHub Copilot.")
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

                    Button("Execute") {
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
}
