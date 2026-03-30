import SwiftUI

struct JiraSettingsView: View {
    @AppStorage(AppPreferences.jiraBaseURLKey) private var jiraBaseURL = ""
    @AppStorage(AppPreferences.jiraUserEmailKey) private var jiraUserEmail = ""
    @State private var jiraAPIToken = AppPreferences.jiraAPIToken ?? ""
    @State private var status: TicketProviderStatus?
    @State private var isCheckingReadiness = false

    var body: some View {
        SettingsFormPage(category: .jira) {
            Section {
                TextField("https://your-domain.atlassian.net", text: $jiraBaseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Atlassian account email", text: $jiraUserEmail)
                    .textFieldStyle(.roundedBorder)
                SecureField("API token", text: $jiraAPIToken)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Connection")
            } footer: {
                Text("Der API-Token wird sicher im macOS-Schluesselbund gespeichert. Base URL und E-Mail bleiben in den App-Einstellungen.")
            }

            Section("Status") {
                HStack(alignment: .top, spacing: 12) {
                    if isCheckingReadiness {
                        ProgressView()
                    } else {
                        Image(systemName: status?.isAvailable == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(status?.isAvailable == true ? .green : .orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(status?.message ?? "Jira-Readiness wird geprueft …")
                            .font(.callout)
                        Text("Effektive Base URL: \(AppPreferences.jiraBaseURL.nilIfBlank ?? "nicht gesetzt")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Verbindung pruefen") {
                    Task { await refreshStatus() }
                }
                .disabled(isCheckingReadiness)
            }
        }
        .task {
            await refreshStatus()
        }
        .onChange(of: jiraBaseURL) { _, _ in
            Task { await refreshStatus() }
        }
        .onChange(of: jiraUserEmail) { _, _ in
            Task { await refreshStatus() }
        }
        .onChange(of: jiraAPIToken) { _, newValue in
            persistToken(newValue)
            Task { await refreshStatus() }
        }
    }

    @MainActor
    private func refreshStatus() async {
        isCheckingReadiness = true
        defer { isCheckingReadiness = false }
        status = await JiraCloudService().readiness(for: ManagedRepository(displayName: "Jira", remoteURL: "", bareRepositoryPath: "", defaultBranch: "main"))
    }

    private func persistToken(_ token: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            KeychainSecretStore.delete(service: KeychainSecretStore.jiraService, account: KeychainSecretStore.jiraTokenAccount)
            return
        }

        do {
            try KeychainSecretStore.storeString(trimmedToken, service: KeychainSecretStore.jiraService, account: KeychainSecretStore.jiraTokenAccount)
        } catch {
            status = TicketProviderStatus(
                provider: .jira,
                isAvailable: false,
                message: "Jira-Token konnte nicht im Schluesselbund gespeichert werden: \(error.localizedDescription)"
            )
        }
    }
}
