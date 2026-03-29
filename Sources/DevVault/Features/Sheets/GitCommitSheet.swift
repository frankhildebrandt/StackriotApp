import SwiftData
import SwiftUI

struct GitCommitSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let worktree: WorktreeRecord
    let repository: ManagedRepository

    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Commit")
                .font(.title2.weight(.semibold))

            Text(worktree.branchName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Commit-Nachricht", text: $message, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Abbrechen") {
                    dismiss()
                }
                Button("Commit") {
                    appModel.runGitCommit(
                        message: message,
                        in: worktree,
                        repository: repository,
                        modelContext: modelContext
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
