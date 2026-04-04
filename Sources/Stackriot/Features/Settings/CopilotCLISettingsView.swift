import SwiftUI

struct CopilotCLISettingsView: View {
    @State private var copilotModels: [EditableCopilotModel]
    @State private var defaultCopilotModelID: String

    init() {
        _copilotModels = State(initialValue: AppPreferences.copilotModelOptions
            .filter { !$0.isAuto }
            .map(EditableCopilotModel.init)
        )
        _defaultCopilotModelID = State(initialValue: AppPreferences.defaultCopilotModelID)
    }

    var body: some View {
        Group {
            Section {
                Picker("Default model", selection: $defaultCopilotModelID) {
                    ForEach(configuredCopilotModels) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }

                ForEach($copilotModels) { $model in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Display name", text: $model.displayName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Copilot CLI model ID", text: $model.modelID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        HStack {
                            Spacer()
                            Button(role: .destructive) {
                                removeCopilotModel(model.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Button {
                        copilotModels.append(EditableCopilotModel())
                    } label: {
                        Label("Add model", systemImage: "plus")
                    }

                    Button("Reset defaults") {
                        copilotModels = CopilotModelOption.defaultManualOptions.map(EditableCopilotModel.init)
                        defaultCopilotModelID = CopilotModelOption.auto.id
                        persistCopilotModelSettings()
                    }
                }
            } header: {
                Text("GitHub Copilot")
            } footer: {
                Text("`Auto` is always available. Add the Copilot CLI model IDs you want Stackriot to offer and choose which one should be preselected for new runs. Repo agents from `.github/agents` appear directly in the run sheet.")
            }
        }
        .onChange(of: copilotModels) { _, _ in
            persistCopilotModelSettings()
        }
        .onChange(of: defaultCopilotModelID) { _, _ in
            persistCopilotModelSettings()
        }
    }

    private var configuredCopilotModels: [CopilotModelOption] {
        AppPreferences.normalizedCopilotModelOptions(
            from: copilotModels.map {
                CopilotModelOption(
                    id: $0.modelID,
                    displayName: $0.displayName,
                    isAuto: false
                )
            }
        )
    }

    private func persistCopilotModelSettings() {
        let normalizedModels = configuredCopilotModels
        let validatedDefault = AppPreferences.validatedCopilotModelID(
            defaultCopilotModelID,
            availableModels: normalizedModels
        )

        AppPreferences.setCopilotModelOptions(normalizedModels)
        AppPreferences.setDefaultCopilotModelID(validatedDefault)

        if defaultCopilotModelID != validatedDefault {
            defaultCopilotModelID = validatedDefault
        }
    }

    private func removeCopilotModel(_ rowID: UUID) {
        copilotModels.removeAll { $0.id == rowID }
    }
}

private struct EditableCopilotModel: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var modelID: String

    init(id: UUID = UUID(), displayName: String = "", modelID: String = "") {
        self.id = id
        self.displayName = displayName
        self.modelID = modelID
    }

    init(_ option: CopilotModelOption) {
        self.init(displayName: option.displayName, modelID: option.id)
    }
}
