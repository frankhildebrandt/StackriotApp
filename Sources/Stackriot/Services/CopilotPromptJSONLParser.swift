import Foundation

final class CopilotPromptJSONLParser: StructuredAgentOutputParsing {
    private var bufferedLine = ""
    private var nextTransientSegmentIndex = 0
    private var segmentRevisions: [String: Int] = [:]
    private var bodyTextByID: [String: String] = [:]
    private var aggregatedOutputByID: [String: String] = [:]
    private var detailTextByID: [String: String] = [:]
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

        if let errorChunk = renderErrorIfNeeded(type: type, object: object) {
            return errorChunk
        }
        if let fileChunk = renderFileChangesIfNeeded(type: type, object: object) {
            return fileChunk
        }
        if let todoChunk = renderTodoIfNeeded(type: type, object: object) {
            return todoChunk
        }
        if let toolChunk = renderToolEventIfNeeded(type: type, object: object) {
            return toolChunk
        }
        if let messageChunk = renderMessageIfNeeded(type: type, object: object) {
            return messageChunk
        }

        return StructuredAgentOutputParserSupport.summarizeUnknownEvent(
            agent: .githubCopilot,
            line: line,
            object: object,
            fallbackID: nextTransientSegmentID(prefix: "copilot-event")
        )
    }

    private func renderMessageIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let role = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["role", "speaker"])
        let assistantLike = role?.lowercased() == "assistant"
            || normalizedType.contains("assistant")
            || normalizedType.contains("message")
            || normalizedType.contains("response")
        guard assistantLike else { return nil }
        guard let text = extractText(from: object) else { return nil }
        let segmentID = stableSegmentID(for: object, fallbackPrefix: "copilot-message")
        let bodyText = mergedText(text, for: segmentID, store: &bodyTextByID)
        let segment = makeSegment(
            id: segmentID,
            kind: .agentMessage,
            title: "Antwort",
            bodyText: bodyText,
            groupID: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["conversation_id", "session_id"])
        )
        let renderedPrefix = normalizedType.contains("delta") || normalizedType.contains("partial") ? "" : "[copilot] "
        return StructuredAgentOutputChunk(renderedText: renderedPrefix + text + (renderedPrefix.isEmpty ? "" : "\n"), segments: [segment])
    }

    private func renderToolEventIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let toolName = StructuredAgentOutputParserSupport.firstString(in: object, keys: ["tool_name", "tool", "name"])
        let toolInput = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["input", "arguments", "payload"])
        let command = extractCommand(from: object) ?? extractCommand(from: toolInput ?? [:])
        let isToolEvent = toolName != nil
            || command != nil
            || normalizedType.contains("tool")
            || normalizedType.contains("command")
            || normalizedType.contains("shell")
            || normalizedType.contains("exec")
        guard isToolEvent else { return nil }

        let segmentID = stableToolSegmentID(for: object, fallbackPrefix: "copilot-tool")
        let status = AgentRunSegment.Status(
            rawValue: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["status", "state"]),
            eventType: type
        )
        let isCommand = command != nil || toolName?.lowercased().contains("shell") == true || toolName?.lowercased().contains("bash") == true
        let title = command ?? toolName ?? "Tool"
        let detailCandidate = StructuredAgentOutputParserSupport.prettyPrintedString(from: toolInput)
        let outputCandidate = StructuredAgentOutputParserSupport.prettyPrintedString(from: object["result"])
            ?? StructuredAgentOutputParserSupport.prettyPrintedString(from: object["output"])
        let aggregatedOutput = isCommand ? outputCandidate.flatMap { mergedText($0, for: segmentID, store: &aggregatedOutputByID) } : nil
        let detailText = isCommand ? nil : detailCandidate.flatMap { mergedText($0, for: segmentID, store: &detailTextByID) }
        let segment = makeSegment(
            id: segmentID,
            kind: isCommand ? .commandExecution : .toolCall,
            title: title,
            subtitle: isCommand ? toolName : command,
            status: status,
            exitCode: object["exit_code"] as? Int,
            detailText: detailText,
            aggregatedOutput: aggregatedOutput,
            groupID: toolName
        )
        let renderedTitle = isCommand ? "$ \(title)" : "Tool \(title)"
        let rendered = status == .running ? "[copilot] \(renderedTitle)\n" : "[copilot] \(renderedTitle) \(status.displayText.lowercased())\n"
        return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
    }

    private func renderFileChangesIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let source = (object["fileChanges"] as? [Any])
            ?? (object["changes"] as? [Any])
            ?? (object["files"] as? [Any])
            ?? (StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["patch", "diff"])?["files"] as? [Any])
        let fileChanges = (source ?? []).compactMap(parseFileChange(from:))
        guard !fileChanges.isEmpty || normalizedType.contains("patch") || normalizedType.contains("file") else {
            return nil
        }
        let summary = fileChanges.map(\.path).prefix(3).joined(separator: ", ")
        let segment = makeSegment(
            id: stableSegmentID(for: object, fallbackPrefix: "copilot-files"),
            kind: .fileChange,
            title: "Changed files",
            subtitle: summary.nonEmpty,
            status: .init(rawValue: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["status", "state"]), eventType: type),
            detailText: fileChanges.isEmpty ? StructuredAgentOutputParserSupport.prettyPrintedString(from: object["patch"] ?? object["diff"]) : nil,
            fileChanges: fileChanges,
            groupID: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["operation_id", "tool_call_id"])
        )
        return StructuredAgentOutputChunk(renderedText: "[copilot] File changes updated\n", segments: [segment])
    }

    private func renderTodoIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let source = (object["todoItems"] as? [Any])
            ?? (object["todos"] as? [Any])
            ?? (object["plan"] as? [Any])
            ?? (object["tasks"] as? [Any])
        guard normalizedType.contains("todo") || normalizedType.contains("plan") || normalizedType.contains("task") || source != nil else {
            return nil
        }
        let items = (source ?? []).compactMap(parseTodoItem(from:))
        guard !items.isEmpty else { return nil }
        let fingerprint = items.map { "\($0.isCompleted ? "[x]" : "[ ]") \($0.text)" }.joined(separator: "\n")
        guard fingerprint != lastTodoFingerprint else { return StructuredAgentOutputChunk() }
        lastTodoFingerprint = fingerprint
        let segment = makeSegment(
            id: stableSegmentID(for: object, fallbackPrefix: "copilot-todo"),
            kind: .todoList,
            title: "Plan",
            subtitle: "Copilot progress",
            todoItems: items,
            groupID: StructuredAgentOutputParserSupport.firstString(in: object, keys: ["conversation_id", "session_id"])
        )
        return StructuredAgentOutputChunk(renderedText: "[copilot] Plan updated\n", segments: [segment])
    }

    private func renderErrorIfNeeded(type: String, object: [String: Any]) -> StructuredAgentOutputChunk? {
        let normalizedType = type.lowercased()
        let errorDictionary = StructuredAgentOutputParserSupport.nestedDictionary(in: object, keys: ["error"])
        let message = StructuredAgentOutputParserSupport.firstString(in: errorDictionary ?? [:], keys: ["message", "error"])
            ?? StructuredAgentOutputParserSupport.firstString(in: object, keys: ["error", "message"])
        guard normalizedType.contains("error") || errorDictionary != nil || message != nil else { return nil }
        let text = message ?? "Copilot error"
        let segment = makeSegment(
            id: stableSegmentID(for: object, fallbackPrefix: "copilot-error"),
            kind: .error,
            title: "Copilot error",
            bodyText: text,
            status: .failed,
            detailText: StructuredAgentOutputParserSupport.prettyPrintedString(from: errorDictionary ?? object)
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

    private func extractText(from object: [String: Any]) -> String? {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["text", "message", "content", "response"])
            ?? StructuredAgentOutputParserSupport.joinedText(from: object["parts"])
            ?? StructuredAgentOutputParserSupport.joinedText(from: object["delta"])
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
        let kind = AgentRunSegment.ChangedFile.Kind(rawValue: StructuredAgentOutputParserSupport.firstString(in: dictionary, keys: ["kind", "status", "change_type"]))
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

    private func stableSegmentID(for object: [String: Any], fallbackPrefix: String) -> String {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["id", "message_id", "operation_id", "tool_call_id"])
            ?? nextTransientSegmentID(prefix: fallbackPrefix)
    }

    private func stableToolSegmentID(for object: [String: Any], fallbackPrefix: String) -> String {
        StructuredAgentOutputParserSupport.firstString(in: object, keys: ["tool_call_id", "operation_id", "id"])
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
