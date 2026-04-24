import AppKit
import SwiftUI

struct SettingsRootView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(AppPreferences.selectedSettingsCategoryKey) private var selectedCategoryRawValue = SettingsCategory.defaultCategory.rawValue

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: selection) { category in
                Label(category.title, systemImage: category.symbolName)
                    .tag(category)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 260)
            .listStyle(.sidebar)
        } detail: {
            switch selectedCategory {
            case .repositories:
                RepositoriesSettingsView()
            case .shortcuts:
                ShortcutsSettingsView()
            case .terminal:
                TerminalSettingsView()
            case .devContainers:
                DevContainerSettingsView()
            case .node:
                NodeSettingsView()
            case .agentCLIs:
                AgentCLIsSettingsView()
            case .aiProvider:
                AIProviderSettingsView()
            case .browserSessions:
                BrowserSessionsSettingsView()
            case .jira:
                JiraSettingsView()
            case .mcp:
                MCPSettingsView()
            case .sshKeys:
                SSHKeysSettingsView()
            case .about:
                AboutSettingsView()
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    private var selectedCategory: SettingsCategory {
        SettingsCategory(rawValue: selectedCategoryRawValue) ?? .defaultCategory
    }

    private var selection: Binding<SettingsCategory?> {
        Binding {
            selectedCategory
        } set: { newValue in
            selectedCategoryRawValue = newValue?.rawValue ?? SettingsCategory.defaultCategory.rawValue
        }
    }
}

private struct ShortcutsSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(AppPreferences.quickIntentHotkeyEnabledKey) private var isQuickIntentEnabled = AppPreferences.defaultQuickIntentHotkey.isEnabled
    @AppStorage(AppPreferences.quickIntentHotkeyKeyCodeKey) private var quickIntentKeyCode = Int(AppPreferences.defaultQuickIntentHotkey.keyCode)
    @AppStorage(AppPreferences.quickIntentHotkeyModifiersKey) private var quickIntentModifiers = AppPreferences.defaultQuickIntentHotkey.modifiers.rawValue
    @AppStorage(AppPreferences.commandBarHotkeyEnabledKey) private var isCommandBarEnabled = AppPreferences.defaultCommandBarHotkey.isEnabled
    @AppStorage(AppPreferences.commandBarHotkeyKeyCodeKey) private var commandBarKeyCode = Int(AppPreferences.defaultCommandBarHotkey.keyCode)
    @AppStorage(AppPreferences.commandBarHotkeyModifiersKey) private var commandBarModifiers = AppPreferences.defaultCommandBarHotkey.modifiers.rawValue

    @State private var capturingTarget: ShortcutCaptureTarget?
    @State private var localMonitor: Any?

    private var configuration: QuickIntentHotkeyConfiguration {
        QuickIntentHotkeyConfiguration(
            isEnabled: isQuickIntentEnabled,
            keyCode: UInt16(quickIntentKeyCode),
            modifiers: QuickIntentModifierSet(rawValue: quickIntentModifiers)
        )
    }

    private var commandBarConfiguration: GlobalHotKeyConfiguration {
        GlobalHotKeyConfiguration(
            isEnabled: isCommandBarEnabled,
            keyCode: UInt16(commandBarKeyCode),
            modifiers: QuickIntentModifierSet(rawValue: commandBarModifiers)
        )
    }

    var body: some View {
        SettingsFormPage(category: .shortcuts) {
            Section("CommandBar") {
                Toggle("Globalen Hotkey aktivieren", isOn: $isCommandBarEnabled)
                    .onChange(of: isCommandBarEnabled) { _, _ in
                        appModel.configureCommandBarHotKey()
                    }

                LabeledContent("Aktueller Shortcut") {
                    Text(commandBarConfiguration.displayString)
                        .font(.system(.body, design: .monospaced))
                }

                HStack {
                    Button(capturingTarget == .commandBar ? "Taste jetzt druecken…" : "Shortcut aufnehmen") {
                        if capturingTarget == .commandBar {
                            stopCapture()
                        } else {
                            startCapture(.commandBar)
                        }
                    }

                    Button("Auf Standard") {
                        let defaults = AppPreferences.defaultCommandBarHotkey
                        isCommandBarEnabled = defaults.isEnabled
                        commandBarKeyCode = Int(defaults.keyCode)
                        commandBarModifiers = defaults.modifiers.rawValue
                        appModel.configureCommandBarHotKey()
                    }
                }

                Text("Der globale CommandBar-Hotkey oeffnet eine kontextabhaengige Suche fuer Run Targets, Repository-Aktionen und schnelle Navigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quick Intent") {
                Toggle("Globalen Hotkey aktivieren", isOn: $isQuickIntentEnabled)
                    .onChange(of: isQuickIntentEnabled) { _, _ in
                        appModel.configureQuickIntentHotKey()
                    }

                LabeledContent("Aktueller Shortcut") {
                    Text(configuration.displayString)
                        .font(.system(.body, design: .monospaced))
                }

                HStack {
                    Button(capturingTarget == .quickIntent ? "Taste jetzt druecken…" : "Shortcut aufnehmen") {
                        if capturingTarget == .quickIntent {
                            stopCapture()
                        } else {
                            startCapture(.quickIntent)
                        }
                    }

                    Button("Auf Standard") {
                        let defaults = AppPreferences.defaultQuickIntentHotkey
                        isQuickIntentEnabled = defaults.isEnabled
                        quickIntentKeyCode = Int(defaults.keyCode)
                        quickIntentModifiers = defaults.modifiers.rawValue
                        appModel.configureQuickIntentHotKey()
                    }
                }

                Text("Tipp: Waehle einen Shortcut, der nicht mit globalen macOS-Kurzbefehlen kollidiert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Kontextquellen") {
                Text("Die CommandBar versucht zuerst, den frontmost Cursor-Workspace einem Stackriot-Worktree zuzuordnen, und faellt danach auf die aktuelle Stackriot-Auswahl zurueck.")
                Text("Quick Intent liest beim globalen Trigger zuerst die aktuelle Textmarkierung aus der aktiven App und faellt ansonsten auf die Zwischenablage zurueck.")
                Text("Fuer Markierungstext und bessere Fenster-Kontexterkennung benoetigt Stackriot Bedienungshilfe-Berechtigungen unter Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen.")
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            stopCapture()
        }
    }

    private func startCapture(_ target: ShortcutCaptureTarget) {
        stopCapture()
        capturingTarget = target
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = Self.quickIntentModifiers(from: event.modifierFlags)
            guard modifiers.isEmpty == false else { return nil }
            switch target {
            case .quickIntent:
                quickIntentKeyCode = Int(event.keyCode)
                quickIntentModifiers = modifiers.rawValue
                isQuickIntentEnabled = true
                appModel.configureQuickIntentHotKey()
            case .commandBar:
                commandBarKeyCode = Int(event.keyCode)
                commandBarModifiers = modifiers.rawValue
                isCommandBarEnabled = true
                appModel.configureCommandBarHotKey()
            }
            stopCapture()
            return nil
        }
    }

    private func stopCapture() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        capturingTarget = nil
    }

    private static func quickIntentModifiers(from flags: NSEvent.ModifierFlags) -> QuickIntentModifierSet {
        var modifiers: QuickIntentModifierSet = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

private enum ShortcutCaptureTarget {
    case quickIntent
    case commandBar
}

#Preview {
    SettingsRootView()
        .environment(AppModel())
        .modelContainer(for: StackriotModelContainer.persistentModelTypes, inMemory: true)
}
