import Foundation

final class ACPEventJSONLParser: StructuredAgentOutputParsing {
    var currentSessionID: String?
    var latestAssistantMessageText: String?

    private var bufferedLine = ""
    private var nextTransientSegmentIndex = 0
    private var segmentRevisions: [String: Int] = [:]
    private var bodyTextByID: [String: String] = [:]
    private var detailTextByID: [String: String] = [:]
    private var aggregatedOutputByID: [String: String] = [:]
    private var lastPlanFingerprint: String?

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

        let rawTool = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["tool"])
        let tool = rawTool.flatMap(AIAgentTool.init(rawValue:)) ?? .none
        currentSessionID = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["sessionId"]) ?? currentSessionID
        let eventType = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["event"]) ?? "event"

        switch eventType {
        case "session_started":
            return renderSessionStarted(object: object, tool: tool)
        case "agent_message_chunk":
            return renderAgentMessage(object: object, tool: tool)
        case "agent_thought_chunk":
            return renderReasoning(object: object, tool: tool)
        case "tool_call", "tool_call_update":
            return renderToolCall(object: object, tool: tool)
        case "plan":
            return renderPlan(object: object, tool: tool)
        case "permission_request":
            return renderPermissionRequest(object: object, tool: tool)
        case "permission_resolved":
            return renderPermissionResolved(object: object, tool: tool)
        case "prompt_finished":
            return renderPromptFinished(object: object, tool: tool)
        case "error":
            return renderError(object: object, tool: tool)
        default:
            return StructuredAgentOutputParserSupport.summarizeUnknownEvent(
                agent: tool,
                line: line,
                object: object,
                fallbackID: nextTransientSegmentID(prefix: "acp-event")
            )
        }
    }

    private func renderSessionStarted(object: [String: Any], tool: AIAgentTool) -> StructuredAgentOutputChunk {
        let sessionID = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["sessionId"]) ?? "unknown"
        let loadedExistingSession = (object["loadedExistingSession"] as? Bool) == true
        let subtitle = loadedExistingSession ? "Existing session loaded" : "New session created"
        let segment = makeSegment(
            id: "session-\(sessionID)",
            tool: tool,
            kind: .toolCall,
            title: "ACP session",
            subtitle: subtitle,
            bodyText: sessionID,
            status: .completed,
            groupID: sessionID
        )
        return StructuredAgentOutputChunk(
            renderedText: "[\(displayName(for: tool))] ACP session: \(sessionID)\n",
            segments: [segment]
        )
    }

    private func renderAgentMessage(object: [String: Any], tool: AIAgentTool) -> StructuredAgentOutputChunk {
        guard let text = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["text"]) else {
            return StructuredAgentOutputChunk()
        }
        let segmentID = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["messageId"])
            ?? "\(currentSessionID ?? "session")-assistant"
        let bodyText = mergedText(
            text,
            for: segmentID,
            store: &bodyTextByID,
            isDelta: (object["isDelta"] as? Bool) == true
        )
        latestAssistantMessageText = bodyText.nonEmpty ?? latestAssistantMessageText
        let segment = makeSegment(
            id: segmentID,
            tool: tool,
            kind: .agentMessage,
            title: "Assistant",
            bodyText: bodyText,
            groupID: currentSessionID
        )
        let renderedPrefix = (object["isDelta"] as? Bool) == true ? "" : "[\(displayName(for: tool))] "
        return StructuredAgentOutputChunk(
            renderedText: renderedPrefix + text + (renderedPrefix.isEmpty ? "" : "\n"),
            segments: [segment]
        )
    }

    private func renderReasoning(object: [String: Any], tool: AIAgentTool) -> StructuredAgentOutputChunk {
        guard let text = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["text"]) else {
            return StructuredAgentOutputChunk()
        }
        let segmentID = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["messageId"])
            ?? "\(currentSessionID ?? "session")-reasoning"
        let bodyText = mergedText(
            text,
            for: segmentID,
            store: &bodyTextByID,
            isDelta: (object["isDelta"] as? Bool) == true
        )
        let segment = makeSegment(
            id: segmentID,
            tool: tool,
            kind: .reasoning,
            title: "Thinking",
            bodyText: bodyText,
            groupID: currentSessionID
        )
        let renderedPrefix = (object["isDelta"] as? Bool) == true ? "" : "[\(displayName(for: tool))] Thinking: "
        return StructuredAgentOutputChunk(
            renderedText: renderedPrefix + text + (renderedPrefix.isEmpty ? "" : "\n"),
            segments: [segment]
        )
    }

    private func renderToolCall(object: [String: Any], tool: AIAgentTool) -> StructuredAgentOutputChunk {
        let segmentID = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["toolCallId"])
            ?? nextTransientSegmentID(prefix: "acp-tool")
        let title = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["title"]) ?? "Tool"
        let subtitle = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["kind"])
        let status = AgentRunSegment.Status(
            rawValue: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["status"]),
            eventType: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["event"]) ?? "tool_call_update"
        )
        let detailText = StructuredAgentOutputParserSupport.prettyPrintedString(from: object["input"])
            .flatMap { mergedText($0, for: "\(segmentID)-detail", store: &detailTextByID, isDelta: false) }
        let aggregatedOutput = StructuredAgentOutputParserSupport.prettyPrintedString(from: object["output"])
            .flatMap { mergedText($0, for: "\(segmentID)-output", store: &aggregatedOutputByID, isDelta: false) }
        let segment = makeSegment(
            id: segmentID,
            tool: tool,
            kind: .toolCall,
            title: title,
            subtitle: subtitle,
            status: status,
            detailText: detailText,
            aggregatedOutput: aggregatedOutput,
            groupID: currentSessionID
        )
        let rendered = "[\(displayName(for: tool))] Tool \(title) \(status.displayText.lowercased())\n"
        return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
    }

    private func renderPlan(object: [String: Any], tool: AIAgentTool) -> StructuredAgentOutputChunk {
        let entries = (object["entries"] as? [[String: Any]] ?? []).compactMap { entry -> AgentRunSegment.TodoItem? in
            guard let text = StructuredAgentOutputParserSupport.firstString(in: entry, keys: ["content"]) else {
                return nil
            }
            let status = StructuredAgentOutputParserSupport.firstString(in: entry, keys: ["status"])?.lowercased()
            return AgentRunSegment.TodoItem(
                text: text,
                isCompleted: status == "completed" || status == "done" || status == "success"
            )
        }
        guard !entries.isEmpty else { return StructuredAgentOutputChunk() }
        let fingerprint = entries.map { "\($0.isCompleted ? "[x]" : "[ ]") \($0.text)" }.joined(separator: "\n")
        guard fingerprint != lastPlanFingerprint else { return StructuredAgentOutputChunk() }
        lastPlanFingerprint = fingerprint
        let segment = makeSegment(
            id: "\(currentSessionID ?? "session")-plan",
            tool: tool,
            kind: .todoList,
            title: "Plan updated",
            subtitle: "\(entries.count) step\(entries.count == 1 ? "" : "s")",
            todoItems: entries,
            groupID: currentSessionID
        )
        return StructuredAgentOutputChunk(
            renderedText: "[\(displayName(for: tool))] Plan updated\n",
            segments: [segment]
        )
    }

    private func renderPermissionRequest(object: [String: Any], tool: AIAgentTool) -> StructuredAgentOutputChunk {
        let title = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["title"]) ?? "Permission required"
        let bodyText = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["message", "body"])
        let detailText = StructuredAgentOutputParserSupport.prettyPrintedString(from: object["options"])
        let segment = makeSegment(
            id: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["requestId"])
                ?? nextTransientSegmentID(prefix: "acp-permission"),
            tool: tool,
            kind: .toolCall,
            title: title,
            subtitle: "Waiting for approval",
            bodyText: bodyText,
            status: .pending,
            detailText: detailText,
            groupID: currentSessionID
        )
        return StructuredAgentOutputChunk(
            renderedText: "[\(displayName(for: tool))] Permission required: \(title)\n",
            segments: [segment]
        )
    }

    private func renderPermissionResolved(object: [String: Any], tool: AIAgentTool) -> StructuredAgentOutputChunk {
        let selectedOption = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["selectedOptionName"]) ?? "Permission updated"
        let segment = makeSegment(
            id: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["requestId"])
                ?? nextTransientSegmentID(prefix: "acp-permission-result"),
            tool: tool,
            kind: .toolCall,
            title: "Permission response",
            subtitle: selectedOption,
            status: .completed,
            groupID: currentSessionID
        )
        return StructuredAgentOutputChunk(
            renderedText: "[\(displayName(for: tool))] Permission response: \(selectedOption)\n",
            segments: [segment]
        )
    }

    private func renderPromptFinished(object: [String: Any], tool: AIAgentTool) -> StructuredAgentOutputChunk {
        let stopReason = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["stopReason"]) ?? "unknown"
        let segment = makeSegment(
            id: "\(currentSessionID ?? "session")-prompt-finished",
            tool: tool,
            kind: .toolCall,
            title: "Prompt finished",
            subtitle: stopReason,
            status: .completed,
            groupID: currentSessionID
        )
        return StructuredAgentOutputChunk(
            renderedText: "[\(displayName(for: tool))] Prompt finished: \(stopReason)\n",
            segments: [segment]
        )
    }

    private func renderError(object: [String: Any], tool: AIAgentTool) -> StructuredAgentOutputChunk {
        let message = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["message", "error"]) ?? "ACP error"
        let segment = makeSegment(
            id: nextTransientSegmentID(prefix: "acp-error"),
            tool: tool,
            kind: .error,
            title: "\(tool.displayName) error",
            bodyText: message,
            status: .failed,
            detailText: StructuredAgentOutputParserSupport.prettyPrintedString(from: object)
        )
        return StructuredAgentOutputChunk(
            renderedText: "[\(displayName(for: tool))] Error: \(message)\n",
            segments: [segment]
        )
    }

    private func fallbackChunk(line: String) -> StructuredAgentOutputChunk {
        StructuredAgentOutputChunk(
            renderedText: line + "\n",
            segments: [
                AgentRunSegment(
                    id: nextTransientSegmentID(prefix: "acp-text"),
                    sourceAgent: .none,
                    revision: 1,
                    kind: .fallbackText,
                    title: "ACP output",
                    bodyText: line
                )
            ]
        )
    }

    private func makeSegment(
        id: String,
        tool: AIAgentTool,
        kind: AgentRunSegment.Kind,
        title: String,
        subtitle: String? = nil,
        bodyText: String? = nil,
        status: AgentRunSegment.Status? = nil,
        detailText: String? = nil,
        aggregatedOutput: String? = nil,
        todoItems: [AgentRunSegment.TodoItem] = [],
        groupID: String? = nil
    ) -> AgentRunSegment {
        let revision = (segmentRevisions[id] ?? 0) + 1
        segmentRevisions[id] = revision
        return AgentRunSegment(
            id: id,
            sourceAgent: tool,
            revision: revision,
            kind: kind,
            title: title,
            subtitle: subtitle,
            bodyText: bodyText,
            status: status,
            detailText: detailText,
            aggregatedOutput: aggregatedOutput,
            todoItems: todoItems,
            groupID: groupID
        )
    }

    private func mergedText(
        _ incoming: String,
        for id: String,
        store: inout [String: String],
        isDelta: Bool
    ) -> String {
        let trimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isDelta {
            store[id] = trimmed
            return trimmed
        }
        let merged = (store[id] ?? "") + incoming
        store[id] = merged
        return merged
    }

    private func nextTransientSegmentID(prefix: String) -> String {
        nextTransientSegmentIndex += 1
        return "\(prefix)-\(nextTransientSegmentIndex)"
    }

    private func displayName(for tool: AIAgentTool) -> String {
        switch tool {
        case .none:
            "acp"
        default:
            tool.displayName.lowercased()
        }
    }
}
