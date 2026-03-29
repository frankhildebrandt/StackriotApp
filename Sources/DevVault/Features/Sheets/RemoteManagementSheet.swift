import SwiftData
import SwiftUI

struct RemoteManagementSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StoredSSHKey.displayName) private var sshKeys: [StoredSSHKey]

    let repository: ManagedRepository
    @State private var editingRemote: RepositoryRemote?
    @State private var remotePendingRemoval: RepositoryRemote?
    @State private var isEditorPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Manage Remotes")
                        .font(.title2.weight(.semibold))
                    Text(repository.displayName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }

            if repository.remotes.isEmpty {
                ContentUnavailableView("No Remotes", systemImage: "network", description: Text("Add a remote to enable refreshes and publishing."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List {
                    ForEach(repository.remotes.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { remote in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(remote.name)
                                    .font(.headline)
                                if !remote.fetchEnabled {
                                    Text("Fetch Off")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.thinMaterial, in: Capsule())
                                }
                                Spacer()
                                Button("Edit") {
                                    editingRemote = remote
                                    isEditorPresented = true
                                }
                                Button("Remove", role: .destructive) {
                                    remotePendingRemoval = remote
                                }
                            }
                            Text(remote.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(remote.sshKey?.displayName ?? "No SSH key assigned")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .frame(minHeight: 260)
            }

            HStack {
                Button {
                    editingRemote = nil
                    isEditorPresented = true
                } label: {
                    Label("Add Remote", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if sshKeys.isEmpty {
                    Text("SSH keys are managed in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 700, height: 520)
        .sheet(isPresented: $isEditorPresented) {
            RemoteEditorSheet(repository: repository, remote: editingRemote)
                .environment(appModel)
        }
        .confirmationDialog("Remove remote?", item: $remotePendingRemoval) { remote in
            Button("Remove", role: .destructive) {
                Task {
                    await appModel.removeRemote(remote, from: repository, in: modelContext)
                }
            }
        } message: { remote in
            Text("Remove \(remote.name) from \(repository.displayName)?")
        }
    }
}
