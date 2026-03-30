import SwiftUI

struct RepositoriesSettingsView: View {
    @AppStorage(AppPreferences.autoRefreshEnabledKey) private var autoRefreshEnabled = AppPreferences.defaultAutoRefreshEnabled
    @AppStorage(AppPreferences.autoRefreshIntervalKey) private var autoRefreshInterval = AppPreferences.defaultAutoRefreshInterval

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
                Text("Refresh")
            } footer: {
                Text("Background refresh keeps repository status current without interrupting focused work.")
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
