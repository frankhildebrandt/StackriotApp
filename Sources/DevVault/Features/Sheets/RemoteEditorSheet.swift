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
                Button("Save") {
                    Task {
                        let key = sshKeys.first(where: { $0.id == selectedSSHKeyID })
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
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
}
