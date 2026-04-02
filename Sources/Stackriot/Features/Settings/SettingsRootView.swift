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

    @State private var isCapturingShortcut = false
    @State private var localMonitor: Any?

    private var configuration: QuickIntentHotkeyConfiguration {
        QuickIntentHotkeyConfiguration(
            isEnabled: isQuickIntentEnabled,
            keyCode: UInt16(quickIntentKeyCode),
            modifiers: QuickIntentModifierSet(rawValue: quickIntentModifiers)
        )
    }

    var body: some View {
        SettingsFormPage(category: .shortcuts) {
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
                    Button(isCapturingShortcut ? "Taste jetzt druecken…" : "Shortcut aufnehmen") {
                        if isCapturingShortcut {
                            stopCapture()
                        } else {
                            startCapture()
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
                Text("Beim globalen Trigger versucht Stackriot zuerst die aktuelle Textmarkierung aus der aktiven App zu lesen und faellt ansonsten auf die Zwischenablage zurueck.")
                Text("Fuer Markierungstext benoetigt Stackriot Bedienungshilfe-Berechtigungen unter Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen.")
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            stopCapture()
        }
    }

    private func startCapture() {
        stopCapture()
        isCapturingShortcut = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = Self.quickIntentModifiers(from: event.modifierFlags)
            guard modifiers.isEmpty == false else { return nil }
            quickIntentKeyCode = Int(event.keyCode)
            quickIntentModifiers = modifiers.rawValue
            isQuickIntentEnabled = true
            appModel.configureQuickIntentHotKey()
            stopCapture()
            return nil
        }
    }

    private func stopCapture() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        isCapturingShortcut = false
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

#Preview {
    SettingsRootView()
        .environment(AppModel())
        .modelContainer(for: StackriotModelContainer.persistentModelTypes, inMemory: true)
}
