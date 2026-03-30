import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SSHKeysSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredSSHKey.displayName) private var sshKeys: [StoredSSHKey]

    @State private var isImportingKey = false
    @State private var isGenerateSheetPresented = false
    @State private var pendingKeyDeletion: StoredSSHKey?
    @State private var expandedKeyIDs: Set<UUID> = []

    var body: some View {
        SettingsFormPage(category: .sshKeys) {
            Section {
                if sshKeys.isEmpty {
                    ContentUnavailableView(
                        "No SSH Keys",
                        systemImage: "key.slash",
                        description: Text("Import an existing key or generate a new one to assign SSH credentials to repository remotes.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ForEach(sshKeys) { key in
                        SSHKeyRow(
                            key: key,
                            isExpanded: expandedKeyIDs.contains(key.id),
                            onToggleExpansion: {
                                toggleExpansion(for: key.id)
                            },
                            onDelete: {
                                pendingKeyDeletion = key
                            }
                        )
                    }
                }
            } header: {
                Text("Stored keys")
            } footer: {
                Text("SSH keys are shared with remote management. Deleting a key also removes any remote assignments that currently use it.")
            }

            Section("Actions") {
                Button {
                    isImportingKey = true
                } label: {
                    Label("Import existing key", systemImage: "square.and.arrow.down")
                }

                Button {
                    isGenerateSheetPresented = true
                } label: {
                    Label("Generate key", systemImage: "wand.and.stars")
                }
            }
        }
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
            let remoteCount = key.remotes.count
            if remoteCount == 0 {
                Text("Remove \(key.displayName) from Stackriot?")
            } else {
                Text("Remove \(key.displayName) from Stackriot and clear \(remoteCount) remote assignment\(remoteCount == 1 ? "" : "s")?")
            }
        }
    }

    private func toggleExpansion(for keyID: UUID) {
        if expandedKeyIDs.contains(keyID) {
            expandedKeyIDs.remove(keyID)
        } else {
            expandedKeyIDs.insert(keyID)
        }
    }
}

private struct SSHKeyRow: View {
    let key: StoredSSHKey
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(key.displayName)
                        .font(.headline)
                    HStack(spacing: 10) {
                        Label(key.kind.displayName, systemImage: key.kind == .generated ? "wand.and.stars" : "square.and.arrow.down")
                        if !key.remotes.isEmpty {
                            Label("\(key.remotes.count) remote\(key.remotes.count == 1 ? "" : "s")", systemImage: "link")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(compactPublicKey)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Button(isExpanded ? "Hide key" : "Show key") {
                    onToggleExpansion()
                }

                Button("Delete", role: .destructive) {
                    onDelete()
                }
            }

            if isExpanded {
                Text(key.publicKey)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
    }

    private var compactPublicKey: String {
        let components = key.publicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return key.publicKey }
        let prefix = String(components[0])
        let body = String(components[1])
        let suffix = components.dropFirst(2).joined(separator: " ")
        let head = body.prefix(16)
        let tail = body.suffix(12)
        let abbreviatedBody = body.count > 30 ? "\(head)…\(tail)" : body
        return suffix.isEmpty ? "\(prefix) \(abbreviatedBody)" : "\(prefix) \(abbreviatedBody) \(suffix)"
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
