import SwiftUI

struct AIProviderSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(AppPreferences.aiProviderKey) private var aiProvider = AppPreferences.defaultAIProvider.rawValue
    @AppStorage(AppPreferences.aiAPIKeyKey) private var aiAPIKey = ""
    @AppStorage(AppPreferences.aiBaseURLKey) private var aiBaseURL = ""
    @AppStorage(AppPreferences.aiModelKey) private var aiModel = ""

    @State private var isVerifyingConfiguration = false
    @State private var configurationVerifySuccess: String?
    @State private var configurationVerifyError: String?

    var body: some View {
        SettingsFormPage(category: .aiProvider) {
            Section {
                Picker("Provider", selection: $aiProvider) {
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }

                LabeledContent("Connection type") {
                    Label(providerModeTitle, systemImage: providerModeSymbol)
                        .foregroundStyle(providerModeColor)
                }

                LabeledContent("API key") {
                    Text(selectedAIProvider.requiresAPIKey ? "Required" : "Optional")
                }
            } header: {
                Text("Provider")
            } footer: {
                Text(providerFootnote)
            }

            Section {
                SecureField(selectedAIProvider.requiresAPIKey ? "API key" : "API key (optional)", text: $aiAPIKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $aiModel, prompt: Text(selectedAIProvider.defaultModel))
                    .textFieldStyle(.roundedBorder)
                TextField("Base URL", text: $aiBaseURL, prompt: Text(selectedAIProvider.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Credentials and overrides")
            } footer: {
                Text("Leave the model or base URL empty to keep the provider default. Local providers usually only need a reachable endpoint.")
            }

            Section {
                LabeledContent("Effective model", value: AppPreferences.aiModel)
                LabeledContent("Effective base URL", value: AppPreferences.aiBaseURL)
                LabeledContent("Configuration status", value: configurationStatus)

                HStack(alignment: .center, spacing: 10) {
                    Button {
                        runConfigurationCheck()
                    } label: {
                        HStack(spacing: 6) {
                            if isVerifyingConfiguration {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.circle")
                            }
                            Text("Konfiguration pruefen")
                        }
                    }
                    .disabled(isVerifyingConfiguration)

                    if let configurationVerifySuccess {
                        Text(configurationVerifySuccess)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let configurationVerifyError {
                        Text(configurationVerifyError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Effective configuration")
            } footer: {
                Text("Sendet eine minimale Chat-Anfrage mit dem gewaehlten Provider, Modell und der Basis-URL.")
            }
        }
    }

    private var selectedAIProvider: AIProviderKind {
        AIProviderKind(rawValue: aiProvider) ?? AppPreferences.defaultAIProvider
    }

    private var providerModeTitle: String {
        selectedAIProvider.requiresAPIKey ? "Remote provider" : "Local provider"
    }

    private var providerModeSymbol: String {
        selectedAIProvider.requiresAPIKey ? "network" : "desktopcomputer"
    }

    private var providerModeColor: Color {
        selectedAIProvider.requiresAPIKey ? .accentColor : .secondary
    }

    private var providerFootnote: String {
        if selectedAIProvider.requiresAPIKey {
            return "Remote providers send requests over the network and require a valid API key before Stackriot can use them."
        }
        return "Local providers run on your machine or local network. An API key can stay empty unless your endpoint expects one."
    }

    private var configurationStatus: String {
        if selectedAIProvider.requiresAPIKey, AppPreferences.aiAPIKey == nil {
            return "API key missing"
        }
        return selectedAIProvider.requiresAPIKey ? "Ready for remote requests" : "Ready for local requests"
    }

    /// Values as shown in the form (AppStorage is live while the settings window is open).
    private var formAIConfiguration: AIProviderConfiguration {
        let key = aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let trimmedModel = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBase = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIProviderConfiguration(
            provider: selectedAIProvider,
            apiKey: key,
            model: trimmedModel.nonEmpty ?? selectedAIProvider.defaultModel,
            baseURL: trimmedBase.nonEmpty ?? selectedAIProvider.defaultBaseURL
        )
    }

    private func runConfigurationCheck() {
        configurationVerifySuccess = nil
        configurationVerifyError = nil
        isVerifyingConfiguration = true
        let configuration = formAIConfiguration
        let service = appModel.services.aiProviderService
        Task {
            do {
                try await service.verifyConfiguration(configuration)
                await MainActor.run {
                    configurationVerifySuccess = "Verbindung OK."
                    isVerifyingConfiguration = false
                }
            } catch {
                await MainActor.run {
                    configurationVerifyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isVerifyingConfiguration = false
                }
            }
        }
    }
}
