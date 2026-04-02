import Foundation

final class ClaudePrintStreamJSONParser: StructuredAgentOutputParsing {
    var currentSessionID: String?
    var latestAssistantMessageText: String?

    private var bufferedLine = ""
    private var nextTransientSegmentIndex = 0
    private var segmentRevisions: [String: Int] = [:]
    private var bodyTextByID: [String: String] = [:]
    private var detailTextByID: [String: String] = [:]
    private var aggregatedOutputByID: [String: String] = [:]
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

        currentSessionID = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["session_id", "sessionId"])
            ?? currentSessionID

        let type = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["type", "event", "kind"]) ?? "event"

        if let errorChunk = renderErrorIfNeeded(type: type, object: object) {
            return errorChunk
        }
        if let todoChunk = renderTodoIfNeeded(type: type, object: object) {
            return todoChunk
        }
        if let toolChunk = renderToolEventIfNeeded(type: type, object: object) {
            return toolChunk
        }
        if let reasoningChunk = renderReasoningIfNeeded(type: type, object: object) {
            return reasoningChunk
        }
        if let messageChunk = renderMessageIfNeeded(type: type, object: object) {
            return messageChunk
        }

        return StructuredAgentOutputParserSupport.summarizeUnknownEvent(
            agent: .claudeCode,
            line: line,
            object: object,
            fallbackID: nextTransientSegmentID(prefix: "claude-event")
        )
    }

    private func renderMessageIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let explicitRole = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["role"])
        let message = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["message"])
        let messageRole = StructuredAgentOutputParserSupport.firstString(in: message ?? [:], keys: ["role"])
        let role = explicitRole ?? messageRole
        let hasAssistantRole = role?.lowercased() == "assistant"
        let looksLikeAssistantEvent = hasAssistantRole || normalizedType.contains("assistant") || normalizedType.contains("message") || normalizedType.contains("content_block")
        guard looksLikeAssistantEvent else { return nil }

        guard let text = extractText(from: object) else { return nil }
        let segmentID = stableSegmentID(for: object, fallbackPrefix: "claude-message")
        let bodyText = mergedText(text, for: segmentID, store: &bodyTextByID)
        latestAssistantMessageText = bodyText.nonEmpty ?? latestAssistantMessageText
        let segment = makeSegment(
            id: segmentID,
            kind: .agentMessage,
            title: "Antwort",
            bodyText: bodyText,
            status: .init(rawValue: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["status"]), eventType: type),
            groupID: messageGroupID(for: object)
        )
        let renderedPrefix = normalizedType.contains("delta") || normalizedType.contains("partial") ? "" : "[claude] "
        return StructuredAgentOutputChunk(renderedText: renderedPrefix + text + (renderedPrefix.isEmpty ? "" : "\n"), segments: [segment])
    }

    private func renderReasoningIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        if normalizedType.contains("thinking") || normalizedType.contains("reason") {
            guard let text = extractText(from: object) else { return nil }
            let segmentID = stableSegmentID(for: object, fallbackPrefix: "claude-thinking")
            let bodyText = mergedText(text, for: segmentID, store: &bodyTextByID)
            let segment = makeSegment(id: segmentID, kind: .reasoning, title: "Thinking", bodyText: bodyText, groupID: messageGroupID(for: object))
            return StructuredAgentOutputChunk(renderedText: "[claude] Thinking: \(text)\n", segments: [segment])
        }

        let content = extractContentEntries(from: object)
        let texts = content.compactMap { entry -> String? in
            let type = entryType(entry)
            guard type.contains("thinking") else { return nil }
            return StructuredAgentOutputParserSupport.joinedText(from: entry)
        }
        guard let text = texts.joined(separator: "\n").nonEmpty else { return nil }
        let segmentID = stableSegmentID(for: object, fallbackPrefix: "claude-thinking")
        let bodyText = mergedText(text, for: segmentID, store: &bodyTextByID)
        let segment = makeSegment(id: segmentID, kind: .reasoning, title: "Thinking", bodyText: bodyText, groupID: messageGroupID(for: object))
        return StructuredAgentOutputChunk(renderedText: "[claude] Thinking: \(text)\n", segments: [segment])
    }

    private func renderToolEventIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let content = extractContentEntries(from: object)

        if let toolEntry = content.first(where: { entryType($0).contains("tool") || entryType($0).contains("bash") }) {
            return renderToolEntry(type: type, object: object, toolEntry: toolEntry)
        }

        let toolName = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["tool_name", "tool", "name"])
        let input = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["input", "arguments"])
        let command = toolName == nil ? extractCommand(from: object) : (extractCommand(from: input ?? [:]) ?? extractCommand(from: object))
        guard toolName != nil || command != nil || normalizedType.contains("tool") || normalizedType.contains("bash") else {
            return nil
        }

        let segmentID = stableToolSegmentID(for: object, fallbackPrefix: "claude-tool")
        return renderToolSegment(
            type: type,
            object: object,
            segmentID: segmentID,
            toolName: toolName,
            command: command,
            detailCandidate: StructuredAgentOutputParserSupport.prettyPrintedString(from: input),
            outputCandidate: StructuredAgentOutputParserSupport.prettyPrintedString(from: object["result"])
                ?? StructuredAgentOutputParserSupport.prettyPrintedString(from: object["output"]),
            exitCode: object["exit_code"] as? Int
        )
    }

    private func renderToolEntry(type: String, object: [String: Any], toolEntry: [String: Any]) -> StructuredAgentOutputChunk {
        let mergedObject = toolEntry.merging(object) { current, _ in current }
        let segmentID = stableToolSegmentID(for: mergedObject, fallbackPrefix: "claude-tool")
        let toolName = StructuredAgentOutputParserSupport.firstString(in: toolEntry, keys: ["name", "tool_name", "tool"]) ?? "Tool"
        let command = extractCommand(from: toolEntry)
        return renderToolSegment(
            type: type,
            object: mergedObject,
            segmentID: segmentID,
            toolName: toolName,
            command: command,
            detailCandidate: StructuredAgentOutputParserSupport.prettyPrintedString(from: toolEntry["input"])
                ?? StructuredAgentOutputParserSupport.prettyPrintedString(from: toolEntry["arguments"]),
            outputCandidate: StructuredAgentOutputParserSupport.prettyPrintedString(from: toolEntry["output"])
                ?? StructuredAgentOutputParserSupport.prettyPrintedString(from: toolEntry["result"]),
            exitCode: toolEntry["exit_code"] as? Int
        )
    }

    private func renderToolSegment(
        type: String,
        object: [String: Any],
        segmentID: String,
        toolName: String?,
        command: String?,
        detailCandidate: String?,
        outputCandidate: String?,
        exitCode: Int?
    ) -> StructuredAgentOutputChunk {
        let status = AgentRunSegment.Status(
            rawValue: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["status", "state"]),
            eventType: type
        )
        let normalizedToolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = command ?? normalizedToolName ?? "Tool"
        let isCommand = command != nil || normalizedToolName?.lowercased().contains("bash") == true || normalizedToolName?.lowercased().contains("shell") == true
        let detailText = detailCandidate.flatMap { mergedText($0, for: segmentID, store: &detailTextByID) }
        let aggregatedOutput = isCommand ? outputCandidate.flatMap { mergedText($0, for: segmentID, store: &aggregatedOutputByID) } : nil
        let segment = makeSegment(
            id: segmentID,
            kind: isCommand ? .commandExecution : .toolCall,
            title: title,
            subtitle: isCommand ? normalizedToolName : command,
            status: status,
            exitCode: exitCode,
            detailText: isCommand ? nil : detailText,
            aggregatedOutput: aggregatedOutput,
            groupID: normalizedToolName
        )

        let renderedTitle = isCommand ? "$ \(title)" : "Tool \(title)"
        let rendered = status == .running ? "[claude] \(renderedTitle)\n" : "[claude] \(renderedTitle) \(status.displayText.lowercased())\n"
        return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
    }

    private func renderTodoIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        guard normalizedType.contains("plan") || normalizedType.contains("todo") || normalizedType.contains("task") || object["todos"] != nil || object["tasks"] != nil else {
            return nil
        }
        let source = (object["todos"] as? [Any]) ?? (object["tasks"] as? [Any]) ?? (object["items"] as? [Any])
        let todoItems = (source ?? []).compactMap(parseTodoItem(from:))
        guard !todoItems.isEmpty else { return nil }
        let fingerprint = todoItems.map { "\($0.isCompleted ? "[x]" : "[ ]") \($0.text)" }.joined(separator: "\n")
        guard fingerprint != lastTodoFingerprint else { return StructuredAgentOutputChunk() }
        lastTodoFingerprint = fingerprint
        let segment = makeSegment(
            id: stableSegmentID(for: object, fallbackPrefix: "claude-todo"),
            kind: .todoList,
            title: "Plan",
            subtitle: "Claude task update",
            todoItems: todoItems,
            groupID: messageGroupID(for: object)
        )
        return StructuredAgentOutputChunk(renderedText: "[claude] Plan updated\n", segments: [segment])
    }

    private func renderErrorIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let errorDictionary = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["error"])
        let message = StructuredAgentOutputParserSupport.firstString(in: errorDictionary ?? [:], keys: ["message", "error"])
            ?? StructuredAgentOutputParserSupport.firstString(in: object, keys: ["error", "message"])
        guard normalizedType.contains("error") || errorDictionary != nil || message != nil else { return nil }
        let text = message ?? "Claude error"
        let segment = makeSegment(
            id: stableSegmentID(for: object, fallbackPrefix: "claude-error"),
            kind: .error,
            title: "Claude error",
            bodyText: text,
            status: .failed,
            detailText: StructuredAgentOutputParserSupport.prettyPrintedString(from: errorDictionary ?? object)
        )
        return StructuredAgentOutputChunk(renderedText: "[claude] Error: \(text)\n", segments: [segment])
    }

    private func fallbackChunk(line: String) -> StructuredAgentOutputChunk {
        StructuredAgentOutputChunk(
            renderedText: line + "\n",
            segments: [
                makeSegment(
                    id: nextTransientSegmentID(prefix: "claude-text"),
                    kind: .fallbackText,
                    title: "Log",
                    bodyText: line
                )
            ]
        )
    }

    private func extractText(from object: [String: Any]) -> String? {
        if let text = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["text", "completion", "response"]) {
            return text
        }
        if let message = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["message"]),
           let text = StructuredAgentOutputParserSupport.joinedText(from: message["content"]) {
            return text
        }
        if let delta = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["delta"]),
           let text = StructuredAgentOutputParserSupport.joinedText(from: delta) {
            return text
        }
        let content = extractContentEntries(from: object)
        let textBlocks = content.compactMap { entry -> String? in
            let type = entryType(entry)
            guard !type.contains("tool") else { return nil }
            return StructuredAgentOutputParserSupport.joinedText(from: entry)
        }
        return textBlocks.joined(separator: "\n").nonEmpty
    }

    private func extractContentEntries(from object: [String: Any]) -> [[String: Any]] {
        if let content = object["content"] as? [[String: Any]] {
            return content
        }
        if let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            return content
        }
        return []
    }

    private func extractCommand(from object: [String: Any]) -> String? {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["command", "cmd", "shell_command"])
            ?? StructuredAgentOutputParserSupport.firstString(in: StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["input", "arguments"]) ?? [:], keys: ["command", "cmd", "shell_command"])
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

    private func messageGroupID(for object: [String: Any]) -> String? {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["message_id", "session_id"])
            ?? StructuredAgentOutputParserSupport.firstString(in: StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["message"]) ?? [:], keys: ["id"])
    }

    private func stableSegmentID(for object: [String: Any], fallbackPrefix: String) -> String {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["id", "message_id", "tool_use_id"])
            ?? StructuredAgentOutputParserSupport.firstString(in: StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["message"]) ?? [:], keys: ["id"])
            ?? nextTransientSegmentID(prefix: fallbackPrefix)
    }

    private func stableToolSegmentID(for object: [String: Any], fallbackPrefix: String) -> String {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["tool_use_id", "id"])
            ?? StructuredAgentOutputParserSupport.firstString(in: StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["tool_use"]) ?? [:], keys: ["id"])
            ?? nextTransientSegmentID(prefix: fallbackPrefix)
    }

    private func nextTransientSegmentID(prefix: String) -> String {
        nextTransientSegmentIndex += 1
        return "\(prefix)-\(nextTransientSegmentIndex)"
    }

    private func mergedText(_ incoming: String, for id: String, store: inout [String: String]) -> String {
        let trimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
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
        todoItems: [AgentRunSegment.TodoItem] = [],
        groupID: String? = nil
    ) -> AgentRunSegment {
        let revision = (segmentRevisions[id] ?? 0) + 1
        segmentRevisions[id] = revision
        return AgentRunSegment(
            id: id,
            sourceAgent: .claudeCode,
            revision: revision,
            kind: kind,
            title: title,
            subtitle: subtitle,
            bodyText: bodyText,
            status: status,
            exitCode: exitCode,
            detailText: detailText,
            aggregatedOutput: aggregatedOutput,
            todoItems: todoItems,
            groupID: groupID
        )
    }

    private func entryType(_ object: [String: Any]) -> String {
        ((object["type"] as? String) ?? "").lowercased()
    }
}
