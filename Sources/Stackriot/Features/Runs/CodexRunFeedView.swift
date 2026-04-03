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

private struct RawLogTaskTrigger: Equatable {
    let outputCount: Int
    let removedTypes: Set<String>
}

private struct AgentRunFeedPresentation: Equatable, Sendable {
    let feedSegments: [AgentRunSegment]
    let assistantDrawerText: String
    let rows: [AgentRunFeedRow]

    static let empty = AgentRunFeedPresentation(feedSegments: [], assistantDrawerText: "", rows: [])

    static func build(from segments: [AgentRunSegment], usesAssistantDrawer: Bool) -> AgentRunFeedPresentation {
        let feedSegments: [AgentRunSegment]
        let assistantSegments: [AgentRunSegment]

        if usesAssistantDrawer {
            var nextFeedSegments: [AgentRunSegment] = []
            var nextAssistantSegments: [AgentRunSegment] = []
            nextFeedSegments.reserveCapacity(segments.count)
            nextAssistantSegments.reserveCapacity(segments.count / 2)

            for segment in segments {
                if segment.kind == .agentMessage {
                    nextAssistantSegments.append(segment)
                } else {
                    nextFeedSegments.append(segment)
                }
            }

            feedSegments = nextFeedSegments
            assistantSegments = nextAssistantSegments
        } else {
            feedSegments = segments
            assistantSegments = []
        }

        let assistantDrawerText = assistantSegments
            .compactMap(\.bodyText)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        return AgentRunFeedPresentation(
            feedSegments: feedSegments,
            assistantDrawerText: assistantDrawerText,
            rows: AgentRunFeedLayout.rows(from: feedSegments)
        )
    }
}

struct AgentRunFeedView: View {
    @Environment(AppModel.self) private var appModel

    let run: RunRecord

    @State private var selectedMode: AgentRunContentMode = .feed
    @State private var presentation = AgentRunFeedPresentation.empty
    @State private var cachedRawLogDisplayText = ""

    private var usesAssistantDrawer: Bool {
        switch run.outputInterpreter {
        case .cursorAgentPrintJSON, .copilotPromptJSONL, .openCodePromptJSONL:
            true
        default:
            false
        }
    }

    private var segments: [AgentRunSegment] {
        appModel.structuredSegments(for: run)
    }

    private var bottomAnchorID: String {
        "agent-run-feed-bottom-\(run.id.uuidString)"
    }

    private var assistantDrawerBottomID: String {
        "agent-run-assistant-bottom-\(run.id.uuidString)"
    }

    private var scrollTrigger: AgentFeedScrollTrigger {
        AgentFeedScrollTrigger(
            count: presentation.feedSegments.count,
            lastSegmentID: presentation.feedSegments.last?.id,
            lastRevision: presentation.feedSegments.last?.revision ?? 0
        )
    }

    private var showFeedEmptyPlaceholder: Bool {
        presentation.rows.isEmpty && (!usesAssistantDrawer || presentation.assistantDrawerText.isEmpty)
    }

    private var rawLogRemovedEventTypes: Set<String> {
        switch run.outputInterpreter {
        case .cursorAgentPrintJSON:
            ["assistant"]
        case .copilotPromptJSONL:
            ["assistant.message", "assistant.message_delta"]
        case .openCodePromptJSONL:
            ["text"]
        default:
            []
        }
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
        .onChange(of: run.status) { old, new in
            switch new {
            case .succeeded, .failed, .cancelled:
                guard old == .running || old == .pending else { return }
                appModel.presentCursorAgentMarkdownSnapshotIfNeeded(for: run)
            default:
                break
            }
        }
        .task(id: run.id) {
            appModel.ensureStructuredSegmentsLoaded(for: run)
        }
        .task(id: presentationTaskTrigger) {
            let nextSegments = segments
            let usesAssistantDrawer = usesAssistantDrawer
            let nextPresentation = await Task.detached(priority: .userInitiated) {
                AgentRunFeedPresentation.build(from: nextSegments, usesAssistantDrawer: usesAssistantDrawer)
            }.value
            guard !Task.isCancelled else { return }
            presentation = nextPresentation
        }
        .task(id: rawLogTaskTrigger) {
            let outputText = run.outputText
            let removedTypes = rawLogRemovedEventTypes
            let nextText: String

            if removedTypes.isEmpty {
                nextText = outputText
            } else {
                nextText = await Task.detached(priority: .utility) {
                    Self.jsonLRemovingEventTypes(outputText, removedTypes: removedTypes)
                }.value
            }

            guard !Task.isCancelled else { return }
            cachedRawLogDisplayText = nextText
        }
    }

    private var feedView: some View {
        Group {
            if usesAssistantDrawer {
                VSplitView {
                    feedScrollCard
                    assistantOutputDrawer
                }
                .frame(maxHeight: .infinity)
            } else {
                feedScrollCard
            }
        }
    }

