import SwiftData
import SwiftUI

struct RemoteManagementSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StoredSSHKey.displayName) private var sshKeys: [StoredSSHKey]

    let repository: ManagedRepository
    @State private var editingRemote: RepositoryRemote?
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
                                if repository.defaultRemoteName == remote.name {
                                    Text("Default Remote")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.blue.opacity(0.12), in: Capsule())
                                }
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
                                    Task {
                                        await appModel.removeRemote(remote, from: repository, in: modelContext)
                                    }
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
                    Text("Manage SSH keys in Settings > SSH Keys.")
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
    }
}
