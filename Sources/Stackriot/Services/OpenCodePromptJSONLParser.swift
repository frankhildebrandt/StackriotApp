import Foundation

final class OpenCodePromptJSONLParser: StructuredAgentOutputParsing {
    private var bufferedLine = ""
    private var nextTransientSegmentIndex = 0
    private var segmentRevisions: [String: Int] = [:]
    private var bodyTextByID: [String: String] = [:]
    private var detailTextByID: [String: String] = [:]
    private var aggregatedOutputByID: [String: String] = [:]

    var currentSessionID: String?
    var latestAssistantMessageText: String?

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
        if let sessionID = currentSessionID?.nonEmpty {
            parsed.renderedText += "[opencode] Resume: opencode run --session \(sessionID)\n"
        }
        return parsed
    }

    private func render(line rawLine: String) -> StructuredAgentOutputChunk {
        let line = rawLine.replacingOccurrences(of: "\r", with: "")
        guard !line.isEmpty else { return StructuredAgentOutputChunk(renderedText: "\n") }
        guard let object = StructuredAgentOutputParserSupport.jsonObject(from: line) else {
            return fallbackChunk(line: line)
        }

        let part = (object["part"] as? [String: Any]) ?? [:]
        currentSessionID = StructuredAgentOutputParserSupport.firstString(
            in: object,
            keys: ["sessionID", "session_id", "sessionId", "id"]
        ) ?? StructuredAgentOutputParserSupport.firstString(
            in: part,
            keys: ["sessionID", "session_id", "sessionId"]
        ) ?? currentSessionID

        let type = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["type", "event", "kind"]) ?? "event"
        let normalizedType = type.lowercased()

        switch normalizedType {
        case "text":
            return renderText(part: part)
        case "tool_use":
            return renderToolUse(part: part, type: type)
        case "step_start":
            return renderStepBoundary(part: part, type: type, isStart: true)
        case "step_finish":
            return renderStepBoundary(part: part, type: type, isStart: false)
        case "error":
            return renderError(object: object, type: type)
        default:
            return StructuredAgentOutputParserSupport.summarizeUnknownEvent(
                agent: .openCode,
                line: line,
                object: object,
                fallbackID: nextTransientSegmentID(prefix: "opencode-event")
            )
        }
    }

    private func renderText(part: [String: Any]) -> StructuredAgentOutputChunk {
        guard let text = StructuredAgentOutputParserSupport.firstString(in: part, keys: ["text"]) else {
            return StructuredAgentOutputChunk()
        }
        let segmentID = stableSegmentID(for: part, fallbackPrefix: "opencode-text")
        let bodyText = mergedText(text, for: segmentID)
        latestAssistantMessageText = bodyText.nonEmpty ?? latestAssistantMessageText
        let segment = makeSegment(
            id: segmentID,
            kind: .agentMessage,
            title: "Antwort",
            bodyText: bodyText,
            groupID: currentSessionID
        )
        return StructuredAgentOutputChunk(renderedText: "[opencode] \(text)\n", segments: [segment])
    }

    private func renderToolUse(part: [String: Any], type: String) -> StructuredAgentOutputChunk {
        let state = (part["state"] as? [String: Any]) ?? [:]
        let tool = StructuredAgentOutputParserSupport.firstString(in: part, keys: ["tool"]) ?? "tool"
        let title = StructuredAgentOutputParserSupport.firstString(in: state, keys: ["title"]) ?? tool
        let input = StructuredAgentOutputParserSupport.prettyPrintedString(from: state["input"])
        let output = StructuredAgentOutputParserSupport.prettyPrintedString(from: state["output"])
        let metadata = StructuredAgentOutputParserSupport.prettyPrintedString(from: state["metadata"])
        let detail = [input, metadata].compactMap(\.self).joined(separator: "\n\n").nonEmpty
        let segmentID = stableSegmentID(for: part, fallbackPrefix: "opencode-tool")

        if let detail {
            _ = mergedText(detail, for: "\(segmentID)-detail", store: &detailTextByID)
        }
        if let output {
            _ = mergedText(output, for: "\(segmentID)-output", store: &aggregatedOutputByID)
        }

        let segment = makeSegment(
            id: segmentID,
            kind: .toolCall,
            title: title,
            subtitle: tool == title ? nil : tool,
            status: .init(rawValue: StructuredAgentOutputParserSupport.firstString(in: state, keys: ["status"]), eventType: type),
            detailText: detailTextByID["\(segmentID)-detail"]?.nonEmpty,
            aggregatedOutput: aggregatedOutputByID["\(segmentID)-output"]?.nonEmpty,
            groupID: currentSessionID
        )
        return StructuredAgentOutputChunk(
            renderedText: "[opencode] \(title) \(segment.status?.displayText.lowercased() ?? "updated")\n",
            segments: [segment]
        )
    }

    private func renderStepBoundary(part: [String: Any], type: String, isStart: Bool) -> StructuredAgentOutputChunk {
        let reason = StructuredAgentOutputParserSupport.firstString(in: part, keys: ["reason"])
        if !isStart, reason?.lowercased() == "tool-calls" {
            return StructuredAgentOutputChunk()
        }

        let title = isStart ? "Step started" : "Step finished"
        let segment = makeSegment(
            id: stableSegmentID(for: part, fallbackPrefix: isStart ? "opencode-step-start" : "opencode-step-finish"),
            kind: .toolCall,
            title: title,
            subtitle: reason,
            status: .init(rawValue: isStart ? "running" : "completed", eventType: type),
            detailText: StructuredAgentOutputParserSupport.prettyPrintedString(from: part["tokens"]),
            groupID: currentSessionID
        )
        let rendered = isStart ? "[opencode] Step started\n" : "[opencode] Step finished\n"
        return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
    }

    private func renderError(object: [String: Any], type: String) -> StructuredAgentOutputChunk {
        let errorObject = (object["error"] as? [String: Any]) ?? [:]
        let errorData = (errorObject["data"] as? [String: Any]) ?? [:]
        let message = StructuredAgentOutputParserSupport.firstString(
            in: errorData,
            keys: ["message", "error", "detail"]
        ) ?? StructuredAgentOutputParserSupport.firstString(
            in: errorObject,
            keys: ["message", "name"]
        ) ?? "OpenCode error"
        let segment = makeSegment(
            id: nextTransientSegmentID(prefix: "opencode-error"),
            kind: .error,
            title: "OpenCode error",
            bodyText: message,
            status: .init(rawValue: "failed", eventType: type),
            detailText: StructuredAgentOutputParserSupport.prettyPrintedString(from: errorObject),
            groupID: currentSessionID
        )
        return StructuredAgentOutputChunk(renderedText: "[opencode] Error: \(message)\n", segments: [segment])
    }

    private func fallbackChunk(line: String) -> StructuredAgentOutputChunk {
        StructuredAgentOutputChunk(
            renderedText: line + "\n",
            segments: [
                makeSegment(
                    id: nextTransientSegmentID(prefix: "opencode-text"),
                    kind: .fallbackText,
                    title: "Log",
                    bodyText: line,
                    groupID: currentSessionID
                )
            ]
        )
    }

    private func stableSegmentID(for object: [String: Any], fallbackPrefix: String) -> String {
        if let id = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["id", "callID", "callId", "messageID", "messageId"]) {
            return id
        }
        return nextTransientSegmentID(prefix: fallbackPrefix)
    }

    private func nextTransientSegmentID(prefix: String) -> String {
        nextTransientSegmentIndex += 1
        return "\(prefix)-\(nextTransientSegmentIndex)"
    }

    private func mergedText(
        _ text: String,
        for id: String,
        store: inout [String: String]
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store[id] ?? "" }
        if let existing = store[id]?.nonEmpty {
            let merged = [existing, trimmed].joined(separator: "\n\n")
            store[id] = merged
            return merged
        }
        store[id] = trimmed
        return trimmed
    }

    private func mergedText(_ text: String, for id: String) -> String {
        mergedText(text, for: id, store: &bodyTextByID)
    }

    private func makeSegment(
        id: String,
        kind: AgentRunSegment.Kind,
        title: String,
        subtitle: String? = nil,
        bodyText: String? = nil,
        status: AgentRunSegment.Status? = nil,
        detailText: String? = nil,
        aggregatedOutput: String? = nil,
        groupID: String? = nil
    ) -> AgentRunSegment {
        let revision = (segmentRevisions[id] ?? 0) + 1
        segmentRevisions[id] = revision
        return AgentRunSegment(
            id: id,
            sourceAgent: .openCode,
            revision: revision,
            kind: kind,
            title: title,
            subtitle: subtitle,
            bodyText: bodyText,
            status: status,
            detailText: detailText,
            aggregatedOutput: aggregatedOutput,
            groupID: groupID
        )
    }
}
