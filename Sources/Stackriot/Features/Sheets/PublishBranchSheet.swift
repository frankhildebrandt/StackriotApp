import SwiftData
import SwiftUI

struct PublishBranchSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let repository: ManagedRepository
    let worktree: WorktreeRecord

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
                Button("Publish") {
                    Task {
                        await appModel.publishSelectedBranch(in: modelContext)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.publishDraft.remoteName.isEmpty)
                .commandEnterAction(disabled: appModel.publishDraft.remoteName.isEmpty) {
                    Task {
                        await appModel.publishSelectedBranch(in: modelContext)
                        dismiss()
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(.regularMaterial)
    }
}