    private var feedScrollCard: some View {
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
                        ForEach(presentation.rows) { row in
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
    }

    private var rawLogView: some View {
        TextEditor(text: .constant(cachedRawLogDisplayText))
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(.black.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(.white)
    }

    private var presentationTaskTrigger: AgentFeedScrollTrigger {
        AgentFeedScrollTrigger(
            count: segments.count,
            lastSegmentID: segments.last?.id,
            lastRevision: segments.last?.revision ?? 0
        )
    }

    private var rawLogTaskTrigger: RawLogTaskTrigger {
        RawLogTaskTrigger(
            outputCount: run.outputText.count,
            removedTypes: rawLogRemovedEventTypes
        )
    }

    nonisolated private static func jsonLRemovingEventTypes(_ text: String, removedTypes: Set<String>) -> String {
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

    private var assistantOutputDrawer: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                Label("Antwort", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Group {
                        if presentation.assistantDrawerText.isEmpty {
                            Text("Warte auf Antwort…")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            AgentRichTextFlow(text: presentation.assistantDrawerText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(height: 1)
                        .id(assistantDrawerBottomID)
                }
                .frame(minHeight: 120)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
            )
            .onChange(of: presentation.assistantDrawerText.count) { _, _ in
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
                proxy.scrollTo(assistantDrawerBottomID, anchor: .bottom)
            }
        }
    }
}

enum AgentRunFeedRow: Identifiable, Equatable, Sendable {
    case segment(AgentRunSegment)
    case turnGroup(
        id: String,
        sourceAgent: AIAgentTool,
        header: String?,
        title: String,
        subtitle: String?,
        status: AgentRunSegment.Status?,
        summary: String?,
        segments: [AgentRunSegment]
    )
    case changedFiles(id: String, sourceAgent: AIAgentTool, status: AgentRunSegment.Status?, files: [AgentRunSegment.ChangedFile], details: [String])

    var id: String {
        switch self {
        case .segment(let segment):
            segment.id
        case .turnGroup(let id, _, _, _, _, _, _, _):
            id
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
            if let groupID = groupableTurnGroupID(for: segment) {
                let sourceAgent = segment.sourceAgent
                var groupedSegments = [segment]
                index += 1

                while index < segments.count {
                    let candidate = segments[index]
                    guard candidate.sourceAgent == sourceAgent, candidate.groupID == groupID, candidate.kind != .fileChange else {
                        break
                    }
                    groupedSegments.append(candidate)
                    index += 1
                }

                if groupedSegments.count == 1 {
                    rows.append(.segment(groupedSegments[0]))
                } else {
                    rows.append(
                        .turnGroup(
                            id: "turn-group-\(groupID)",
                            sourceAgent: sourceAgent,
                            header: turnGroupHeader(from: groupedSegments),
                            title: turnGroupTitle(from: groupedSegments),
                            subtitle: turnGroupSubtitle(from: groupedSegments),
                            status: turnGroupStatus(from: groupedSegments),
                            summary: turnGroupSummary(from: groupedSegments),
                            segments: groupedSegments
                        )
                    )
                }
                continue
            }

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

    private static func groupableTurnGroupID(for segment: AgentRunSegment) -> String? {
        guard
            segment.sourceAgent == .githubCopilot,
            segment.kind != .fileChange,
            let groupID = segment.groupID
        else {
            return nil
        }
        return groupID
    }

    private static func turnGroupHeader(from segments: [AgentRunSegment]) -> String? {
        if let intentTitle = segments.reversed().first(where: \.isIntentSegment)?.title {
            return intentTitle
        }
        if let turnTitle = segments.first(where: \.isTurnLifecycleSegment)?.title {
            return turnTitle
        }
        return nil
    }

    private static func turnGroupTitle(from segments: [AgentRunSegment]) -> String {
        if let assistantTitle = segments.reversed().first(where: { $0.kind == .agentMessage })?.title {
            return assistantTitle
        }
        if let activeToolTitle = segments.reversed().first(where: { $0.isUserVisibleToolSegment })?.title {
            return activeToolTitle
        }
        return turnGroupHeader(from: segments) ?? segments.last?.title ?? "Turn"
    }

    private static func turnGroupSubtitle(from segments: [AgentRunSegment]) -> String? {
        if let toolSubtitle = segments.reversed().first(where: { $0.isUserVisibleToolSegment })?.preferredTurnSubtitle {
            return toolSubtitle
        }
        if let userPrompt = segments.reversed().first(where: \.isUserPromptSegment)?.bodyText?.nonEmpty {
            return userPrompt
        }
        return segments.reversed().compactMap(\.subtitle).first
    }

    private static func turnGroupStatus(from segments: [AgentRunSegment]) -> AgentRunSegment.Status? {
        if segments.contains(where: { $0.status == .failed }) {
            return .failed
        }
        if segments.contains(where: { $0.status == .running }) {
            return .running
        }
        if segments.contains(where: { $0.status == .pending }) {
            return .pending
        }
        return segments.reversed().compactMap(\.status).first
    }

    private static func turnGroupSummary(from segments: [AgentRunSegment]) -> String? {
        let actionableSegments = segments.filter { !$0.isTurnLifecycleSegment }
        let toolSegments = actionableSegments.filter { $0.kind == .commandExecution || $0.kind == .toolCall }
        let summarizedCompletedToolCount = toolSegments.filter(\.isSummarizableCompletedTool).count
        guard !toolSegments.isEmpty else {
            return actionableSegments.first?.title ?? actionableSegments.first?.bodyText
        }

        let firstTool = toolSegments.first?.title ?? "Action"
        if toolSegments.count == 1 {
            return firstTool
        }
        let summary = "\(toolSegments.count) actions · \(firstTool) + \(toolSegments.count - 1) more"
        guard summarizedCompletedToolCount > 1 else {
            return summary
        }
        return "\(summary) · \(summarizedCompletedToolCount) completed"
    }
}

private struct AgentRunFeedRowView: View {
    let row: AgentRunFeedRow

    var body: some View {
        switch row {
        case .segment(let segment):
            AgentRunSegmentRow(segment: segment)
        case .turnGroup(_, let sourceAgent, let header, let title, let subtitle, let status, let summary, let segments):
            AgentTurnGroupRow(
                sourceAgent: sourceAgent,
                header: header,
                title: title,
                subtitle: subtitle,
                status: status,
                summary: summary,
                segments: segments
            )
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

private struct AgentTurnGroupRow: View {
    let sourceAgent: AIAgentTool
    let header: String?
    let title: String
    let subtitle: String?
    let status: AgentRunSegment.Status?
    let summary: String?
    let segments: [AgentRunSegment]

    @State private var isExpanded: Bool

    init(
        sourceAgent: AIAgentTool,
        header: String?,
        title: String,
        subtitle: String?,
        status: AgentRunSegment.Status?,
        summary: String?,
        segments: [AgentRunSegment]
    ) {
        self.sourceAgent = sourceAgent
        self.header = header
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.summary = summary
        self.segments = segments
        _isExpanded = State(initialValue: !Self.isCollapsedByDefault(for: status))
    }

    private var visibleSegments: [AgentRunSegment] {
        let filtered = segments.filter { !$0.isTurnLifecycleSegment && !$0.isIntentSegment }
        return filtered.isEmpty ? segments : filtered
    }

    private var expandedSegments: [AgentRunSegment] {
        visibleSegments.filter { !$0.isSummarizableCompletedTool }
    }

    private var summarizedCompletedTools: [AgentRunSegment] {
        visibleSegments.filter(\.isSummarizableCompletedTool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        if let header, header != title {
                            Text(header)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        HStack(spacing: 8) {
                            Text(sourceAgent.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if !isExpanded, let summary {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 12)

                    if let status {
                        AgentStatusChip(text: status.displayText, color: statusColor(status))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if !summarizedCompletedTools.isEmpty {
                        AgentCompletedToolSummaryRow(segments: summarizedCompletedTools)
                    }

                    ForEach(expandedSegments) { segment in
                        AgentRunSegmentRow(segment: segment)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onChange(of: status) { _, newValue in
            guard Self.isCollapsedByDefault(for: newValue) else { return }
            isExpanded = false
        }
    }

    private static func isCollapsedByDefault(for status: AgentRunSegment.Status?) -> Bool {
        switch status {
        case .completed, .failed, .cancelled:
            true
        default:
            false
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

private struct AgentCompletedToolSummaryRow: View {
    let segments: [AgentRunSegment]

    private var labels: [String] {
        var seen: Set<String> = []
        return segments.compactMap { segment in
            let candidate = (segment.preferredTurnSubtitle ?? segment.title).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, seen.insert(candidate).inserted else { return nil }
            return candidate
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("\(segments.count) completed tool calls")
                    .font(.subheadline.weight(.semibold))
            }

            if !labels.isEmpty {
                Text(labels.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AgentChatBubble: View {
    let segment: AgentRunSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(Color.accentColor)
                Text(segment.title)
                    .font(.headline)
                Text(segment.sourceAgent.displayName)
                    .font(.caption.weight(.medium))
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

    var body: some View {
        agentMarkdownAttributedText(agentMarkdownNormalizeNewlines(markdown))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(usesSecondaryStyle ? 0.78 : 1)
    }

    private func agentMarkdownAttributedText(_ source: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            return Text(attributed)
        }
        return Text(source)
    }
}

private func agentMarkdownNormalizeNewlines(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
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

private extension AgentRunSegment {
    var isIntentSegment: Bool {
        sourceAgent == .githubCopilot
            && kind == .toolCall
            && subtitle?.lowercased() == "report_intent"
    }

    var isTurnLifecycleSegment: Bool {
        sourceAgent == .githubCopilot
            && kind == .toolCall
            && id.hasPrefix("turn-")
    }

    var isUserPromptSegment: Bool {
        kind == .toolCall && title == "User prompt"
    }

    var preferredTurnSubtitle: String? {
        subtitle?.nonEmpty ?? bodyText?.nonEmpty ?? title.nonEmpty
    }

    var isUserVisibleToolSegment: Bool {
        (kind == .commandExecution || kind == .toolCall)
            && !isTurnLifecycleSegment
            && !isIntentSegment
            && !isUserPromptSegment
    }

    var isSummarizableCompletedTool: Bool {
        isUserVisibleToolSegment
            && status == .completed
            && aggregatedOutput == nil
            && detailText == nil
    }
}
