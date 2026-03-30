import Foundation
import SwiftUI

private enum AgentRunContentMode: String, CaseIterable, Identifiable {
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

private struct AgentFeedScrollTrigger: Equatable {
    let count: Int
    let lastSegmentID: String?
    let lastRevision: Int
}

struct AgentRunFeedView: View {
    @Environment(AppModel.self) private var appModel

    let run: RunRecord

    @State private var selectedMode: AgentRunContentMode = .feed

    private var isCursorStreamInterpreter: Bool {
        run.outputInterpreter == .cursorAgentPrintJSON
    }

    private var segments: [AgentRunSegment] {
        appModel.structuredSegments(for: run)
    }

    /// Cursor `stream-json` assistant output is only shown in `cursorAssistantDrawer`, not in the main feed.
    private var feedSegments: [AgentRunSegment] {
        guard isCursorStreamInterpreter else { return segments }
        return segments.filter { $0.kind != .agentMessage }
    }

    private var cursorAssistantSegments: [AgentRunSegment] {
        guard isCursorStreamInterpreter else { return [] }
        return segments.filter { $0.kind == .agentMessage }
    }

    private var cursorAssistantText: String {
        cursorAssistantSegments
            .map { $0.bodyText ?? "" }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private var rows: [AgentRunFeedRow] {
        AgentRunFeedLayout.rows(from: feedSegments)
    }

    private var bottomAnchorID: String {
        "agent-run-feed-bottom-\(run.id.uuidString)"
    }

    private var cursorAssistantBottomID: String {
        "agent-run-cursor-assistant-bottom-\(run.id.uuidString)"
    }

    private var scrollTrigger: AgentFeedScrollTrigger {
        AgentFeedScrollTrigger(
            count: feedSegments.count,
            lastSegmentID: feedSegments.last?.id,
            lastRevision: feedSegments.last?.revision ?? 0
        )
    }

    private var showFeedEmptyPlaceholder: Bool {
        rows.isEmpty && (!isCursorStreamInterpreter || cursorAssistantText.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Ansicht", selection: $selectedMode) {
                ForEach(AgentRunContentMode.allCases) { mode in
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
            appModel.ensureStructuredSegmentsLoaded(for: run)
        }
    }

    private var feedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if showFeedEmptyPlaceholder {
                            ContentUnavailableView(
                                "Noch kein Feed",
                                systemImage: "bubble.left.and.text.bubble.right",
                                description: Text("Sobald strukturierte Agent-Events eintreffen, erscheinen sie hier. Rohdaten bleiben jederzeit im Raw Log sichtbar.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            ForEach(rows) { row in
                                AgentRunFeedRowView(row: row)
                                    .id(row.id)
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

            if isCursorStreamInterpreter {
                cursorAssistantDrawer
            }
        }
    }

    private var rawLogView: some View {
        TextEditor(text: .constant(rawLogDisplayText))
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(.black.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.white)
    }

    /// Full JSONL is stored on the run; for Cursor we hide `assistant` lines here so the reply stays only in the drawer.
    private var rawLogDisplayText: String {
        guard isCursorStreamInterpreter else { return run.outputText }
        return Self.jsonLRemovingEventTypes(run.outputText, removedTypes: ["assistant"])
    }

    private static func jsonLRemovingEventTypes(_ text: String, removedTypes: Set<String>) -> String {
        let lowered = Set(removedTypes.map { $0.lowercased() })
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { line in
            let string = String(line)
            guard let data = string.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else {
                return true
            }
            return !lowered.contains(type.lowercased())
        }
        return kept.joined(separator: "\n")
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private var cursorAssistantDrawer: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                Label("Antwort", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Group {
                        if cursorAssistantText.isEmpty {
                            Text("Warte auf Antwort…")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            AgentRichTextFlow(text: cursorAssistantText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(height: 1)
                        .id(cursorAssistantBottomID)
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
            )
            .onChange(of: cursorAssistantText.count) { _, _ in
                scrollAssistantDrawerToBottom(using: proxy)
            }
            .onAppear {
                scrollAssistantDrawerToBottom(using: proxy)
            }
        }
    }

    private func scrollAssistantDrawerToBottom(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(cursorAssistantBottomID, anchor: .bottom)
            }
        }
    }
}

enum AgentRunFeedRow: Identifiable, Equatable {
    case segment(AgentRunSegment)
    case changedFiles(id: String, sourceAgent: AIAgentTool, status: AgentRunSegment.Status?, files: [AgentRunSegment.ChangedFile], details: [String])

    var id: String {
        switch self {
        case .segment(let segment):
            segment.id
        case .changedFiles(let id, _, _, _, _):
            id
        }
    }
}

enum AgentRunFeedLayout {
    static func rows(from segments: [AgentRunSegment]) -> [AgentRunFeedRow] {
        var rows: [AgentRunFeedRow] = []
        var index = 0

        while index < segments.count {
            let segment = segments[index]
            if segment.kind == .fileChange {
                var files = segment.fileChanges
                var details = [segment.detailText].compactMap(\.self)
                var status = segment.status
                let sourceAgent = segment.sourceAgent
                let startIndex = index
                index += 1

                while index < segments.count, segments[index].kind == .fileChange {
                    files += segments[index].fileChanges
                    if let detail = segments[index].detailText {
                        details.append(detail)
                    }
                    status = segments[index].status ?? status
                    index += 1
                }

                let deduplicatedFiles = uniqueFiles(from: files)
                rows.append(
                    .changedFiles(
                        id: "changed-files-\(segments[startIndex].id)",
                        sourceAgent: sourceAgent,
                        status: status,
                        files: deduplicatedFiles,
                        details: details
                    )
                )
                continue
            }

            rows.append(.segment(segment))
            index += 1
        }

        return rows
    }

    private static func uniqueFiles(from files: [AgentRunSegment.ChangedFile]) -> [AgentRunSegment.ChangedFile] {
        var seen: Set<String> = []
        var result: [AgentRunSegment.ChangedFile] = []
        for file in files.reversed() {
            guard seen.insert(file.path).inserted else { continue }
            result.append(file)
        }
        return result.reversed()
    }
}

private struct AgentRunFeedRowView: View {
    let row: AgentRunFeedRow

    var body: some View {
        switch row {
        case .segment(let segment):
            AgentRunSegmentRow(segment: segment)
        case .changedFiles(_, let sourceAgent, let status, let files, let details):
            AgentChangedFilesSection(sourceAgent: sourceAgent, status: status, files: files, details: details)
        }
    }
}

private struct AgentRunSegmentRow: View {
    let segment: AgentRunSegment

    var body: some View {
        switch segment.kind {
        case .agentMessage:
            AgentChatBubble(segment: segment)
        case .reasoning:
            AgentReasoningBubble(segment: segment)
        case .commandExecution, .toolCall:
            AgentTimelineRow(segment: segment)
        case .fileChange:
            EmptyView()
        case .todoList:
            AgentTodoBlock(segment: segment)
        case .error:
            AgentAlertRow(segment: segment)
        case .fallbackText:
            AgentFallbackRow(segment: segment)
        }
    }
}

private struct AgentChatBubble: View {
    let segment: AgentRunSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(Color.accentColor)
                Text(segment.sourceAgent.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let subtitle = segment.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            AgentRichTextFlow(text: segment.bodyText ?? "")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
        )
    }

    private var sourceIcon: String {
        switch segment.sourceAgent {
        case .claudeCode:
            "sparkles.rectangle.stack"
        case .githubCopilot:
            "chevron.left.forwardslash.chevron.right"
        case .codex:
            "sparkles"
        default:
            "bubble.left.and.text.bubble.right"
        }
    }
}

private struct AgentReasoningBubble: View {
    let segment: AgentRunSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Thinking", systemImage: "brain")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            AgentRichTextFlow(text: segment.bodyText ?? "", usesSecondaryStyle: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AgentTimelineRow: View {
    let segment: AgentRunSegment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(accentColor.opacity(0.18))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentColor)
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(segment.title)
                        .font(.headline)
                    if let subtitle = segment.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        if let status = segment.status {
                            AgentStatusChip(text: status.displayText, color: statusColor(status))
                        }
                        if let exitCode = segment.exitCode {
                            AgentStatusChip(text: "Exit \(exitCode)", color: exitCode == 0 ? .green : .red)
                        }
                    }
                }

