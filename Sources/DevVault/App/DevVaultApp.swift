import SwiftData
import SwiftUI

@main
struct DevVaultApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("DevVault", id: "main") {
            RootView()
                .environment(appModel)
        }
        .defaultSize(width: 1480, height: 920)
        .modelContainer(for: DevVaultModelContainer.persistentModelTypes)
        .commands {
            DevVaultAppCommands(appModel: appModel)
        }

        Settings {
            SettingsView()
                .environment(appModel)
        }
        .modelContainer(for: DevVaultModelContainer.persistentModelTypes)

        Window("About DevVault", id: "about") {
            AboutView()
        }
    }
}
