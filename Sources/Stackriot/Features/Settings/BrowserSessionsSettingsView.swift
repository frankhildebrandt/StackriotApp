import SwiftUI

struct BrowserSessionsSettingsView: View {
    @State private var authProvider: TicketProviderKind?
    @State private var clearingProvider: TicketProviderKind?

    var body: some View {
        SettingsFormPage(category: .browserSessions) {
            providerSection(.github)
            providerSection(.jira)
        }
        .sheet(item: $authProvider) { provider in
            EmbeddedBrowserAuthenticationSheet(provider: provider)
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: TicketProviderKind) -> some View {
        Section {
            Text("Persistent WebKit cookies created here are reused by PR and ticket primary-context tabs.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Sign In / Re-Auth") {
                    authProvider = provider
                }

                Button("Clear Session", role: .destructive) {
                    clearingProvider = provider
                    Task {
                        await EmbeddedBrowserSessionStore.clearSession(for: provider)
                        clearingProvider = nil
                    }
                }
                .disabled(clearingProvider == provider)

                if clearingProvider == provider {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } header: {
            Text(EmbeddedBrowserSessionStore.providerDisplayName(provider))
        } footer: {
            Text(provider == .github
                ? "`gh auth` remains separate and is still used for CLI flows."
                : "Jira API credentials remain separate and are still used for ticket search and plan generation.")
        }
    }
}