                if let bodyText = segment.bodyText {
                    Text(bodyText)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }

                if let output = segment.aggregatedOutput {
                    AgentDisclosureTextBlock(title: "Output", text: output)
                }

                if let detail = segment.detailText {
                    AgentDisclosureTextBlock(title: "Details", text: detail)
                }
            }
            .padding(.top, 1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var iconName: String {
        switch segment.kind {
        case .commandExecution:
            "terminal"
        case .toolCall:
            "hammer"
        default:
            "circle"
        }
    }

    private var accentColor: Color {
        switch segment.kind {
        case .commandExecution:
            .blue
        case .toolCall:
            .purple
        default:
            .secondary
        }
    }

    private func statusColor(_ status: AgentRunSegment.Status) -> Color {
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

private struct AgentChangedFilesSection: View {
    let sourceAgent: AIAgentTool
    let status: AgentRunSegment.Status?
    let files: [AgentRunSegment.ChangedFile]
    let details: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("Changed files", systemImage: "doc.on.doc")
                    .font(.headline)
                Text(sourceAgent.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let status {
                    AgentStatusChip(text: status.displayText, color: .orange)
                }
            }

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(files, id: \.path) { change in
                    HStack(spacing: 10) {
                        AgentStatusChip(text: change.kind.displayText, color: fileColor(change.kind))
                        Text(change.path)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let detailText = details.joined(separator: "\n\n").nonEmpty {
                AgentDisclosureTextBlock(title: "Details", text: detailText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func fileColor(_ kind: AgentRunSegment.ChangedFile.Kind) -> Color {
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

private struct AgentTodoBlock: View {
    let segment: AgentRunSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(segment.title, systemImage: "checklist")
                .font(.headline)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AgentAlertRow: View {
    let segment: AgentRunSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(segment.title)
                    .font(.headline)
                Spacer()
                if let status = segment.status {
                    AgentStatusChip(text: status.displayText, color: .red)
                }
            }

            if let bodyText = segment.bodyText {
                Text(bodyText)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }

            if let detail = segment.detailText {
                AgentDisclosureTextBlock(title: "Details", text: detail)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AgentFallbackRow: View {
    let segment: AgentRunSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(segment.subtitle ?? segment.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let bodyText = segment.bodyText {
                Text(bodyText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            if let detail = segment.detailText, detail != segment.bodyText {
                AgentDisclosureTextBlock(title: "Raw event", text: detail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AgentStatusChip: View {
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

private struct AgentDisclosureTextBlock: View {
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

private struct AgentRichTextFlow: View {
    let text: String
    let usesSecondaryStyle: Bool

    init(text: String, usesSecondaryStyle: Bool = false) {
        self.text = text
        self.usesSecondaryStyle = usesSecondaryStyle
    }

    private var blocks: [AgentTextBlock] {
        AgentTextBlock.parse(text: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { entry in
                let block = entry.element
                switch block {
                case .markdown(let markdown):
                    AgentMarkdownText(markdown: markdown, usesSecondaryStyle: usesSecondaryStyle)
                case .code(let language, let code):
                    AgentCodeBlockDisclosure(language: language, code: code)
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct AgentMarkdownText: View {
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

private struct AgentCodeBlockDisclosure: View {
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

private enum AgentTextBlock: Equatable {
    case markdown(String)
    case code(language: String?, code: String)

    static func parse(text: String) -> [AgentTextBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var remaining = normalized[...]
        var blocks: [AgentTextBlock] = []

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
