import Foundation

final class CursorAgentPrintJSONParser: StructuredAgentOutputParsing {
    private var bufferedLine = ""
    private var nextTransientSegmentIndex = 0
    private var segmentRevisions: [String: Int] = [:]
    private var bodyTextByID: [String: String] = [:]
    private var detailTextByID: [String: String] = [:]
    private var aggregatedOutputByID: [String: String] = [:]

    var currentSessionID: String?
    var latestResultText: String?

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
            parsed.renderedText += "[cursor] Resume: cursor-agent --resume \(sessionID)\n"
        }
        return parsed
    }

    private func render(line rawLine: String) -> StructuredAgentOutputChunk {
        let line = rawLine.replacingOccurrences(of: "\r", with: "")
        guard !line.isEmpty else { return StructuredAgentOutputChunk(renderedText: "\n") }
        guard let object = StructuredAgentOutputParserSupport.jsonObject(from: line) else {
            return fallbackChunk(line: line)
        }

        currentSessionID = StructuredAgentOutputParserSupport.firstString(
            in: object,
            keys: ["session_id", "sessionId", "chat_id", "chatId", "id"]
        ) ?? currentSessionID

        let type = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["type", "event", "kind"]) ?? "event"

        if let errorChunk = renderErrorIfNeeded(type: type, object: object) {
            return errorChunk
        }
        if let toolCallChunk = renderCursorToolCallIfNeeded(type: type, object: object) {
            return toolCallChunk
        }
        if let toolChunk = renderToolEventIfNeeded(type: type, object: object) {
            return toolChunk
        }
        if let messageChunk = renderMessageIfNeeded(type: type, object: object) {
            return messageChunk
        }
        if currentSessionID != nil, object.keys.allSatisfy({ ["type", "event", "kind", "session_id", "sessionId", "chat_id", "chatId", "id", "status"].contains($0) }) {
            return StructuredAgentOutputChunk()
        }

        return StructuredAgentOutputParserSupport.summarizeUnknownEvent(
            agent: .cursorCLI,
            line: line,
            object: object,
            fallbackID: nextTransientSegmentID(prefix: "cursor-event")
        )
    }

    private func renderMessageIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let subtypeLower = (StructuredAgentOutputParserSupport.firstString(in: object, keys: ["subtype"]) ?? "").lowercased()
        let isThinking = normalizedType.contains("thinking") || normalizedType.contains("reason")
        let isPartial = subtypeLower.contains("delta") || normalizedType.contains("delta") || normalizedType.contains("partial")

        let hint: SegmentStreamHint = isThinking ? .thinking : .assistant
        let segmentID = stableSegmentID(for: object, fallbackPrefix: "cursor-message", hint: hint)

        if let text = extractText(from: object) {
            let bodyText = mergedText(text, for: segmentID, store: &bodyTextByID)
            latestResultText = bodyText

            let kind: AgentRunSegment.Kind = isThinking ? .reasoning : .agentMessage
            let title = kind == .reasoning ? "Reasoning" : "Antwort"
            let status = thinkingOrMessageStatus(
                isThinking: isThinking,
                subtypeLower: subtypeLower,
                object: object,
                type: type,
                isPartial: isPartial
            )
            let segment = makeSegment(
                id: segmentID,
                kind: kind,
                title: title,
                bodyText: bodyText,
                status: status,
                groupID: currentSessionID
            )

            let renderedText: String
            if isPartial {
                renderedText = text
            } else if kind == .reasoning {
                renderedText = "[cursor] Reasoning: \(text)\n"
            } else {
                renderedText = "[cursor] \(text)\n"
            }
            return StructuredAgentOutputChunk(renderedText: renderedText, segments: [segment])
        }

        if isThinking, subtypeLower.contains("completed") {
            let bodyText = bodyTextByID[segmentID] ?? ""
            latestResultText = bodyText.nonEmpty ?? latestResultText
            let segment = makeSegment(
                id: segmentID,
                kind: .reasoning,
                title: "Reasoning",
                bodyText: bodyText.nonEmpty,
                status: .completed,
                groupID: currentSessionID
            )
            return StructuredAgentOutputChunk(renderedText: "[cursor] Reasoning completed\n", segments: [segment])
        }

        return nil
    }

    private func thinkingOrMessageStatus(
        isThinking: Bool,
        subtypeLower: String,
        object: [String: Any],
        type: String,
        isPartial: Bool
    ) -> AgentRunSegment.Status? {
        if isThinking {
            if subtypeLower.contains("completed") { return .completed }
            if subtypeLower.contains("delta") || isPartial { return .running }
        } else if isPartial {
            return .running
        }
        return AgentRunSegment.Status(
            rawValue: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["status", "state"]),
            eventType: type
        )
    }

    private func renderCursorToolCallIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        guard normalizedType == "tool_call" || object["tool_call"] != nil else { return nil }

        let segmentID = stableSegmentID(for: object, fallbackPrefix: "cursor-tool", hint: .generic)
        let subtypeLower = (StructuredAgentOutputParserSupport.firstString(in: object, keys: ["subtype"]) ?? "").lowercased()

        guard let parsed = parseNestedToolCall(from: object) else {
            let segment = makeSegment(
                id: segmentID,
                kind: .toolCall,
                title: "Tool",
                status: cursorToolCallStatus(subtypeLower: subtypeLower, hasError: false),
                groupID: currentSessionID
            )
            return StructuredAgentOutputChunk(renderedText: "[cursor] Tool \(segment.status?.displayText.lowercased() ?? "updated")\n", segments: [segment])
        }

        let hasError = parsed.hasError
        let status = cursorToolCallStatus(subtypeLower: subtypeLower, hasError: hasError)

        if let detail = parsed.detailSnippet {
            _ = mergedText(detail, for: segmentID, store: &detailTextByID)
        }
        if let output = parsed.outputSnippet {
            _ = mergedText(output, for: segmentID, store: &aggregatedOutputByID)
        }

        let detailText = detailTextByID[segmentID]?.nonEmpty
        let aggregatedOutput = aggregatedOutputByID[segmentID]?.nonEmpty

        let segment = makeSegment(
            id: segmentID,
            kind: .toolCall,
            title: parsed.title,
            subtitle: parsed.subtitle,
            status: status,
            detailText: detailText,
            aggregatedOutput: aggregatedOutput,
            groupID: currentSessionID
        )

        let rendered = "[cursor] \(parsed.title) \(segment.status?.displayText.lowercased() ?? "updated")\n"
        return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
    }

    private struct ParsedNestedToolCall {
        let title: String
        let subtitle: String?
        let detailSnippet: String?
        let outputSnippet: String?
        let hasError: Bool
    }

    private func parseNestedToolCall(from object: [String: Any]) -> ParsedNestedToolCall? {
        guard let toolCallDict = object["tool_call"] as? [String: Any] else { return nil }
        for (key, value) in toolCallDict {
            guard let inner = value as? [String: Any] else { continue }
            let title = key
            var detailSnippet: String?
            if let args = inner["args"] {
                detailSnippet = StructuredAgentOutputParserSupport.prettyPrintedString(from: args)
            }
            var outputSnippet: String?
            var hasError = false
            if let result = inner["result"] {
                outputSnippet = StructuredAgentOutputParserSupport.prettyPrintedString(from: result)
                if let resultDict = result as? [String: Any], resultDict["error"] != nil {
                    hasError = true
                }
            }
            return ParsedNestedToolCall(
                title: title,
                subtitle: nil,
                detailSnippet: detailSnippet,
                outputSnippet: outputSnippet,
                hasError: hasError
            )
        }
        return nil
    }

    private func cursorToolCallStatus(subtypeLower: String, hasError: Bool) -> AgentRunSegment.Status {
        if hasError { return .failed }
        if subtypeLower.contains("started") || subtypeLower.contains("start") { return .running }
        if subtypeLower.contains("completed") || subtypeLower.contains("complete") { return .completed }
        return .unknown
    }

    private func renderToolEventIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        if normalizedType == "tool_call" || object["tool_call"] != nil {
            return nil
        }
        let toolName = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["tool_name", "tool", "name"])
        let command = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["command", "cmd", "shell_command"])
            ?? StructuredAgentOutputParserSupport.firstString(
                in: StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["input", "arguments"]) ?? [:],
                keys: ["command", "cmd", "shell_command"]
            )
        guard toolName != nil || command != nil || normalizedType.contains("tool") || normalizedType.contains("bash") || normalizedType.contains("command") else {
            return nil
        }

        let segmentID = stableSegmentID(for: object, fallbackPrefix: "cursor-tool", hint: .generic)
        let isCommand = command != nil || toolName?.lowercased().contains("bash") == true || toolName?.lowercased().contains("shell") == true
        let detailText = StructuredAgentOutputParserSupport.prettyPrintedString(
            from: StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["input", "arguments"])
        ).flatMap { mergedText($0, for: segmentID, store: &detailTextByID) }
        let aggregatedOutput = StructuredAgentOutputParserSupport.prettyPrintedString(from: object["output"] ?? object["result"])
            .flatMap { mergedText($0, for: segmentID, store: &aggregatedOutputByID) }
        let segment = makeSegment(
            id: segmentID,
            kind: isCommand ? .commandExecution : .toolCall,
            title: command ?? toolName ?? "Tool",
            subtitle: isCommand ? toolName : command,
            status: .init(
                rawValue: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["status", "state"]),
                eventType: type
            ),
            exitCode: object["exit_code"] as? Int,
            detailText: isCommand ? nil : detailText,
            aggregatedOutput: isCommand ? aggregatedOutput : nil,
            groupID: toolName
        )

        let renderedTitle = isCommand ? "$ \(command ?? toolName ?? "command")" : "Tool \(toolName ?? command ?? "tool")"
        let rendered = normalizedType.contains("start") || normalizedType.contains("running")
            ? "[cursor] \(renderedTitle)\n"
            : "[cursor] \(renderedTitle) \(segment.status?.displayText.lowercased() ?? "updated")\n"
        return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
    }

    private func renderErrorIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let errorDictionary = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["error"])
        let explicitError = StructuredAgentOutputParserSupport.firstString(in: errorDictionary ?? [:], keys: ["message", "error"])
            ?? StructuredAgentOutputParserSupport.firstString(in: object, keys: ["error"])
        let message = explicitError
            ?? (normalizedType.contains("error")
                ? StructuredAgentOutputParserSupport.firstString(in: object, keys: ["message", "response"])
                : nil)
        guard normalizedType.contains("error") || errorDictionary != nil || explicitError != nil else { return nil }
        let text = message ?? "Cursor error"
        let segment = makeSegment(
            id: stableSegmentID(for: object, fallbackPrefix: "cursor-error", hint: .generic),
            kind: .error,
            title: "Cursor error",
            bodyText: text,
            status: .failed,
            detailText: StructuredAgentOutputParserSupport.prettyPrintedString(from: errorDictionary ?? object)
        )
        return StructuredAgentOutputChunk(renderedText: "[cursor] Error: \(text)\n", segments: [segment])
    }

    private func extractText(from object: [String: Any]) -> String? {
        if let text = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["result", "output", "response", "message", "text"]) {
            return text
        }
        if let delta = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["delta"]),
           let text = StructuredAgentOutputParserSupport.joinedText(from: delta) {
            return text
        }
        if let message = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["message"]),
           let text = StructuredAgentOutputParserSupport.joinedText(from: message["content"] ?? message["text"] ?? message["message"]) {
            return text
        }
        if let content = object["content"] {
            return StructuredAgentOutputParserSupport.joinedText(from: content)
        }
        return nil
    }

    private enum SegmentStreamHint {
        case thinking
        case assistant
        case generic
    }

    private func stableSegmentID(for object: [String: Any], fallbackPrefix: String, hint: SegmentStreamHint = .generic) -> String {
        if let callId = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["call_id", "callId"]) {
            return callId
        }
        if let modelCallId = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["model_call_id", "modelCallId"]) {
            return modelCallId
        }
        if let existing = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["message_id", "tool_use_id"]) {
            return existing
        }
        if let id = object["id"] as? String, !id.isEmpty {
            return id
        }
        if let mid = StructuredAgentOutputParserSupport.firstString(
            in: StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["message"]) ?? [:],
            keys: ["id"]
        ) {
            return mid
        }
        let session = currentSessionID ?? "nosession"
        switch hint {
        case .thinking:
            return "\(session)-thinking"
        case .assistant:
            return "\(session)-assistant"
        case .generic:
            return nextTransientSegmentID(prefix: fallbackPrefix)
        }
    }

    private func nextTransientSegmentID(prefix: String) -> String {
        nextTransientSegmentIndex += 1
        return "\(prefix)-\(nextTransientSegmentIndex)"
    }

    private func mergedText(_ incoming: String, for id: String, store: inout [String: String]) -> String {
        if incoming.isEmpty {
            return store[id] ?? ""
        }
        let trimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, !incoming.isEmpty {
            let existing = store[id] ?? ""
            let merged = existing + incoming
            store[id] = merged
            return merged
        }
        guard !trimmed.isEmpty else { return store[id] ?? "" }
        let existing = store[id] ?? ""
        let merged: String
        if existing.isEmpty || trimmed.hasPrefix(existing) {
            merged = trimmed
        } else if existing == trimmed || existing.hasSuffix(trimmed) {
            merged = existing
        } else {
            merged = existing + trimmed
        }
        store[id] = merged
        return merged
    }

    private func fallbackChunk(line: String) -> StructuredAgentOutputChunk {
        StructuredAgentOutputChunk(
            renderedText: line + "\n",
            segments: [
                makeSegment(
                    id: nextTransientSegmentID(prefix: "cursor-text"),
                    kind: .fallbackText,
                    title: "Cursor output",
                    bodyText: line
                )
            ]
        )
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
        groupID: String? = nil
    ) -> AgentRunSegment {
        let revision = (segmentRevisions[id] ?? 0) + 1
        segmentRevisions[id] = revision
        return AgentRunSegment(
            id: id,
            sourceAgent: .cursorCLI,
            revision: revision,
            kind: kind,
            title: title,
            subtitle: subtitle,
            bodyText: bodyText,
            status: status,
            exitCode: exitCode,
            detailText: detailText,
            aggregatedOutput: aggregatedOutput,
            groupID: groupID
        )
    }
}
