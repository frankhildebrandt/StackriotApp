import SwiftUI

private enum CodexRunContentMode: String, CaseIterable, Identifiable {
    case feed
    case rawLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed:
            "Feed"
        case .rawLog:
            "Raw Log"
        }
    }
}

private struct CodexFeedScrollTrigger: Equatable {
    let count: Int
    let lastSegmentID: String?
    let lastRevision: Int
}

struct CodexRunFeedView: View {
    @Environment(AppModel.self) private var appModel

    let run: RunRecord

    @State private var selectedMode: CodexRunContentMode = .feed

    private var segments: [CodexRunSegment] {
        appModel.codexSegments(for: run)
    }

    private var bottomAnchorID: String {
        "codex-run-feed-bottom-\(run.id.uuidString)"
    }

    private var scrollTrigger: CodexFeedScrollTrigger {
        CodexFeedScrollTrigger(
            count: segments.count,
            lastSegmentID: segments.last?.id,
            lastRevision: segments.last?.revision ?? 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Ansicht", selection: $selectedMode) {
                ForEach(CodexRunContentMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch selectedMode {
            case .feed:
                feedView
            case .rawLog:
                rawLogView
            }
        }
        .task(id: run.id) {
            appModel.ensureCodexSegmentsLoaded(for: run)
        }
    }

    private var feedView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if segments.isEmpty {
                        ContentUnavailableView(
                            "Noch kein Feed",
                            systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("Sobald strukturierte Codex-Events eintreffen, erscheinen sie hier.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ForEach(segments) { segment in
                            CodexRunSegmentRow(segment: segment)
                                .id(segment.id)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .onAppear {
                scrollToLatest(using: proxy)
            }
            .onChange(of: scrollTrigger) { _, _ in
                scrollToLatest(using: proxy)
            }
        }
    }

    private var rawLogView: some View {
        TextEditor(text: .constant(run.outputText))
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(.black.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.white)
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

private struct CodexRunSegmentRow: View {
    let segment: CodexRunSegment

    var body: some View {
        switch segment.kind {
        case .agentMessage:
            CodexTextFlowCard(
                title: segment.title,
                subtitle: segment.subtitle,
                bodyText: segment.bodyText ?? "",
                iconName: "sparkles",
                accentColor: .accentColor,
                usesSecondaryBodyStyle: false
            )
        case .reasoning:
            CodexTextFlowCard(
                title: segment.title,
                subtitle: segment.subtitle,
                bodyText: segment.bodyText ?? "",
                iconName: "brain",
                accentColor: .secondary,
                usesSecondaryBodyStyle: true
            )
        case .commandExecution:
            CodexStatusCard(
                title: segment.title,
                subtitle: segment.subtitle,
                iconName: "terminal",
                accentColor: .blue,
                status: segment.status,
                exitCode: segment.exitCode,
                bodyText: segment.bodyText,
                detailText: segment.aggregatedOutput,
                detailTitle: "Output"
            )
        case .mcpToolCall:
            CodexStatusCard(
                title: segment.title,
                subtitle: segment.subtitle,
                iconName: "externaldrive.badge.wifi",
                accentColor: .purple,
                status: segment.status,
                exitCode: segment.exitCode,
                bodyText: segment.bodyText,
                detailText: segment.detailText,
                detailTitle: segment.status == .failed ? "Error details" : "Details"
            )
        case .collabToolCall:
            CodexStatusCard(
                title: segment.title,
                subtitle: segment.subtitle,
                iconName: "person.2.fill",
                accentColor: .teal,
                status: segment.status,
                exitCode: segment.exitCode,
                bodyText: segment.bodyText,
                detailText: segment.detailText,
                detailTitle: "Details"
            )
        case .fileChange:
            CodexFileChangeCard(segment: segment)
        case .todoList:
            CodexTodoCard(segment: segment)
        case .error:
            CodexStatusCard(
                title: segment.title,
                subtitle: segment.subtitle,
                iconName: "exclamationmark.triangle.fill",
                accentColor: .red,
                status: segment.status ?? .failed,
                exitCode: segment.exitCode,
                bodyText: segment.bodyText,
                detailText: segment.detailText,
                detailTitle: "Details"
            )
        case .fallbackText:
            CodexFallbackTextCard(text: segment.bodyText ?? segment.title)
        }
    }
}

private struct CodexCardContainer<Content: View>: View {
    let accentColor: Color
    let content: Content

    init(accentColor: Color, @ViewBuilder content: () -> Content) {
        self.accentColor = accentColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accentColor.opacity(0.2))
                .frame(width: 4)
        }
    }
}

private struct CodexTextFlowCard: View {
    let title: String
    let subtitle: String?
    let bodyText: String
    let iconName: String
    let accentColor: Color
    let usesSecondaryBodyStyle: Bool

    var body: some View {
        CodexCardContainer(accentColor: accentColor) {
            CodexCardHeader(
                title: title,
                subtitle: subtitle,
                iconName: iconName,
                accentColor: accentColor
            )

            CodexRichTextFlow(text: bodyText, usesSecondaryStyle: usesSecondaryBodyStyle)
        }
    }
}

private struct CodexStatusCard: View {
    let title: String
    let subtitle: String?
    let iconName: String
    let accentColor: Color
    let status: CodexRunSegment.Status?
    let exitCode: Int?
    let bodyText: String?
    let detailText: String?
    let detailTitle: String

    var body: some View {
        CodexCardContainer(accentColor: accentColor) {
            HStack(alignment: .top, spacing: 12) {
                CodexCardHeader(
                    title: title,
                    subtitle: subtitle,
                    iconName: iconName,
                    accentColor: accentColor
                )
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    if let status {
                        CodexStatusBadge(text: status.displayText, color: badgeColor(for: status))
                    }
                    if let exitCode {
                        CodexStatusBadge(text: "Exit \(exitCode)", color: exitCode == 0 ? .green : .red)
                    }
                }
            }

            if let bodyText {
                Text(bodyText)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }

            if let detailText {
                CodexDisclosureTextBlock(title: detailTitle, text: detailText)
            }
        }
    }

    private func badgeColor(for status: CodexRunSegment.Status) -> Color {
        switch status {
        case .pending:
            .gray
        case .running:
            .blue
        case .completed:
            .green
        case .failed:
            .red
        case .cancelled:
            .orange
        case .unknown:
            .secondary
        }
    }
}

private struct CodexFileChangeCard: View {
    let segment: CodexRunSegment

