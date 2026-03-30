import SwiftUI

struct TerminalSettingsView: View {
    @AppStorage(AppPreferences.terminalTabRetentionModeKey) private var terminalTabRetentionMode = AppPreferences.defaultTerminalTabRetentionMode.rawValue

    var body: some View {
        SettingsFormPage(category: .terminal) {
            Section {
                Picker("Completed tab retention", selection: $terminalTabRetentionMode) {
                    ForEach(TerminalTabRetentionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
            } header: {
                Text("Tabs")
            } footer: {
                Text("Choose whether completed tabs disappear quickly, stay open until you close them, or only remain while they are still running.")
            }
        }
    }
}
