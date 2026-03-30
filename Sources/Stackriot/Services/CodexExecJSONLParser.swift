import Foundation

final class CodexExecJSONLParser: StructuredAgentOutputParsing {
    private var bufferedLine = ""
    private var threadID: String?
    private var lastTodoFingerprint: String?
    private var nextTransientSegmentIndex = 0
    private var segmentRevisions: [String: Int] = [:]

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
        if let threadID {
            parsed.renderedText += "[codex] Resume: codex exec resume \(threadID)\n"
        }
        return parsed
    }

    private func render(line rawLine: String) -> StructuredAgentOutputChunk {
        let line = rawLine.replacingOccurrences(of: "\r", with: "")
        guard !line.isEmpty else { return StructuredAgentOutputChunk(renderedText: "\n") }

        guard
            let object = StructuredAgentOutputParserSupport.jsonObject(from: line),
            let type = object["type"] as? String
        else {
            return StructuredAgentOutputChunk(
                renderedText: line + "\n",
                segments: [
                    makeSegment(
                        id: nextTransientSegmentID(prefix: "text"),
                        kind: .fallbackText,
                        title: "Log",
                        bodyText: line
                    )
                ]
            )
        }

        switch type {
        case "thread.started":
            let threadID = object["thread_id"] as? String
            self.threadID = threadID ?? self.threadID
            guard let threadID else { return StructuredAgentOutputChunk(renderedText: "[codex] Thread started\n") }
            return StructuredAgentOutputChunk(renderedText: "[codex] Thread started: \(threadID)\n")
        case "turn.started":
            return StructuredAgentOutputChunk(renderedText: "[codex] Turn started\n")
        case "turn.completed":
            let usage = object["usage"] as? [String: Any]
            let inputTokens = usage?["input_tokens"] as? Int ?? 0
            let cachedInputTokens = usage?["cached_input_tokens"] as? Int ?? 0
            let outputTokens = usage?["output_tokens"] as? Int ?? 0
            return StructuredAgentOutputChunk(
                renderedText: "[codex] Turn completed. tokens in/out: \(inputTokens) (+\(cachedInputTokens) cached) / \(outputTokens)\n"
            )
        case "turn.failed":
            let error = (object["error"] as? [String: Any])?["message"] as? String ?? "Turn failed"
            return StructuredAgentOutputChunk(
                renderedText: "[codex] Turn failed: \(error)\n",
                segments: [
                    makeSegment(
                        id: nextTransientSegmentID(prefix: "turn-failed"),
                        kind: .error,
                        title: "Turn failed",
                        bodyText: error,
                        status: .failed
                    )
                ]
            )
        case "error":
            let message = object["message"] as? String ?? "Unknown error"
            return StructuredAgentOutputChunk(
                renderedText: "[codex] Error: \(message)\n",
                segments: [
                    makeSegment(
                        id: nextTransientSegmentID(prefix: "error"),
                        kind: .error,
                        title: "Codex error",
                        bodyText: message,
                        status: .failed
                    )
                ]
            )
        case "item.started", "item.updated", "item.completed":
            return renderItemEvent(type: type, object: object)
        default:
            return StructuredAgentOutputParserSupport.summarizeUnknownEvent(
                agent: .codex,
                line: line,
                object: object,
                fallbackID: nextTransientSegmentID(prefix: "text")
            )
        }
    }

    private func renderItemEvent(type: String, object: [String: Any]) -> StructuredAgentOutputChunk {
        guard
            let item = object["item"] as? [String: Any],
            let itemType = item["type"] as? String
        else {
            return StructuredAgentOutputChunk()
        }

        switch itemType {
        case "agent_message":
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return StructuredAgentOutputChunk() }
            let segment = makeSegment(
                id: stableSegmentID(for: item, fallbackPrefix: "agent-message"),
                kind: .agentMessage,
                title: "Antwort",
                bodyText: text
            )
            guard type == "item.completed" else {
                return StructuredAgentOutputChunk(segments: [segment])
            }
            return StructuredAgentOutputChunk(renderedText: text + "\n", segments: [segment])
        case "reasoning":
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return StructuredAgentOutputChunk() }
            let segment = makeSegment(
                id: stableSegmentID(for: item, fallbackPrefix: "reasoning"),
                kind: .reasoning,
                title: "Reasoning",
                bodyText: text
            )
            guard type == "item.completed" else {
                return StructuredAgentOutputChunk(segments: [segment])
            }
            return StructuredAgentOutputChunk(renderedText: "[codex] Reasoning: \(text)\n", segments: [segment])
        case "command_execution":
            return renderCommandExecutionEvent(type: type, item: item)
        case "file_change":
            guard type == "item.completed" else { return StructuredAgentOutputChunk() }
            let status = (item["status"] as? String) ?? "unknown"
            let changes = (item["changes"] as? [[String: Any]] ?? []).compactMap { change -> AgentRunSegment.ChangedFile? in
                guard let path = change["path"] as? String else { return nil }
                return AgentRunSegment.ChangedFile(path: path, kind: .init(rawValue: change["kind"] as? String))
            }
            let summary = changes.map { change -> String in
                let prefix: String
                switch change.kind {
                case .added:
                    prefix = "+"
                case .deleted:
                    prefix = "-"
                default:
                    prefix = "~"
                }
                return "\(prefix) \(change.path)"
            }
            let segment = makeSegment(
                id: stableSegmentID(for: item, fallbackPrefix: "file-change"),
                kind: .fileChange,
                title: "Dateiänderungen",
                subtitle: summary.prefix(3).joined(separator: ", "),
                status: .init(rawValue: status, eventType: type),
                fileChanges: changes
            )
            let renderedSummary = summary.isEmpty ? "" : " [" + summary.joined(separator: ", ") + "]"
            return StructuredAgentOutputChunk(
                renderedText: "[codex] File change \(status)\(renderedSummary)\n",
                segments: [segment]
            )
        case "mcp_tool_call":
            return renderMCPToolCall(type: type, item: item)
        case "collab_tool_call":
            let tool = (item["tool"] as? String) ?? "unknown"
            let status = (item["status"] as? String) ?? "unknown"
            let receivers = (item["receiver_thread_ids"] as? [String] ?? []).joined(separator: ", ")
            let receiverSuffix = receivers.isEmpty ? "" : " -> \(receivers)"
            let segment = makeSegment(
                id: stableSegmentID(for: item, fallbackPrefix: "collab-tool"),
                kind: .toolCall,
                title: tool,
                subtitle: receivers.isEmpty ? nil : "Receivers: \(receivers)",
                status: .init(rawValue: status, eventType: type),
                detailText: StructuredAgentOutputParserSupport.prettyPrintedString(from: item["output"]),
                groupID: receivers.nonEmpty
            )
            guard type != "item.updated" else {
                return StructuredAgentOutputChunk(segments: [segment])
            }
            return StructuredAgentOutputChunk(
                renderedText: "[codex] Collab \(tool) \(status)\(receiverSuffix)\n",
                segments: [segment]
            )
        case "web_search":
            let query = (item["query"] as? String) ?? ""
            if type == "item.started" {
                let rendered = query.isEmpty ? "[codex] Web search started\n" : "[codex] Web search: \(query)\n"
                let segment = makeSegment(
                    id: stableSegmentID(for: item, fallbackPrefix: "web-search"),
                    kind: .toolCall,
                    title: "Web search",
                    subtitle: query.nonEmpty,
                    status: .running
                )
                return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
            }
            return StructuredAgentOutputChunk()
        case "todo_list":
            return renderTodoList(type: type, item: item)
        case "error":
            let message = (item["message"] as? String) ?? "Unknown item error"
            return StructuredAgentOutputChunk(
                renderedText: "[codex] Item error: \(message)\n",
                segments: [
                    makeSegment(
                        id: stableSegmentID(for: item, fallbackPrefix: "item-error"),
                        kind: .error,
                        title: "Item error",
                        bodyText: message,
                        status: .failed
                    )
                ]
            )
        default:
            return StructuredAgentOutputParserSupport.summarizeUnknownEvent(
                agent: .codex,
                line: StructuredAgentOutputParserSupport.prettyPrintedString(from: object) ?? String(describing: object),
                object: object,
                fallbackID: nextTransientSegmentID(prefix: "item")
            )
        }
    }

    private func renderCommandExecutionEvent(type: String, item: [String: Any]) -> StructuredAgentOutputChunk {
        let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = (item["status"] as? String) ?? "unknown"
        let aggregatedOutput = (item["aggregated_output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let exitCode = item["exit_code"] as? Int
        let segment = makeSegment(
            id: stableSegmentID(for: item, fallbackPrefix: "command"),
            kind: .commandExecution,
            title: command.isEmpty ? "Command" : command,
            status: .init(rawValue: status, eventType: type),
            exitCode: exitCode,
            aggregatedOutput: aggregatedOutput
        )

        switch type {
        case "item.started":
            let rendered = command.isEmpty ? "[codex] Command started\n" : "[codex] $ \(command)\n"
            return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
        case "item.completed":
            var rendered = command.isEmpty ? "[codex] Command \(status)" : "[codex] Command \(status): \(command)"
            if let exitCode {
                rendered += " (exit \(exitCode))"
            }
            rendered += "\n"
            if !aggregatedOutput.isEmpty {
                rendered += aggregatedOutput + "\n"
            }
            return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
        case "item.updated":
            return StructuredAgentOutputChunk(segments: [segment])
        default:
            return StructuredAgentOutputChunk()
        }
    }

    private func renderMCPToolCall(type: String, item: [String: Any]) -> StructuredAgentOutputChunk {
        let server = (item["server"] as? String) ?? "unknown"
        let tool = (item["tool"] as? String) ?? "unknown"
        let status = (item["status"] as? String) ?? "unknown"
        let errorDetail = StructuredAgentOutputParserSupport.prettyPrintedString(from: item["error"])
        let resultDetail = StructuredAgentOutputParserSupport.prettyPrintedString(from: item["result"])
        let detail = errorDetail ?? resultDetail
        let segment = makeSegment(
            id: stableSegmentID(for: item, fallbackPrefix: "mcp-tool"),
            kind: .toolCall,
            title: "\(server)/\(tool)",
            status: .init(rawValue: status, eventType: type),
            detailText: detail,
            groupID: server
        )

        switch type {
        case "item.started":
            return StructuredAgentOutputChunk(
                renderedText: "[codex] MCP \(server)/\(tool) started\n",
                segments: [segment]
            )
        case "item.completed":
            var rendered = "[codex] MCP \(server)/\(tool) \(status)\n"
            if
                let error = item["error"] as? [String: Any],
                let message = error["message"] as? String,
                !message.isEmpty
            {
                rendered += message + "\n"
            }
            return StructuredAgentOutputChunk(renderedText: rendered, segments: [segment])
        case "item.updated":
            return StructuredAgentOutputChunk(segments: [segment])
        default:
            return StructuredAgentOutputChunk()
        }
    }

    private func renderTodoList(type: String, item: [String: Any]) -> StructuredAgentOutputChunk {
        guard type != "item.started" else { return StructuredAgentOutputChunk() }
        let todoItems = (item["items"] as? [[String: Any]] ?? []).compactMap { entry -> AgentRunSegment.TodoItem? in
            guard let text = entry["text"] as? String else { return nil }
            let completed = entry["completed"] as? Bool ?? false
            return AgentRunSegment.TodoItem(text: text, isCompleted: completed)
        }
        guard !todoItems.isEmpty else { return StructuredAgentOutputChunk() }

        let items = todoItems.map { "\($0.isCompleted ? "[x]" : "[ ]") \($0.text)" }

        let fingerprint = items.joined(separator: "\n")
        guard fingerprint != lastTodoFingerprint else { return StructuredAgentOutputChunk() }
        lastTodoFingerprint = fingerprint
        let segment = makeSegment(
            id: nextTransientSegmentID(prefix: "todo"),
            kind: .todoList,
            title: "Todos",
            subtitle: "Updated todo list",
            todoItems: todoItems
        )
        return StructuredAgentOutputChunk(
            renderedText: "[codex] Todo\n" + items.joined(separator: "\n") + "\n",
            segments: [segment]
        )
    }

    private func stableSegmentID(for item: [String: Any], fallbackPrefix: String) -> String {
        if let id = item["id"] as? String, !id.isEmpty {
            return id
        }
        return nextTransientSegmentID(prefix: fallbackPrefix)
    }

    private func nextTransientSegmentID(prefix: String) -> String {
        nextTransientSegmentIndex += 1
        return "\(prefix)-\(nextTransientSegmentIndex)"
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
            sourceAgent: .codex,
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
