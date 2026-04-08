import AppKit
import SwiftUI

struct TerminalSettingsView: View {
    @AppStorage(AppPreferences.terminalTabRetentionModeKey) private var terminalTabRetentionMode = AppPreferences.defaultTerminalTabRetentionMode.rawValue
    @AppStorage(AppPreferences.externalTerminalKey) private var externalTerminalRawValue = ""

    private var availableTerminals: [SupportedExternalTerminal] {
        SupportedExternalTerminal.installedCases
    }

    private var selectedTerminal: SupportedExternalTerminal {
        if let stored = SupportedExternalTerminal(rawValue: externalTerminalRawValue),
           availableTerminals.contains(stored) {
            return stored
        }
        return AppPreferences.externalTerminal
    }

    var body: some View {
        SettingsFormPage(category: .terminal) {
            Section {
                Picker("External terminal app", selection: Binding(
                    get: { selectedTerminal },
                    set: { externalTerminalRawValue = $0.rawValue }
                )) {
                    ForEach(availableTerminals) { terminal in
                        Text(terminal.displayName).tag(terminal)
                    }
                }
            } header: {
                Text("External Terminal")
            } footer: {
                Text("Used as the default external terminal when opening repositories or worktrees from Open In context menus.")
            }

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
