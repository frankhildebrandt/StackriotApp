import SwiftUI

struct WorkspaceDiffFileList: View {
    let files: [WorkspaceDiffFile]
    let emptyTitle: String
    let emptyDescription: String
    var usesVerticalScrollView = true

    var body: some View {
        if files.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: "checkmark.circle",
                description: Text(emptyDescription)
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: usesVerticalScrollView ? .infinity : nil
            )
        } else {
            Group {
                if usesVerticalScrollView {
                    ScrollView {
                        fileSections
                    }
                } else {
                    fileSections
                }
            }
        }
    }

    private var fileSections: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(files) { file in
                DiffFileSection(file: file)
            }
        }
        .padding(16)
    }
}

struct DiffFileSection: View {
    let file: WorkspaceDiffFile
    @State private var isExpanded = true
    @State private var renderedLines: [String] = []

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
        .task(id: file.patch) {
            renderedLines = file.patch.split(whereSeparator: \.isNewline).map(String.init)
        }
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
