import SwiftUI

struct SettingsRootView: View {
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
            case .terminal:
                TerminalSettingsView()
            case .node:
                NodeSettingsView()
            case .aiProvider:
                AIProviderSettingsView()
            case .jira:
                JiraSettingsView()
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

#Preview {
    SettingsRootView()
        .environment(AppModel())
        .modelContainer(for: StackriotModelContainer.persistentModelTypes, inMemory: true)
}
