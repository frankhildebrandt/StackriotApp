import SwiftData
import SwiftUI

struct CreateWorktreeSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let repository: ManagedRepository

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 18) {
            Text("Create Worktree")
                .font(.title2.weight(.semibold))

            TextField("Branch Name", text: $appModel.worktreeDraft.branchName)
                .textFieldStyle(.roundedBorder)
            TextField("Issue / Context (optional)", text: $appModel.worktreeDraft.issueContext)
                .textFieldStyle(.roundedBorder)
            TextField("Source Branch", text: $appModel.worktreeDraft.sourceBranch)
                .textFieldStyle(.roundedBorder)

            Text("Bare repository: \(repository.bareRepositoryPath)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Create") {
                    Task {
                        await appModel.createWorktree(for: repository, in: modelContext)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.worktreeDraft.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(.regularMaterial)
    }
}
