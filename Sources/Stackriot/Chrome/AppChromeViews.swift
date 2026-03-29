import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferences.autoRefreshEnabledKey) private var autoRefreshEnabled = AppPreferences.defaultAutoRefreshEnabled
    @AppStorage(AppPreferences.autoRefreshIntervalKey) private var autoRefreshInterval = AppPreferences.defaultAutoRefreshInterval
    @AppStorage(AppPreferences.terminalTabRetentionModeKey) private var terminalTabRetentionMode = AppPreferences.defaultTerminalTabRetentionMode.rawValue
    @AppStorage(AppPreferences.nodeAutoUpdateEnabledKey) private var nodeAutoUpdateEnabled = AppPreferences.defaultNodeAutoUpdateEnabled
    @Query(sort: \StoredSSHKey.displayName) private var sshKeys: [StoredSSHKey]

    @State private var isImportingKey = false
    @State private var isGenerateSheetPresented = false
    @State private var pendingKeyDeletion: StoredSSHKey?

    var body: some View {
        Form {
            Section("Repositories") {
                Toggle("Automatically refresh repositories", isOn: $autoRefreshEnabled)
                Picker("Refresh interval", selection: $autoRefreshInterval) {
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("60 minutes").tag(3600.0)
                }
                LabeledContent("Workflow", value: "Bare repos + worktrees")
            }

            Section("Terminal Tabs") {
                Picker("Completed tab retention", selection: $terminalTabRetentionMode) {
                    ForEach(TerminalTabRetentionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
            }

            Section("Node Runtime") {
                Toggle("Automatically update managed Node LTS", isOn: $nodeAutoUpdateEnabled)
                LabeledContent("Status", value: appModel.nodeRuntimeStatus.bootstrapState)
                LabeledContent("Default version", value: appModel.nodeRuntimeStatus.defaultVersionSpec)
                LabeledContent("Resolved default", value: appModel.nodeRuntimeStatus.resolvedDefaultVersion)
                LabeledContent("Runtime root") {
                    Text(appModel.nodeRuntimeStatus.runtimeRootPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("NPM cache") {
                    Text(appModel.nodeRuntimeStatus.npmCachePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let error = appModel.nodeRuntimeStatus.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Rebuild Managed Runtime") {
                    appModel.rebuildManagedNodeRuntime()
                }
            }

            Section("SSH Keys") {
                if sshKeys.isEmpty {
                    Text("No SSH keys stored yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sshKeys) { key in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(key.displayName)
                                    .font(.headline)
                                Spacer()
                                Text(key.kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Delete", role: .destructive) {
                                    pendingKeyDeletion = key
                                }
                            }
                            Text(key.publicKey)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }

                HStack {
                    Button("Import Existing Key") {
                        isImportingKey = true
                    }
                    Button("Generate Key") {
                        isGenerateSheetPresented = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(minWidth: 720, minHeight: 420)
        .fileImporter(
            isPresented: $isImportingKey,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                Task {
                    await appModel.importSSHKey(from: url, in: modelContext)
                }
            case let .failure(error):
                appModel.pendingErrorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isGenerateSheetPresented) {
            GenerateSSHKeySheet()
                .environment(appModel)
        }
        .confirmationDialog("Delete SSH key?", item: $pendingKeyDeletion) { key in
            Button("Delete", role: .destructive) {
                appModel.removeSSHKey(key, in: modelContext)
            }
        } message: { key in
            Text("Remove \(key.displayName) from Stackriot and clear assignments from remotes?")
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Stackriot")
                    .font(.largeTitle.weight(.semibold))
                Text("Repository orchestration for focused local development")
                    .foregroundStyle(.secondary)
            }

            Text("Bare repositories, worktrees, editor launchers, remote management, and structured local task execution in one macOS app.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 280)
        .background(.regularMaterial)
    }
}

private struct GenerateSSHKeySheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Generate SSH Key")
                .font(.title2.weight(.semibold))

            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)
            TextField("Comment (optional)", text: $comment)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Generate") {
                    Task {
                        await appModel.generateSSHKey(displayName: displayName, comment: comment, in: modelContext)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(.regularMaterial)
    }
}
