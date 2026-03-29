import SwiftData
import SwiftUI

@main
struct StackriotApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("Stackriot", id: "main") {
            RootView()
                .environment(appModel)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task {
                        await appModel.refreshAllRepositories(force: true)
                    }
                }
        }
        .defaultSize(width: 1480, height: 920)
        .modelContainer(for: StackriotModelContainer.persistentModelTypes)
        .commands {
            StackriotAppCommands(appModel: appModel)
        }

        Settings {
            SettingsView()
                .environment(appModel)
        }
        .modelContainer(for: StackriotModelContainer.persistentModelTypes)

        Window("About Stackriot", id: "about") {
            AboutView()
        }
    }
}
