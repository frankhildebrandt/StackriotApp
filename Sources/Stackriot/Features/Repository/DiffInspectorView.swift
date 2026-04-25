import SwiftUI

struct DiffInspectorView: View {
    @Environment(AppModel.self) private var appModel

    let repository: ManagedRepository
    let worktree: WorktreeRecord

    @State private var diffSnapshot = WorkspaceDiffSnapshot(files: [])
    @State private var isLoading = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkspaceDiffFileList(
                    files: filteredFiles,
                    emptyTitle: "No Uncommitted Changes",
                    emptyDescription: query.isEmpty
                        ? "The selected workspace is clean."
                        : "No changed files match the current filter."
                )
                .background(Color.clear)
            }
        }
        .task(id: worktree.id) {
            await reloadDiff()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(worktree.isDefaultBranchWorkspace ? "Main/Default" : worktree.branchName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if diffSnapshot.hasChanges {
                    Text("\(diffSnapshot.files.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }
                Spacer()
                Button {
                    Task { await reloadDiff() }
                } label: {
                    AsyncIconLabel(systemImage: "arrow.clockwise", isRunning: isLoading)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
                .help("Refresh diff")
            }

            TextField("Filter files…", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var filteredFiles: [WorkspaceDiffFile] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return diffSnapshot.files }
        return diffSnapshot.files.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
    }

    @MainActor
    private func reloadDiff() async {
        guard appModel.selectedRepositoryID == repository.id else { return }
        guard !isLoading else { return }
        let key = AsyncUIActionKey.worktree(worktree.id, AsyncUIActionKey.Operation.loadDiff)
        guard appModel.beginUIAction(key, title: "Loading diff") else { return }
        isLoading = true
        defer {
            isLoading = false
            appModel.endUIAction(key)
        }
        let loadedSnapshot = await appModel.loadDiff(for: worktree)
        guard !Task.isCancelled, appModel.selectedRepositoryID == repository.id else {
            return
        }
        diffSnapshot = loadedSnapshot
    }
}
