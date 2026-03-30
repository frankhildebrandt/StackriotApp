import SwiftUI

struct RepositoriesSettingsView: View {
    @AppStorage(AppPreferences.autoRefreshEnabledKey) private var autoRefreshEnabled = AppPreferences.defaultAutoRefreshEnabled
    @AppStorage(AppPreferences.autoRefreshIntervalKey) private var autoRefreshInterval = AppPreferences.defaultAutoRefreshInterval
    @AppStorage(AppPreferences.worktreeStatusPollingEnabledKey) private var worktreeStatusPollingEnabled =
        AppPreferences.defaultWorktreeStatusPollingEnabled
    @AppStorage(AppPreferences.worktreeStatusPollingIntervalKey) private var worktreeStatusPollingInterval =
        AppPreferences.defaultWorktreeStatusPollingInterval

    var body: some View {
        SettingsFormPage(category: .repositories) {
            Section {
                Toggle("Automatically refresh repositories", isOn: $autoRefreshEnabled)
                Picker("Refresh interval", selection: $autoRefreshInterval) {
                    Text("Every 5 minutes").tag(300.0)
                    Text("Every 15 minutes").tag(900.0)
                    Text("Every hour").tag(3600.0)
                }
            } header: {
                Text("Remote refresh")
            } footer: {
                Text("Fetches from remotes and syncs default-branch worktrees. Runs in the background on the interval above.")
            }

            Section {
                Toggle("Poll worktree status for selected repository", isOn: $worktreeStatusPollingEnabled)
                Picker("Status interval", selection: $worktreeStatusPollingInterval) {
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every minute").tag(60.0)
                    Text("Every 2 minutes").tag(120.0)
                    Text("Every 5 minutes").tag(300.0)
                    Text("Every 15 minutes").tag(900.0)
                }
                .disabled(!worktreeStatusPollingEnabled)
            } header: {
                Text("Worktree status (local)")
            } footer: {
                Text("Updates ahead/behind, uncommitted line counts, and PR upstream for the currently selected repository only. Does not run git fetch; use Remote refresh for that.")
            }

            Section {
                LabeledContent("Working mode", value: "Bare repositories + worktrees")
            } header: {
                Text("Repository workflow")
            } footer: {
                Text("Stackriot stores shared Git data in a bare repository and creates worktrees for active tasks.")
            }
        }
    }
}
