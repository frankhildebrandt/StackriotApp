import Foundation

final class CopilotPromptJSONLParser: StructuredAgentOutputParsing {
    private static let ignoredEventTypes: Set<String> = [
        "session.background_tasks_changed",
        "session.mcp_servers_loaded",
        "session.mcp_server_status_changed",
        "session.tools_updated",
    ]

    private var bufferedLine = ""
    private var nextTransientSegmentIndex = 0
    private var segmentRevisions: [String: Int] = [:]
    private var bodyTextByID: [String: String] = [:]
    private var aggregatedOutputByID: [String: String] = [:]
    private var detailTextByID: [String: String] = [:]
    private var toolNameByID: [String: String] = [:]
    private var toolSubtitleByID: [String: String] = [:]
    private var commandByID: [String: String] = [:]
    private var latestIntentByGroupID: [String: String] = [:]
    private var lastTodoFingerprint: String?

    func consume(_ chunk: String) -> StructuredAgentOutputChunk {
        bufferedLine += chunk

        var parsed = StructuredAgentOutputChunk()
        while let newlineIndex = bufferedLine.firstIndex(of: "\n") {
            let line = String(bufferedLine[..<newlineIndex])
            bufferedLine.removeSubrange(...newlineIndex)
            parsed.append(render(line: line))
        }

        return parsed
    }

    func finish() -> StructuredAgentOutputChunk {
        var parsed = StructuredAgentOutputChunk()
        if !bufferedLine.isEmpty {
            parsed.append(render(line: bufferedLine))
            bufferedLine.removeAll(keepingCapacity: false)
        }
        return parsed
    }

    private func render(line rawLine: String) -> StructuredAgentOutputChunk {
        let line = rawLine.replacingOccurrences(of: "\r", with: "")
        guard !line.isEmpty else { return StructuredAgentOutputChunk(renderedText: "\n") }
        guard let object = StructuredAgentOutputParserSupport.jsonObject(from: line) else {
            return fallbackChunk(line: line)
        }

        let type = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["type", "event", "kind"]) ?? "event"
        let normalizedType = type.lowercased()

        if Self.ignoredEventTypes.contains(normalizedType) {
            return StructuredAgentOutputChunk()
        }

        if let errorChunk = renderErrorIfNeeded(type: type, object: object) {
            return errorChunk
        }
        if let fileChunk = renderFileChangesIfNeeded(type: type, object: object) {
            return fileChunk
        }
        if let todoChunk = renderTodoIfNeeded(type: type, object: object) {
            return todoChunk
        }
        if let conversationChunk = renderConversationEventIfNeeded(type: type, object: object) {
            return conversationChunk
        }
        if let toolChunk = renderToolEventIfNeeded(type: type, object: object) {
            return toolChunk
        }
        if let messageChunk = renderAssistantMessageIfNeeded(type: type, object: object) {
            return messageChunk
        }
        if let reasoningChunk = renderReasoningIfNeeded(type: type, object: object) {
            return reasoningChunk
        }

