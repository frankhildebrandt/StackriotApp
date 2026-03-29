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
            } else if filteredFiles.isEmpty {
                ContentUnavailableView(
                    "No Uncommitted Changes",
                    systemImage: "checkmark.circle",
                    description: Text(query.isEmpty ? "The selected workspace is clean." : "No changed files match the current filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredFiles) { file in
                            DiffFileSection(file: file)
                        }
                    }
                    .padding(16)
                }
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
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
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
        isLoading = true
        diffSnapshot = await appModel.loadDiff(for: worktree)
        isLoading = false
    }
}

private struct DiffFileSection: View {
    let file: WorkspaceDiffFile
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(renderedLines.indices, id: \.self) { index in
                        DiffLineRow(line: renderedLines[index])
                    }
                }
                .padding(.top, 8)
            }
        } label: {
            HStack {
                Text(file.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(file.status.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var renderedLines: [String] {
        file.patch.split(whereSeparator: \.isNewline).map(String.init)
    }

    private var statusColor: Color {
        switch file.status {
        case .added, .untracked:
            .green
        case .deleted:
            .red
        case .renamed, .copied:
            .blue
        case .unmerged:
            .orange
        case .modified, .unknown:
            .primary
        }
    }
}

private struct DiffLineRow: View {
    let line: String

    var body: some View {
        Text(line)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
    }

    private var backgroundColor: Color {
        if line.hasPrefix("@@") {
            return .blue.opacity(0.12)
        }
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
            return .green.opacity(0.16)
        }
        if line.hasPrefix("-"), !line.hasPrefix("---") {
            return .red.opacity(0.16)
        }
        return .clear
    }

    private var foregroundColor: Color {
        if line.hasPrefix("@@") {
            return .blue
        }
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
            return .green
        }
        if line.hasPrefix("-"), !line.hasPrefix("---") {
            return .red
        }
        return .primary
    }
}
