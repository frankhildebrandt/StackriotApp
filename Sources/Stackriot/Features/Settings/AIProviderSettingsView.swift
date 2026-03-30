import SwiftUI

struct AIProviderSettingsView: View {
    @AppStorage(AppPreferences.aiProviderKey) private var aiProvider = AppPreferences.defaultAIProvider.rawValue
    @AppStorage(AppPreferences.aiAPIKeyKey) private var aiAPIKey = ""
    @AppStorage(AppPreferences.aiBaseURLKey) private var aiBaseURL = ""
    @AppStorage(AppPreferences.aiModelKey) private var aiModel = ""

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

            Section("Effective configuration") {
                LabeledContent("Effective model", value: AppPreferences.aiModel)
                LabeledContent("Effective base URL", value: AppPreferences.aiBaseURL)
                LabeledContent("Configuration status", value: configurationStatus)
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
}