    var body: some View {
        CodexCardContainer(accentColor: .orange) {
            HStack(alignment: .top, spacing: 12) {
                CodexCardHeader(
                    title: segment.title,
                    subtitle: segment.subtitle,
                    iconName: "doc.on.doc",
                    accentColor: .orange
                )
                Spacer(minLength: 12)
                if let status = segment.status {
                    CodexStatusBadge(text: status.displayText, color: .orange)
                }
            }

            ForEach(segment.fileChanges, id: \.path) { change in
                HStack(spacing: 10) {
                    CodexStatusBadge(text: change.kind.displayText, color: fileColor(for: change.kind))
                    Text(change.path)
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func fileColor(for kind: CodexRunSegment.ChangedFile.Kind) -> Color {
        switch kind {
        case .added:
            .green
        case .deleted:
            .red
        case .renamed, .copied:
            .blue
        case .updated, .unknown:
            .orange
        }
    }
}

private struct CodexTodoCard: View {
    let segment: CodexRunSegment

    var body: some View {
        CodexCardContainer(accentColor: .mint) {
            CodexCardHeader(
                title: segment.title,
                subtitle: segment.subtitle,
                iconName: "checklist",
                accentColor: .mint
            )

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segment.todoItems.enumerated()), id: \.offset) { entry in
                    let item = entry.element
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isCompleted ? .green : .secondary)
                        Text(item.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .strikethrough(item.isCompleted, color: .secondary)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }
}

private struct CodexFallbackTextCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CodexCardHeader: View {
    let title: String
    let subtitle: String?
    let iconName: String
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(accentColor)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct CodexStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct CodexDisclosureTextBlock: View {
    let title: String
    let text: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 6)
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
        }
    }
}

private struct CodexRichTextFlow: View {
    let text: String
    let usesSecondaryStyle: Bool

    private var blocks: [CodexTextBlock] {
        CodexTextBlock.parse(text: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { entry in
                let block = entry.element
                switch block {
                case .markdown(let markdown):
                    CodexMarkdownText(markdown: markdown, usesSecondaryStyle: usesSecondaryStyle)
                case .code(let language, let code):
                    CodexCodeBlockDisclosure(language: language, code: code)
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct CodexMarkdownText: View {
    let markdown: String
    let usesSecondaryStyle: Bool

    private var attributed: AttributedString? {
        try? AttributedString(markdown: markdown)
    }

    var body: some View {
        Group {
            if let attributed {
                Text(attributed)
            } else {
                Text(markdown)
            }
        }
        .font(.body)
        .foregroundStyle(usesSecondaryStyle ? .secondary : .primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodexCodeBlockDisclosure: View {
    let language: String?
    let code: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                Text(language.map { "\($0) code" } ?? "Code")
            }
            .font(.subheadline.weight(.medium))
        }
    }
}

private enum CodexTextBlock: Equatable {
    case markdown(String)
    case code(language: String?, code: String)

    static func parse(text: String) -> [CodexTextBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var remaining = normalized[...]
        var blocks: [CodexTextBlock] = []

        while let start = remaining.range(of: "```") {
            let before = remaining[..<start.lowerBound]
            if let markdown = String(before).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                blocks.append(.markdown(markdown))
            }

            let afterFence = remaining[start.upperBound...]
            guard let end = afterFence.range(of: "```") else {
                if let tail = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    blocks.append(.markdown(tail))
                }
                return blocks
            }

            var codeSection = String(afterFence[..<end.lowerBound])
            var language: String?
            if let newlineIndex = codeSection.firstIndex(of: "\n") {
                let firstLine = String(codeSection[..<newlineIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                language = firstLine.nonEmpty
                codeSection = String(codeSection[codeSection.index(after: newlineIndex)...])
            }
            blocks.append(.code(language: language, code: codeSection.trimmingCharacters(in: .newlines)))
            remaining = afterFence[end.upperBound...]
        }

        if let markdown = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            blocks.append(.markdown(markdown))
        }

        return blocks.isEmpty ? [.markdown(normalized)] : blocks
    }
}
