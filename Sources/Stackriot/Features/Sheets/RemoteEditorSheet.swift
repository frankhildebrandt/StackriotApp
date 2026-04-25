import SwiftData
import SwiftUI

struct RemoteEditorSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StoredSSHKey.displayName) private var sshKeys: [StoredSSHKey]

    let repository: ManagedRepository
    let remote: RepositoryRemote?

    @State private var name = ""
    @State private var url = ""
    @State private var fetchEnabled = true
    @State private var isDefaultRemote = false
    @State private var selectedSSHKeyID: UUID?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(remote == nil ? "Add Remote" : "Edit Remote")
                .font(.title2.weight(.semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("URL", text: $url)
                .textFieldStyle(.roundedBorder)
            Toggle("Use this remote during refresh", isOn: $fetchEnabled)
            Toggle("Default Remote", isOn: $isDefaultRemote)

            Picker("SSH Key", selection: $selectedSSHKeyID) {
                Text("None").tag(nil as UUID?)
                ForEach(sshKeys) { key in
                    Text(key.displayName).tag(Optional(key.id))
                }
            }

            if let key = sshKeys.first(where: { $0.id == selectedSSHKeyID }) {
                Text(key.publicKey)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button {
                    save()
                } label: {
                    AsyncActionLabel(title: "Save", systemImage: "checkmark", isRunning: isSaving)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaveDisabled)
                .commandEnterAction(disabled: isSaveDisabled) {
                    save()
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(.regularMaterial)
        .task {
            name = remote?.name ?? ""
            url = remote?.url ?? ""
            fetchEnabled = remote?.fetchEnabled ?? true
            isDefaultRemote = repository.defaultRemoteName == remote?.name || (remote == nil && repository.defaultRemoteName == nil)
            selectedSSHKeyID = remote?.sshKey?.id
        }
    }

    private var isSaveDisabled: Bool {
        isSaving
            || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let actionID = remote?.id.uuidString ?? repository.id.uuidString
        isSaving = true
        Task {
            let key = sshKeys.first(where: { $0.id == selectedSSHKeyID })
            await appModel.performUIAction(
                key: .tool(actionID, AsyncUIActionKey.Operation.remoteManagement),
                title: remote == nil ? "Adding remote" : "Saving remote"
            ) {
                await appModel.saveRemote(
                    name: name,
                    url: url,
                    fetchEnabled: fetchEnabled,
                    isDefaultRemote: isDefaultRemote,
                    sshKey: key,
                    for: repository,
                    editing: remote,
                    in: modelContext
                )
            }
            isSaving = false
            dismiss()
        }
    }
}
