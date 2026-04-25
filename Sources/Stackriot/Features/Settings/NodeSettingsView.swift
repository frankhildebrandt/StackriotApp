import SwiftUI

struct NodeSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(AppPreferences.nodeAutoUpdateEnabledKey) private var nodeAutoUpdateEnabled = AppPreferences.defaultNodeAutoUpdateEnabled
    @AppStorage(AppPreferences.nodeAutoUpdateIntervalKey) private var nodeAutoUpdateInterval = AppPreferences.defaultNodeAutoUpdateInterval
    @AppStorage(AppPreferences.nodeDefaultVersionSpecKey) private var nodeDefaultVersionSpec = AppPreferences.defaultNodeVersionSpec

    var body: some View {
        SettingsFormPage(category: .node) {
            Section {
                Toggle("Automatically update managed Node LTS", isOn: $nodeAutoUpdateEnabled)
                Picker("Update interval", selection: $nodeAutoUpdateInterval) {
                    Text("Every hour").tag(3600.0)
                    Text("Every 6 hours").tag(21_600.0)
                    Text("Every 12 hours").tag(43_200.0)
                    Text("Every day").tag(86_400.0)
                }
            } header: {
                Text("Managed runtime")
            } footer: {
                Text("Automatic updates keep the managed runtime fresh without forcing a rebuild on every launch.")
            }

            Section {
                TextField("Default version spec", text: $nodeDefaultVersionSpec, prompt: Text(AppPreferences.defaultNodeVersionSpec))
                    .textFieldStyle(.roundedBorder)
                LabeledContent("Resolved default version", value: appModel.nodeRuntimeStatus.resolvedDefaultVersion)
            } header: {
                Text("Defaults")
            } footer: {
                Text("Use a version spec such as `lts/*`, `20`, or `22.11.0`. Stackriot resolves it when the managed runtime is refreshed.")
            }

            Section("Runtime status") {
                LabeledContent("State", value: appModel.nodeRuntimeStatus.bootstrapState)
                LabeledContent("Effective version spec", value: appModel.nodeRuntimeStatus.defaultVersionSpec)
                if let lastUpdatedAt = appModel.nodeRuntimeStatus.lastUpdatedAt {
                    LabeledContent("Last updated") {
                        Text(lastUpdatedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                }
            }

            Section("Paths") {
                LabeledContent("Runtime root") {
                    MonospacedSettingsValue(appModel.nodeRuntimeStatus.runtimeRootPath)
                }
                LabeledContent("NPM cache") {
                    MonospacedSettingsValue(appModel.nodeRuntimeStatus.npmCachePath)
                }
                LabeledContent("Local CLI bin") {
                    MonospacedSettingsValue(AppPaths.localToolsBinDirectory.path)
                }
            }

            Section {
                Button {
                    appModel.rebuildManagedNodeRuntime()
                } label: {
                    AsyncActionLabel(
                        title: "Rebuild managed runtime",
                        systemImage: "arrow.clockwise",
                        isRunning: appModel.isUIActionRunning(.global(AsyncUIActionKey.Operation.nodeRuntime))
                    )
                }
                .disabled(appModel.isUIActionRunning(.global(AsyncUIActionKey.Operation.nodeRuntime)))
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Rebuild the local managed runtime if the resolved version, package manager cache, or installation state looks wrong.")
            }

            if let error = appModel.nodeRuntimeStatus.lastErrorMessage?.nonEmpty {
                Section("Last runtime error") {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("Local CLI tools") {
                ForEach(Array(localCLIStatuses.enumerated()), id: \.element.tool) { _, status in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(status.tool.displayName)
                            Spacer()
                            Text(status.resolutionSource.displayName)
                                .foregroundStyle(status.isAvailable ? Color.secondary : Color.red)
                        }

                        if let resolvedPath = status.resolvedPath?.nonEmpty {
                            MonospacedSettingsValue(resolvedPath)
                        }

                        HStack {
                            Button {
                                appModel.installLocalTool(status.tool)
                            } label: {
                                AsyncActionLabel(
                                    title: "Install locally",
                                    systemImage: "square.and.arrow.down",
                                    isRunning: appModel.isUIActionRunning(.tool(status.tool.rawValue, AsyncUIActionKey.Operation.installLocalTool))
                                )
                            }
                            .disabled(appModel.isUIActionRunning(.tool(status.tool.rawValue, AsyncUIActionKey.Operation.installLocalTool)))

                            if let installHint = status.installHint?.nonEmpty {
                                Text(installHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    appModel.refreshLocalToolStatuses()
                } label: {
                    AsyncActionLabel(
                        title: "Refresh local CLI status",
                        systemImage: "arrow.clockwise",
                        isRunning: appModel.isUIActionRunning(.global(AsyncUIActionKey.Operation.localToolStatus))
                    )
                }
                .disabled(appModel.isUIActionRunning(.global(AsyncUIActionKey.Operation.localToolStatus)))
            }
        }
        .task {
            if appModel.localToolStatuses.isEmpty {
                appModel.refreshLocalToolStatuses()
            }
        }
    }

    private var localCLIStatuses: [AppManagedToolStatus] {
        appModel.localToolStatuses
    }
}

private struct MonospacedSettingsValue: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