        return StructuredAgentOutputParserSupport.summarizeUnknownEvent(
            agent: .githubCopilot,
            line: line,
            object: object,
            fallbackID: nextTransientSegmentID(prefix: "copilot-event")
        )
    }

    private func renderAssistantMessageIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let payload = eventPayload(from: object)
        let legacyRole = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["role", "speaker"])
        let isLegacyAssistantMessage = (legacyRole?.lowercased() == "assistant")
            || normalizedType == "assistant_message"
            || normalizedType == "assistant.response"
        let isRealAssistantMessage = normalizedType == "assistant.message" || normalizedType == "assistant.message_delta"
        guard isRealAssistantMessage || isLegacyAssistantMessage else { return nil }

        let phase = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["phase"])?.lowercased()
        let groupID = segmentGroupID(for: payload, object: object)

        if phase == "thinking", let thinkingText = extractMessageText(from: payload, eventType: normalizedType) {
            return reasoningChunk(
                text: thinkingText,
                id: reasoningSegmentID(for: payload, object: object),
                groupID: groupID,
                renderedPrefix: normalizedType.contains("delta") ? "" : "[copilot] Thinking: ",
                isDelta: normalizedType.contains("delta")
            )
        }

        var chunk = StructuredAgentOutputChunk()

        if let reasoningText = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["reasoningText"]),
           let messageID = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["messageId"]) {
            let reasoningID = "\(messageID)-reasoning"
            let bodyText = mergedText(reasoningText, for: reasoningID, store: &bodyTextByID)
            chunk.renderedText += "[copilot] Thinking: \(reasoningText)\n"
            chunk.segments.append(
                makeSegment(
                    id: reasoningID,
                    kind: .reasoning,
                    title: "Thinking",
                    bodyText: bodyText,
                    groupID: groupID
                )
            )
        }

        guard let text = extractMessageText(from: payload.isEmpty ? object : payload, eventType: normalizedType) else {
            return chunk.segments.isEmpty ? StructuredAgentOutputChunk() : chunk
        }

        let segmentID = messageSegmentID(for: payload, object: object)
        let bodyText = mergedText(
            text,
            for: segmentID,
            store: &bodyTextByID,
            isDelta: normalizedType.contains("delta")
        )
        chunk.segments.append(
            makeSegment(
                id: segmentID,
                kind: .agentMessage,
                title: assistantMessageTitle(for: phase),
                bodyText: bodyText,
                groupID: groupID
            )
        )
        let renderedPrefix = normalizedType.contains("delta") || normalizedType.contains("partial") ? "" : "[copilot] "
        chunk.renderedText += renderedPrefix + text + (renderedPrefix.isEmpty ? "" : "\n")
        return chunk
    }

    private func renderReasoningIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let payload = eventPayload(from: object)

        if normalizedType == "assistant.reasoning" || normalizedType == "assistant.reasoning_delta" {
            guard let text = extractReasoningText(from: payload) else { return nil }
            return reasoningChunk(
                text: text,
                id: reasoningSegmentID(for: payload, object: object),
                groupID: segmentGroupID(for: payload, object: object),
                renderedPrefix: normalizedType.contains("delta") ? "" : "[copilot] Thinking: ",
                isDelta: normalizedType == "assistant.reasoning_delta"
            )
        }

        if normalizedType.contains("reason") || normalizedType.contains("thinking") {
            guard let text = extractReasoningText(from: payload.isEmpty ? object : payload) ?? extractMessageText(from: payload.isEmpty ? object : payload, eventType: normalizedType) else {
                return nil
            }
            return reasoningChunk(
                text: text,
                id: reasoningSegmentID(for: payload, object: object),
                groupID: segmentGroupID(for: payload, object: object),
                renderedPrefix: "[copilot] Thinking: ",
                isDelta: normalizedType.contains("delta")
            )
        }

        return nil
    }

    private func renderConversationEventIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let payload = eventPayload(from: object)

        if normalizedType == "user.message" {
            guard let text = extractMessageText(from: payload.isEmpty ? object : payload, eventType: normalizedType) else {
                return nil
            }
            let segment = makeSegment(
                id: userMessageSegmentID(for: payload, object: object),
                kind: .toolCall,
                title: "User prompt",
                subtitle: StructuredAgentOutputParserSupport.firstString(
                    in: payload.isEmpty ? object : payload,
                    keys: ["interactionId"]
                ),
                bodyText: text,
                status: .completed,
                groupID: segmentGroupID(for: payload, object: object)
            )
            return StructuredAgentOutputChunk(
                renderedText: "[user] \(text)\n",
                segments: [segment]
            )
        }

        guard normalizedType == "assistant.turn_start" || normalizedType == "assistant.turn_end" else {
            return nil
        }

        let turnID = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["turnId"])
            ?? StructuredAgentOutputParserSupport.firstString(in: object, keys: ["turnId"])
        let interactionID = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["interactionId"])
            ?? StructuredAgentOutputParserSupport.firstString(in: object, keys: ["interactionId"])
        let groupID = segmentGroupID(for: payload, object: object) ?? interactionID
        let fallbackTitle = turnID.map { "Turn \($0)" } ?? "Turn"
        let status: AgentRunSegment.Status = normalizedType.hasSuffix("start") ? .running : .completed
        let segment = makeSegment(
            id: turnSegmentID(for: payload, object: object),
            kind: .toolCall,
            title: turnHeaderTitle(for: groupID, fallback: fallbackTitle),
            subtitle: interactionID,
            status: status,
            groupID: groupID
        )
        let rendered = normalizedType.hasSuffix("start")
            ? "[copilot] \(fallbackTitle) started\n"
            : "[copilot] \(fallbackTitle) finished\n"
        return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
    }

    private func reasoningChunk(
        text: String,
        id: String,
        groupID: String?,
        renderedPrefix: String,
        isDelta: Bool = false
    ) -> StructuredAgentOutputChunk {
        let bodyText = mergedText(text, for: id, store: &bodyTextByID, isDelta: isDelta)
        let segment = makeSegment(
            id: id,
            kind: .reasoning,
            title: "Thinking",
            bodyText: bodyText,
            groupID: groupID
        )
        return StructuredAgentOutputChunk(
            renderedText: renderedPrefix + text + (renderedPrefix.isEmpty ? "" : "\n"),
            segments: [segment]
        )
    }

    private func renderToolEventIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let payload = eventPayload(from: object)
        let arguments = StructuredAgentOutputParserSupport.nestedDictionary(in: payload, keys: ["arguments", "input", "payload"])
        let rawToolName = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["toolName", "tool_name", "tool", "name"])
            ?? StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["mcpToolName"])
        let rawCommand = extractCommand(from: arguments ?? payload)
        let groupID = segmentGroupID(for: payload, object: object)
        let isRealToolEvent = [
            "tool.user_requested",
            "tool.execution_start",
            "tool.execution_partial_result",
            "tool.execution_progress",
            "tool.execution_complete",
        ].contains(normalizedType)
        let isLegacyToolEvent = ["tool.started", "tool.completed"].contains(normalizedType)
            || rawToolName != nil
            || rawCommand != nil
        guard isRealToolEvent || isLegacyToolEvent else { return nil }

        let segmentID = toolSegmentID(for: payload, object: object)
        if let rawToolName {
            toolNameByID[segmentID] = rawToolName
        }
        if let rawCommand {
            commandByID[segmentID] = rawCommand
        }
        let toolName = rawToolName ?? toolNameByID[segmentID]
        let command = rawCommand ?? commandByID[segmentID]
        let reportIntent = reportIntentValue(toolName: toolName, arguments: arguments)
        if let reportIntent, let groupID {
            latestIntentByGroupID[groupID] = reportIntent
        }
        let status = toolStatus(for: normalizedType, payload: payload)
        let isCommand = isCommandLike(toolName: toolName, command: command)
        let title = toolRowTitle(toolName: toolName, command: command, reportIntent: reportIntent)
        let preferredSubtitle = preferredToolSubtitle(from: payload)
        if let preferredSubtitle {
            toolSubtitleByID[segmentID] = preferredSubtitle
        }
        let subtitle = toolSubtitleByID[segmentID] ?? toolName

        let result = StructuredAgentOutputParserSupport.nestedDictionary(in: payload, keys: ["result"])
        let error = StructuredAgentOutputParserSupport.nestedDictionary(in: payload, keys: ["error"])
        let partialOutput = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["partialOutput"])
        let progressMessage = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["progressMessage"])
        let outputCandidate = partialOutput
            ?? StructuredAgentOutputParserSupport.firstString(in: result ?? [:], keys: ["detailedContent", "content"])
            ?? StructuredAgentOutputParserSupport.prettyPrintedString(from: result?["contents"])
            ?? StructuredAgentOutputParserSupport.prettyPrintedString(from: payload["output"])
            ?? StructuredAgentOutputParserSupport.prettyPrintedString(from: payload["result"])
        let detailCandidate = progressMessage
            ?? StructuredAgentOutputParserSupport.prettyPrintedString(from: arguments)
            ?? StructuredAgentOutputParserSupport.prettyPrintedString(from: error)
            ?? (isCommand ? nil : outputCandidate)
        let aggregatedOutput = isCommand ? outputCandidate.flatMap { mergedText($0, for: segmentID, store: &aggregatedOutputByID) } : nil
        let detailText = detailCandidate.flatMap { mergedText($0, for: segmentID, store: &detailTextByID) }
        let bodyText = reportIntent

        let segment = makeSegment(
            id: segmentID,
            kind: isCommand ? .commandExecution : .toolCall,
            title: title,
            subtitle: subtitle,
            bodyText: bodyText,
            status: status,
            detailText: isCommand ? nil : detailText,
            aggregatedOutput: aggregatedOutput,
            groupID: groupID
        )

        let renderedTitle = isCommand ? "$ \(title)" : "Tool \(title)"
        let rendered: String
        switch normalizedType {
        case "tool.execution_partial_result":
            rendered = partialOutput ?? ""
        case "tool.execution_progress":
            rendered = progressMessage.map { "[copilot] \($0)\n" } ?? ""
        case "tool.execution_start", "tool.user_requested", "tool.started":
            rendered = "[copilot] \(renderedTitle)\n"
        default:
            rendered = "[copilot] \(renderedTitle) \(status.displayText.lowercased())\n"
        }

        return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
    }

    private func renderFileChangesIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let payload = eventPayload(from: object)

        if normalizedType == "permission.requested",
           let permissionRequest = StructuredAgentOutputParserSupport.nestedDictionary(in: payload, keys: ["permissionRequest"]),
           StructuredAgentOutputParserSupport.firstString(in: permissionRequest, keys: ["kind"]) == "write",
           let path = StructuredAgentOutputParserSupport.firstString(in: permissionRequest, keys: ["fileName"]) {
            let kind = permissionRequest["newFileContents"] == nil ? AgentRunSegment.ChangedFile.Kind.updated : .added
            let segment = makeSegment(
                id: stableSegmentID(for: permissionRequest, fallbackPrefix: "copilot-files"),
                kind: .fileChange,
                title: "Changed files",
                subtitle: path,
                status: .pending,
                detailText: StructuredAgentOutputParserSupport.firstString(in: permissionRequest, keys: ["diff", "intention"]),
                fileChanges: [.init(path: path, kind: kind)],
                groupID: StructuredAgentOutputParserSupport.firstString(in: permissionRequest, keys: ["toolCallId"])
            )
            return StructuredAgentOutputChunk(renderedText: "[copilot] File changes updated\n", segments: [segment])
        }

        if normalizedType == "session.workspace_file_changed",
           let path = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["path"]) {
            let kind = AgentRunSegment.ChangedFile.Kind(rawValue: StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["operation"]))
            let segment = makeSegment(
                id: stableSegmentID(for: payload, fallbackPrefix: "copilot-files"),
                kind: .fileChange,
                title: "Changed files",
                subtitle: path,
                status: .completed,
                fileChanges: [.init(path: path, kind: kind)],
                groupID: path
            )
            return StructuredAgentOutputChunk(renderedText: "[copilot] File changes updated\n", segments: [segment])
        }

        if normalizedType == "result",
           let usage = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["usage"]),
           let codeChanges = StructuredAgentOutputParserSupport.nestedDictionary(in: usage, keys: ["codeChanges"]),
           let files = codeChanges["filesModified"] as? [Any] {
            let fileChanges = files.compactMap(parseFileChange(from:))
            guard !fileChanges.isEmpty else { return nil }
            let segment = makeSegment(
                id: stableSegmentID(for: object, fallbackPrefix: "copilot-files"),
                kind: .fileChange,
                title: "Changed files",
                subtitle: fileChanges.map(\.path).prefix(3).joined(separator: ", ").nonEmpty,
                status: .completed,
                fileChanges: fileChanges
            )
            return StructuredAgentOutputChunk(renderedText: "[copilot] File changes updated\n", segments: [segment])
        }

        let source = (payload["fileChanges"] as? [Any])
            ?? (payload["changes"] as? [Any])
            ?? (payload["files"] as? [Any])
            ?? (StructuredAgentOutputParserSupport.nestedDictionary(in: payload, keys: ["patch", "diff"])?["files"] as? [Any])
        let fileChanges = (source ?? []).compactMap(parseFileChange(from:))
        guard !fileChanges.isEmpty || normalizedType.contains("patch") || normalizedType.contains("file") else {
            return nil
        }
        let summary = fileChanges.map(\.path).prefix(3).joined(separator: ", ")
        let segment = makeSegment(
            id: stableSegmentID(for: payload.isEmpty ? object : payload, fallbackPrefix: "copilot-files"),
            kind: .fileChange,
            title: "Changed files",
            subtitle: summary.nonEmpty,
            status: AgentRunSegment.Status(rawValue: StructuredAgentOutputParserSupport.firstString(in: payload.isEmpty ? object : payload, keys: ["status", "state"]), eventType: type),
            detailText: fileChanges.isEmpty ? StructuredAgentOutputParserSupport.prettyPrintedString(from: payload["patch"] ?? payload["diff"]) : nil,
            fileChanges: fileChanges,
            groupID: StructuredAgentOutputParserSupport.firstString(in: payload.isEmpty ? object : payload, keys: ["operation_id", "tool_call_id", "toolCallId"])
        )
        return StructuredAgentOutputChunk(renderedText: "[copilot] File changes updated\n", segments: [segment])
    }

    private func renderTodoIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let payload = eventPayload(from: object)

        if normalizedType == "exit_plan_mode.requested" {
            let planContent = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["planContent"])
            let summary = StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["summary"])
            let items = parsePlanContent(planContent) + parsePlanSummary(summary)
            let deduplicatedItems = items.removingDuplicateTodoItems()
            guard !deduplicatedItems.isEmpty else { return nil }
            let fingerprint = fingerprint(for: deduplicatedItems)
            guard fingerprint != lastTodoFingerprint else { return StructuredAgentOutputChunk() }
            lastTodoFingerprint = fingerprint
            let segment = makeSegment(
                id: stableSegmentID(for: payload, fallbackPrefix: "copilot-todo"),
                kind: .todoList,
                title: "Plan",
                subtitle: summary,
                detailText: planContent,
                todoItems: deduplicatedItems,
                groupID: StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["requestId"])
            )
            return StructuredAgentOutputChunk(renderedText: "[copilot] Plan updated\n", segments: [segment])
        }

        let source = (payload["todoItems"] as? [Any])
            ?? (payload["todos"] as? [Any])
            ?? (payload["plan"] as? [Any])
            ?? (payload["tasks"] as? [Any])
            ?? (payload["items"] as? [Any])
        guard normalizedType.contains("todo") || normalizedType.contains("plan") || normalizedType.contains("task") || source != nil else {
            return nil
        }
        let items = (source ?? []).compactMap(parseTodoItem(from:))
        guard !items.isEmpty else { return nil }
        let fingerprint = fingerprint(for: items)
        guard fingerprint != lastTodoFingerprint else { return StructuredAgentOutputChunk() }
        lastTodoFingerprint = fingerprint
        let segment = makeSegment(
            id: stableSegmentID(for: payload.isEmpty ? object : payload, fallbackPrefix: "copilot-todo"),
            kind: .todoList,
            title: "Plan",
            subtitle: "Copilot progress",
            todoItems: items,
            groupID: StructuredAgentOutputParserSupport.firstString(in: payload.isEmpty ? object : payload, keys: ["conversation_id", "session_id", "requestId"])
        )
        return StructuredAgentOutputChunk(renderedText: "[copilot] Plan updated\n", segments: [segment])
    }

    private func renderErrorIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let payload = eventPayload(from: object)

        if normalizedType == "tool.execution_complete" || normalizedType == "tool.completed" {
            return nil
        }

        let errorDictionary = StructuredAgentOutputParserSupport.nestedDictionary(in: payload.isEmpty ? object : payload, keys: ["error"])
        let message = StructuredAgentOutputParserSupport.firstString(in: errorDictionary ?? [:], keys: ["message", "error"])
            ?? StructuredAgentOutputParserSupport.firstString(in: payload.isEmpty ? object : payload, keys: ["error", "message"])
        guard normalizedType.contains("error") || normalizedType == "abort" || errorDictionary != nil || message != nil else { return nil }
        let text = message ?? "Copilot error"
        let segment = makeSegment(
            id: stableSegmentID(for: payload.isEmpty ? object : payload, fallbackPrefix: "copilot-error"),
            kind: .error,
            title: "Copilot error",
            bodyText: text,
            status: .failed,
            detailText: StructuredAgentOutputParserSupport.prettyPrintedString(
                from: errorDictionary ?? (payload.isEmpty ? object : payload)
            )
        )
        return StructuredAgentOutputChunk(renderedText: "[copilot] Error: \(text)\n", segments: [segment])
    }

    private func fallbackChunk(line: String) -> StructuredAgentOutputChunk {
        StructuredAgentOutputChunk(
            renderedText: line + "\n",
            segments: [
                makeSegment(
                    id: nextTransientSegmentID(prefix: "copilot-text"),
                    kind: .fallbackText,
                    title: "Log",
                    bodyText: line
                )
            ]
        )
    }

    private func eventPayload(from object: [String: Any]) -> [String: Any] {
        StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["data"]) ?? [:]
    }

    private func extractReasoningText(from object: [String: Any]) -> String? {
        rawString(in: object, keys: ["content", "deltaContent", "reasoningText", "text"])
            ?? StructuredAgentOutputParserSupport.joinedText(from: object["content"])
    }

    private func extractMessageText(from object: [String: Any], eventType: String) -> String? {
        if eventType.contains("delta") {
            return rawString(in: object, keys: ["deltaContent", "content", "text", "transformedContent"])
                ?? StructuredAgentOutputParserSupport.joinedText(from: object["delta"])
        }
        return rawString(in: object, keys: ["content", "text", "message", "response", "transformedContent"])
            ?? StructuredAgentOutputParserSupport.joinedText(from: object["parts"])
            ?? StructuredAgentOutputParserSupport.joinedText(from: object["message"])
    }

    private func extractCommand(from object: [String: Any]) -> String? {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["command", "cmd", "shell_command"])
    }

    private func parseFileChange(from value: Any) -> AgentRunSegment.ChangedFile? {
        if let path = value as? String {
            return AgentRunSegment.ChangedFile(path: path, kind: .unknown)
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        guard let path = StructuredAgentOutputParserSupport.firstString(in: dictionary, keys: ["path", "file", "name"]) else {
            return nil
        }
        let kind = AgentRunSegment.ChangedFile.Kind(rawValue: StructuredAgentOutputParserSupport.firstString(in: dictionary, keys: ["kind", "status", "change_type", "operation"]))
        return AgentRunSegment.ChangedFile(path: path, kind: kind)
    }

    private func parseTodoItem(from value: Any) -> AgentRunSegment.TodoItem? {
        if let text = value as? String {
            return AgentRunSegment.TodoItem(text: text, isCompleted: false)
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        guard let text = StructuredAgentOutputParserSupport.firstString(in: dictionary, keys: ["text", "title", "task"]) else {
            return nil
        }
        let completed = dictionary["completed"] as? Bool
            ?? dictionary["done"] as? Bool
            ?? (StructuredAgentOutputParserSupport.firstString(in: dictionary, keys: ["status", "state"])?.lowercased() == "completed")
        return AgentRunSegment.TodoItem(text: text, isCompleted: completed)
    }

    private func parsePlanContent(_ content: String?) -> [AgentRunSegment.TodoItem] {
        guard let content else { return [] }
        return content
            .components(separatedBy: .newlines)
            .compactMap(parsePlanLine(_:))
    }

    private func parsePlanSummary(_ summary: String?) -> [AgentRunSegment.TodoItem] {
        guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return [] }
        return [AgentRunSegment.TodoItem(text: summary, isCompleted: false)]
    }

    private func parsePlanLine(_ rawLine: String) -> AgentRunSegment.TodoItem? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let item = parseChecklistLine(trimmed) {
            return item
        }

        let strippedNumbering = trimmed.replacingOccurrences(
            of: #"^\d+[\.)]\s+"#,
            with: "",
            options: .regularExpression
        )
        let strippedBullet = strippedNumbering.replacingOccurrences(
            of: #"^[-*+]\s+"#,
            with: "",
            options: .regularExpression
        )
        let candidate = strippedBullet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate != trimmed || trimmed.first?.isNumber == true || ["-", "*", "+"].contains(trimmed.first.map(String.init) ?? "") else {
            return nil
        }
        return AgentRunSegment.TodoItem(text: candidate, isCompleted: false)
    }

    private func parseChecklistLine(_ line: String) -> AgentRunSegment.TodoItem? {
        let patterns: [(String, Bool)] = [
            (#"^[-*+]\s*\[(x|X)\]\s+(.+)$"#, true),
            (#"^[-*+]\s*\[\s\]\s+(.+)$"#, false),
            (#"^\[(x|X)\]\s+(.+)$"#, true),
            (#"^\[\s\]\s+(.+)$"#, false),
        ]

        for (pattern, completed) in patterns {
            if let text = line.captures(matching: pattern)?.last?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return AgentRunSegment.TodoItem(text: text, isCompleted: completed)
            }
        }
        return nil
    }

    private func fingerprint(for items: [AgentRunSegment.TodoItem]) -> String {
        items.map { "\($0.isCompleted ? "[x]" : "[ ]") \($0.text)" }.joined(separator: "\n")
    }

    private func isCommandLike(toolName: String?, command: String?) -> Bool {
        guard command == nil else { return true }
        let normalizedToolName = toolName?.lowercased() ?? ""
        return normalizedToolName.contains("bash")
            || normalizedToolName.contains("shell")
            || normalizedToolName.contains("terminal")
    }

    private func toolStatus(for type: String, payload: [String: Any]) -> AgentRunSegment.Status {
        if type == "tool.user_requested" {
            return .pending
        }
        if type == "tool.execution_progress" || type == "tool.execution_partial_result" || type == "tool.execution_start" || type == "tool.started" {
            return .running
        }
        if type == "tool.execution_complete" || type == "tool.completed" {
            if let success = payload["success"] as? Bool {
                return success ? .completed : .failed
            }
        }
        return AgentRunSegment.Status(
            rawValue: StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["status", "state"]),
            eventType: type
        )
    }

    private func messageSegmentID(for payload: [String: Any], object: [String: Any]) -> String {
        StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["messageId", "id"])
            ?? stableSegmentID(for: object, fallbackPrefix: "copilot-message")
    }

    private func reasoningSegmentID(for payload: [String: Any], object: [String: Any]) -> String {
        StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["reasoningId"])
            ?? StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["messageId"]).map { "\($0)-reasoning" }
            ?? stableSegmentID(for: object, fallbackPrefix: "copilot-reasoning")
    }

    private func toolSegmentID(for payload: [String: Any], object: [String: Any]) -> String {
        StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["toolCallId", "requestId", "id"])
            ?? stableToolSegmentID(for: object, fallbackPrefix: "copilot-tool")
    }

    private func turnSegmentID(for payload: [String: Any], object: [String: Any]) -> String {
        StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["turnId"]).map { "turn-\($0)" }
            ?? stableSegmentID(for: object, fallbackPrefix: "copilot-turn")
    }

    private func userMessageSegmentID(for payload: [String: Any], object: [String: Any]) -> String {
        StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["messageId", "id"]).map { "user-\($0)" }
            ?? StructuredAgentOutputParserSupport.firstString(in: object, keys: ["id"]).map { "user-\($0)" }
            ?? stableSegmentID(for: object, fallbackPrefix: "copilot-user-message")
    }

    private func segmentGroupID(for payload: [String: Any], object: [String: Any]) -> String? {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["parentId", "parent_id"])
            ?? StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["parentId", "parent_id", "interactionId", "parentToolCallId", "conversation_id", "session_id"])
            ?? StructuredAgentOutputParserSupport.firstString(in: object, keys: ["interactionId", "conversation_id", "session_id"])
            ?? StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["turnId"]).map { "turn-\($0)" }
            ?? StructuredAgentOutputParserSupport.firstString(in: object, keys: ["turnId"]).map { "turn-\($0)" }
    }

    private func stableSegmentID(for object: [String: Any], fallbackPrefix: String) -> String {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["id", "message_id", "messageId", "operation_id", "operation", "tool_call_id", "toolCallId", "requestId", "path"])
            ?? nextTransientSegmentID(prefix: fallbackPrefix)
    }

    private func stableToolSegmentID(for object: [String: Any], fallbackPrefix: String) -> String {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["toolCallId", "tool_call_id", "operation_id", "id"])
            ?? nextTransientSegmentID(prefix: fallbackPrefix)
    }

    private func nextTransientSegmentID(prefix: String) -> String {
        nextTransientSegmentIndex += 1
        return "\(prefix)-\(nextTransientSegmentIndex)"
    }

    private func mergedText(
        _ incoming: String,
        for id: String,
        store: inout [String: String],
        isDelta: Bool = false
    ) -> String {
        if incoming.isEmpty {
            return store[id] ?? ""
        }
        let trimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard isDelta else { return store[id] ?? "" }
            let existing = store[id] ?? ""
            let merged = existing + incoming
            store[id] = merged
            return merged
        }
        let existing = store[id] ?? ""
        let merged: String
        if existing.isEmpty || trimmed.hasPrefix(existing) {
            merged = trimmed
        } else if existing == trimmed || existing.hasSuffix(trimmed) {
            merged = existing
        } else {
            let separator = isDelta && shouldInsertSpace(between: existing, and: trimmed) ? " " : ""
            merged = existing + separator + trimmed
        }
        store[id] = merged
        return merged
    }

    private func rawString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = object[key] as? String {
                return string
            }
        }
        return nil
    }

    private func shouldInsertSpace(between existing: String, and incoming: String) -> Bool {
        guard
            let existingScalar = existing.unicodeScalars.last,
            let incomingScalar = incoming.unicodeScalars.first
        else {
            return false
        }

        if CharacterSet.whitespacesAndNewlines.contains(existingScalar)
            || CharacterSet.whitespacesAndNewlines.contains(incomingScalar) {
            return false
        }

        let wordCharacters = CharacterSet.alphanumerics
        guard wordCharacters.contains(existingScalar), wordCharacters.contains(incomingScalar) else {
            return false
        }

        return true
    }

    private func assistantMessageTitle(for phase: String?) -> String {
        switch phase {
        case "final_answer":
            "Final answer"
        case "analysis":
            "Analysis"
        case "plan":
            "Plan"
        case "thinking":
            "Thinking"
        default:
            "Antwort"
        }
    }

    private func toolRowTitle(toolName: String?, command: String?, reportIntent: String?) -> String {
        if let reportIntent {
            return reportIntent
        }
        return command ?? toolName ?? "Tool"
    }

    private func preferredToolSubtitle(from payload: [String: Any]) -> String? {
        StructuredAgentOutputParserSupport.firstString(in: payload, keys: ["intentionSummary", "mcpServerName", "server"])
    }

    private func reportIntentValue(toolName: String?, arguments: [String: Any]?) -> String? {
        guard toolName?.lowercased() == "report_intent" else { return nil }
        return StructuredAgentOutputParserSupport.firstString(in: arguments ?? [:], keys: ["intent"])
    }

    private func turnHeaderTitle(for groupID: String?, fallback: String) -> String {
        guard let groupID, let intent = latestIntentByGroupID[groupID]?.nonEmpty else {
            return fallback
        }
        return intent
    }

    private func makeSegment(
        id: String,
        kind: AgentRunSegment.Kind,
        title: String,
        subtitle: String? = nil,
        bodyText: String? = nil,
        status: AgentRunSegment.Status? = nil,
        exitCode: Int? = nil,
        detailText: String? = nil,
        aggregatedOutput: String? = nil,
        fileChanges: [AgentRunSegment.ChangedFile] = [],
        todoItems: [AgentRunSegment.TodoItem] = [],
        groupID: String? = nil
    ) -> AgentRunSegment {
        let revision = (segmentRevisions[id] ?? 0) + 1
        segmentRevisions[id] = revision
        return AgentRunSegment(
            id: id,
            sourceAgent: .githubCopilot,
            revision: revision,
            kind: kind,
            title: title,
            subtitle: subtitle,
            bodyText: bodyText,
            status: status,
            exitCode: exitCode,
            detailText: detailText,
            aggregatedOutput: aggregatedOutput,
            fileChanges: fileChanges,
            todoItems: todoItems,
            groupID: groupID
        )
    }
}

private extension Array where Element == AgentRunSegment.TodoItem {
    func removingDuplicateTodoItems() -> [Element] {
        var seen: Set<String> = []
        var result: [Element] = []
        for item in self {
            guard seen.insert("\(item.isCompleted)-\(item.text)").inserted else { continue }
            result.append(item)
        }
        return result
    }
}

private extension String {
    func captures(matching pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            let nsRange = match.range(at: index)
            guard let range = Range(nsRange, in: self) else { return nil }
            return String(self[range])
        }
    }
}
