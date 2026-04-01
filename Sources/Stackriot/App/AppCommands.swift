import SwiftUI

struct StackriotAppCommands: Commands {
    @Bindable var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("About Stackriot") {
                openWindow(id: "about")
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("Quick Intent") {
                appModel.presentQuickIntentFromSystemTrigger()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Button("Clone Bare Repository") {
                appModel.presentCloneSheet()
            }
            .keyboardShortcut("n")

            Button("Create Worktree") {
                appModel.presentWorktreeSheetForSelection()
            }
            .keyboardShortcut("t")

            Divider()

            SettingsLink {
                Text("Settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Repositories") {
            Button("Quick Intent") {
                appModel.presentQuickIntentFromSystemTrigger()
            }
            .keyboardShortcut("i", modifiers: [.command, .option, .shift])

            Divider()

            Button("Clone Bare Repository") {
                appModel.presentCloneSheet()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Create Worktree") {
                appModel.presentWorktreeSheetForSelection()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Divider()

            Button("Refresh Selected Repository") {
                appModel.refreshSelectedRepository()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu("Window") {
            Button("Show Main Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("RAW Logs") {
                openWindow(id: "raw-logs")
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button("Quick Intent") {
                openWindow(id: "quick-intent")
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button("Show About") {
                openWindow(id: "about")
            }
        }
    }
}
