import AppKit
import SwiftUI

struct RepositoriesSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(AppPreferences.autoRefreshEnabledKey) private var autoRefreshEnabled = AppPreferences.defaultAutoRefreshEnabled
    @AppStorage(AppPreferences.autoRefreshIntervalKey) private var autoRefreshInterval = AppPreferences.defaultAutoRefreshInterval
    @AppStorage(AppPreferences.worktreeStatusPollingEnabledKey) private var worktreeStatusPollingEnabled =
        AppPreferences.defaultWorktreeStatusPollingEnabled
    @AppStorage(AppPreferences.worktreeStatusPollingIntervalKey) private var worktreeStatusPollingInterval =
        AppPreferences.defaultWorktreeStatusPollingInterval
    @AppStorage(AppPreferences.performanceDebugModeEnabledKey) private var performanceDebugModeEnabled =
        AppPreferences.defaultPerformanceDebugModeEnabled
    @AppStorage(AppPreferences.repositoriesRootLocationKey) private var repositoriesRootLocationRawValue =
        AppPreferences.defaultPathLocation.rawValue
    @AppStorage(AppPreferences.repositoriesRootCustomPathKey) private var repositoriesRootCustomPath = ""
    @AppStorage(AppPreferences.worktreesRootLocationKey) private var worktreesRootLocationRawValue =
        AppPreferences.defaultPathLocation.rawValue
    @AppStorage(AppPreferences.worktreesRootCustomPathKey) private var worktreesRootCustomPath = ""

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

            Section {
                Picker("Repositories", selection: repositoriesRootLocationBinding) {
                    ForEach(AppPathLocation.allCases) { location in
                        Text(location.displayName).tag(location)
                    }
                }

                LabeledContent("Effective path") {
                    settingsPathValue(AppPaths.bareRepositoriesRoot.path)
                }

                if repositoriesRootLocation == .custom {
                    LabeledContent("Custom folder") {
                        settingsPathValue(repositoriesRootCustomPath.nonEmpty ?? "No folder selected")
                    }

                    HStack {
                        Button("Choose folder") {
                            chooseRepositoriesRoot()
                        }

                        Button("Show in Finder") {
                            revealInFinder(AppPaths.bareRepositoriesRoot)
                        }
                    }
                }
            } header: {
                Text("Default repository path")
            } footer: {
                Text("New bare repositories are created under the effective path above. Stackriot keeps them inside a `Repositories` subfolder in the selected base folder.")
            }

            Section {
                Picker("Worktrees", selection: worktreesRootLocationBinding) {
                    ForEach(AppPathLocation.allCases) { location in
                        Text(location.displayName).tag(location)
                    }
                }

                LabeledContent("Effective path") {
                    settingsPathValue(AppPaths.worktreesRoot.path)
                }

                if worktreesRootLocation == .custom {
                    LabeledContent("Custom folder") {
                        settingsPathValue(worktreesRootCustomPath.nonEmpty ?? "No folder selected")
                    }

                    HStack {
                        Button("Choose folder") {
                            chooseWorktreesRoot()
                        }

                        Button("Show in Finder") {
                            revealInFinder(AppPaths.worktreesRoot)
                        }
                    }
                }
            } header: {
                Text("Default worktree path")
            } footer: {
                Text("New default-branch workspaces and new worktrees use this location unless you override the destination for an individual worktree.")
            }

            Section {
                Toggle("Enable performance debug artifact", isOn: $performanceDebugModeEnabled)
                LabeledContent("Artifact file") {
                    Text(appModel.performanceDebugArtifactURL().path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Show in Finder") {
                        Task {
                            await appModel.revealPerformanceDebugArtifact()
                        }
                    }

                    Button("Copy artifact") {
                        appModel.copyPerformanceDebugArtifactToPasteboard()
                    }

                    Button("Clear artifact") {
                        appModel.clearPerformanceDebugArtifact()
                    }
                }
            } header: {
                Text("Performance debug")
            } footer: {
                Text("Enable this, reproduce the slow repository or worktree switch, then send the JSONL artifact file for analysis.")
            }
        }
    }

    private var repositoriesRootLocation: AppPathLocation {
        AppPathLocation(rawValue: repositoriesRootLocationRawValue) ?? AppPreferences.defaultPathLocation
    }

    private var worktreesRootLocation: AppPathLocation {
        AppPathLocation(rawValue: worktreesRootLocationRawValue) ?? AppPreferences.defaultPathLocation
    }

    private var repositoriesRootLocationBinding: Binding<AppPathLocation> {
        Binding(
            get: { repositoriesRootLocation },
            set: { repositoriesRootLocationRawValue = $0.rawValue }
        )
    }

    private var worktreesRootLocationBinding: Binding<AppPathLocation> {
        Binding(
            get: { worktreesRootLocation },
            set: { worktreesRootLocationRawValue = $0.rawValue }
        )
    }

    @ViewBuilder
    private func settingsPathValue(_ value: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private func chooseRepositoriesRoot() {
        let initialDirectory = AppPreferences.repositoriesRootCustomPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppPaths.repositoriesBaseDirectory
        guard let selectedDirectory = IDEManager.chooseDirectory(
            title: "Choose repository base folder",
            message: "Stackriot creates the Repositories subfolder inside this location.",
            prompt: "Choose",
            initialDirectory: initialDirectory
        ) else {
            return
        }
        repositoriesRootLocationRawValue = AppPathLocation.custom.rawValue
        repositoriesRootCustomPath = selectedDirectory.path
    }

    private func chooseWorktreesRoot() {
        let initialDirectory = AppPreferences.worktreesRootCustomPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppPaths.worktreesBaseDirectory
        guard let selectedDirectory = IDEManager.chooseDirectory(
            title: "Choose worktree base folder",
            message: "Stackriot creates the Worktrees subfolder inside this location.",
            prompt: "Choose",
            initialDirectory: initialDirectory
        ) else {
            return
        }
        worktreesRootLocationRawValue = AppPathLocation.custom.rawValue
        worktreesRootCustomPath = selectedDirectory.path
    }

    private func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
