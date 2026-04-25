import SwiftData
import SwiftUI

struct PublishBranchSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let repository: ManagedRepository
    let worktree: WorktreeRecord
    @State private var isPublishing = false

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 18) {
            Text("Publish Branch")
                .font(.title2.weight(.semibold))

            if let displayPath = worktree.displayPath {
                Text(displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Picker("Remote", selection: $appModel.publishDraft.remoteName) {
                ForEach(repository.remotes.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { remote in
                    Text("\(remote.name) (\(remote.url))").tag(remote.name)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button {
                    publish()
                } label: {
                    AsyncActionLabel(title: "Publish", systemImage: "icloud.and.arrow.up", isRunning: isPublishing)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.publishDraft.remoteName.isEmpty || isPublishing)
                .commandEnterAction(disabled: appModel.publishDraft.remoteName.isEmpty || isPublishing) {
                    publish()
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(.regularMaterial)
    }

    private func publish() {
        isPublishing = true
        Task {
            await appModel.performUIAction(
                key: .worktree(worktree.id, AsyncUIActionKey.Operation.publishBranch),
                title: "Publishing branch"
            ) {
                await appModel.publishSelectedBranch(in: modelContext)
            }
            isPublishing = false
            dismiss()
        }
    }
}
