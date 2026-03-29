import Foundation

struct CodexExecParsedChunk {
    var renderedText: String = ""
}

final class CodexExecJSONLParser {
    private var bufferedLine = ""
    private var threadID: String?
    private var lastTodoFingerprint: String?

    func consume(_ chunk: String) -> CodexExecParsedChunk {
        bufferedLine += chunk

        var rendered = ""
        while let newlineIndex = bufferedLine.firstIndex(of: "\n") {
            let line = String(bufferedLine[..<newlineIndex])
            bufferedLine.removeSubrange(...newlineIndex)
            rendered += render(line: line)
        }

        return CodexExecParsedChunk(renderedText: rendered)
    }

    func finish() -> CodexExecParsedChunk {
        var rendered = ""
        if !bufferedLine.isEmpty {
            rendered += render(line: bufferedLine)
            bufferedLine.removeAll(keepingCapacity: false)
        }
        if let threadID {
            rendered += "[codex] Resume: codex exec resume \(threadID)\n"
        }
        return CodexExecParsedChunk(renderedText: rendered)
    }

    private func render(line rawLine: String) -> String {
        let line = rawLine.replacingOccurrences(of: "\r", with: "")
        guard !line.isEmpty else { return "\n" }

        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return line + "\n"
        }

        switch type {
        case "thread.started":
            let threadID = object["thread_id"] as? String
            self.threadID = threadID ?? self.threadID
            guard let threadID else { return "[codex] Thread started\n" }
            return "[codex] Thread started: \(threadID)\n"
        case "turn.started":
            return "[codex] Turn started\n"
        case "turn.completed":
            let usage = object["usage"] as? [String: Any]
            let inputTokens = usage?["input_tokens"] as? Int ?? 0
            let cachedInputTokens = usage?["cached_input_tokens"] as? Int ?? 0
            let outputTokens = usage?["output_tokens"] as? Int ?? 0
            return "[codex] Turn completed. tokens in/out: \(inputTokens) (+\(cachedInputTokens) cached) / \(outputTokens)\n"
        case "turn.failed":
            let error = (object["error"] as? [String: Any])?["message"] as? String ?? "Turn failed"
            return "[codex] Turn failed: \(error)\n"
        case "error":
            let message = object["message"] as? String ?? "Unknown error"
            return "[codex] Error: \(message)\n"
        case "item.started", "item.updated", "item.completed":
            return renderItemEvent(type: type, object: object)
        default:
            return line + "\n"
        }
    }

    private func renderItemEvent(type: String, object: [String: Any]) -> String {
        guard
            let item = object["item"] as? [String: Any],
            let itemType = item["type"] as? String
        else {
            return ""
        }

        switch itemType {
        case "agent_message":
            guard type == "item.completed" else { return "" }
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return "" }
            return text + "\n"
        case "reasoning":
            guard type == "item.completed" else { return "" }
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return "" }
            return "[codex] Reasoning: \(text)\n"
        case "command_execution":
            return renderCommandExecutionEvent(type: type, item: item)
        case "file_change":
            guard type == "item.completed" else { return "" }
            let status = (item["status"] as? String) ?? "unknown"
            let changes = (item["changes"] as? [[String: Any]] ?? []).compactMap { change -> String? in
                guard let path = change["path"] as? String else { return nil }
                let kind = (change["kind"] as? String) ?? "update"
                let prefix: String
                switch kind {
                case "add":
                    prefix = "+"
                case "delete":
                    prefix = "-"
                default:
                    prefix = "~"
                }
                return "\(prefix) \(path)"
            }
            let summary = changes.isEmpty ? "" : " [" + changes.joined(separator: ", ") + "]"
            return "[codex] File change \(status)\(summary)\n"
        case "mcp_tool_call":
            return renderMCPToolCall(type: type, item: item)
        case "collab_tool_call":
            guard type != "item.updated" else { return "" }
            let tool = (item["tool"] as? String) ?? "unknown"
            let status = (item["status"] as? String) ?? "unknown"
            let receivers = (item["receiver_thread_ids"] as? [String] ?? []).joined(separator: ", ")
            let receiverSuffix = receivers.isEmpty ? "" : " -> \(receivers)"
            return "[codex] Collab \(tool) \(status)\(receiverSuffix)\n"
        case "web_search":
            let query = (item["query"] as? String) ?? ""
            if type == "item.started" {
                return query.isEmpty ? "[codex] Web search started\n" : "[codex] Web search: \(query)\n"
            }
            return ""
        case "todo_list":
            return renderTodoList(type: type, item: item)
        case "error":
            let message = (item["message"] as? String) ?? "Unknown item error"
            return "[codex] Item error: \(message)\n"
        default:
            return ""
        }
    }

    private func renderCommandExecutionEvent(type: String, item: [String: Any]) -> String {
        let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = (item["status"] as? String) ?? "unknown"
        let aggregatedOutput = (item["aggregated_output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let exitCode = item["exit_code"] as? Int

        switch type {
        case "item.started":
            return command.isEmpty ? "[codex] Command started\n" : "[codex] $ \(command)\n"
        case "item.completed":
            var rendered = command.isEmpty ? "[codex] Command \(status)" : "[codex] Command \(status): \(command)"
            if let exitCode {
                rendered += " (exit \(exitCode))"
            }
            rendered += "\n"
            if !aggregatedOutput.isEmpty {
                rendered += aggregatedOutput + "\n"
            }
            return rendered
        default:
            return ""
        }
    }

    private func renderMCPToolCall(type: String, item: [String: Any]) -> String {
        let server = (item["server"] as? String) ?? "unknown"
        let tool = (item["tool"] as? String) ?? "unknown"
        let status = (item["status"] as? String) ?? "unknown"

        switch type {
        case "item.started":
            return "[codex] MCP \(server)/\(tool) started\n"
        case "item.completed":
            var rendered = "[codex] MCP \(server)/\(tool) \(status)\n"
            if
                let error = item["error"] as? [String: Any],
                let message = error["message"] as? String,
                !message.isEmpty
            {
                rendered += message + "\n"
            }
            return rendered
        default:
            return ""
        }
    }

    private func renderTodoList(type: String, item: [String: Any]) -> String {
        guard type != "item.started" else { return "" }
        let items = (item["items"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
            guard let text = entry["text"] as? String else { return nil }
            let completed = entry["completed"] as? Bool ?? false
            return "\(completed ? "[x]" : "[ ]") \(text)"
        }
        guard !items.isEmpty else { return "" }

        let fingerprint = items.joined(separator: "\n")
        guard fingerprint != lastTodoFingerprint else { return "" }
        lastTodoFingerprint = fingerprint
        return "[codex] Todo\n" + items.joined(separator: "\n") + "\n"
    }
}
