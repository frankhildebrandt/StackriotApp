import SwiftUI

struct DevContainerSettingsView: View {
    @Environment(AppModel.self) private var appModel

    @AppStorage(AppPreferences.devContainerEnabledKey) private var devContainerEnabled = AppPreferences.defaultDevContainerEnabled
    @AppStorage(AppPreferences.devContainerCLIStrategyKey) private var cliStrategy = AppPreferences.defaultDevContainerCLIStrategy.rawValue
    @AppStorage(AppPreferences.devContainerMonitoringEnabledKey) private var monitoringEnabled = AppPreferences.defaultDevContainerMonitoringEnabled
    @AppStorage(AppPreferences.devContainerMonitoringIntervalKey) private var monitoringInterval = AppPreferences.defaultDevContainerMonitoringInterval
    @AppStorage(AppPreferences.devContainerGlobalVisibilityEnabledKey) private var globalVisibilityEnabled = AppPreferences.defaultDevContainerGlobalVisibilityEnabled

    @State private var toolingStatus = DevContainerToolingStatus()
    @State private var isRefreshingToolingStatus = false

    private var selectedStrategy: DevContainerCLIStrategy {
        DevContainerCLIStrategy(rawValue: cliStrategy) ?? AppPreferences.defaultDevContainerCLIStrategy
    }

    var body: some View {
        SettingsFormPage(category: .devContainers) {
            Section {
                Toggle("Enable devcontainer support", isOn: $devContainerEnabled)
                Toggle("Show active devcontainers globally", isOn: $globalVisibilityEnabled)
            } header: {
                Text("General")
            } footer: {
                Text("When disabled, Stackriot still detects configuration files but does not run devcontainer actions.")
            }

            Section {
                Picker("CLI strategy", selection: $cliStrategy) {
                    ForEach(DevContainerCLIStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy.rawValue)
                    }
                }
            } header: {
                Text("CLI resolution")
            } footer: {
                Text("Auto prefers a native `devcontainer` binary and falls back to `npx @devcontainers/cli` when available.")
            }

            Section {
                Toggle("Monitor devcontainers in the background", isOn: $monitoringEnabled)
                Picker("Polling interval", selection: $monitoringInterval) {
                    Text("Every 15 seconds").tag(15.0)
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every minute").tag(60.0)
                    Text("Every 2 minutes").tag(120.0)
                }
                .disabled(!monitoringEnabled)
            } header: {
                Text("Monitoring")
            } footer: {
                Text("This refreshes devcontainer state across known worktrees so global visibility stays current.")
            }

            Section("Tooling status") {
                LabeledContent("Container engine", value: toolingStatus.containerEngine?.displayName ?? "Missing")
                LabeledContent("Engine executable", value: toolingStatus.containerEngineExecutable ?? "Unavailable")
                LabeledContent("devcontainer", value: toolingStatus.devcontainerInstalled ? "Installed" : "Missing")
                LabeledContent("npx", value: toolingStatus.npxInstalled ? "Installed" : "Missing")
                LabeledContent("Effective CLI", value: toolingStatus.resolvedCLI?.displayName ?? "Unavailable")
                Button {
                    Task {
                        isRefreshingToolingStatus = true
                        toolingStatus = await appModel.services.devContainerService.toolingStatus()
                        isRefreshingToolingStatus = false
                    }
                } label: {
                    AsyncActionLabel(
                        title: "Refresh tooling status",
                        systemImage: "arrow.clockwise",
                        isRunning: isRefreshingToolingStatus
                    )
                }
                .disabled(isRefreshingToolingStatus)
            }

            Section("Install help") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preferred path")
                        .font(.subheadline.weight(.medium))
                    Text("Install Docker, Podman, or another Docker-compatible engine, then make the Dev Containers CLI available either in your shell or via Stackriot local CLI management.")
                        .foregroundStyle(.secondary)

                    Text("Fallback path")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 4)
                    Text("If you already have Node.js, Stackriot can use `npx @devcontainers/cli` instead of a globally installed `devcontainer` binary.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: refreshKey) {
            toolingStatus = await appModel.services.devContainerService.toolingStatus()
        }
    }

    private var refreshKey: String {
        "\(devContainerEnabled)-\(cliStrategy)-\(monitoringEnabled)-\(monitoringInterval)-\(globalVisibilityEnabled)"
    }
}
