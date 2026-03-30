import Foundation

struct StructuredAgentOutputChunk {
    var renderedText: String = ""
    var segments: [AgentRunSegment] = []
}

protocol StructuredAgentOutputParsing: AnyObject {
    func consume(_ chunk: String) -> StructuredAgentOutputChunk
    func finish() -> StructuredAgentOutputChunk
}

enum StructuredAgentOutputParserFactory {
    static func makeParser(for kind: RunOutputInterpreterKind) -> any StructuredAgentOutputParsing {
        switch kind {
        case .codexExecJSONL:
            CodexExecJSONLParser()
        case .claudePrintStreamJSON:
            ClaudePrintStreamJSONParser()
        case .copilotPromptJSONL:
            CopilotPromptJSONLParser()
        case .cursorAgentPrintJSON:
            CursorAgentPrintJSONParser()
        }
    }
}

enum StructuredAgentOutputParserSupport {
    static func jsonObject(from line: String) -> [String: Any]? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    static func prettyPrintedString(from value: Any?) -> String? {
        guard let value else { return nil }

        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }

        guard JSONSerialization.isValidJSONObject(value) else {
            return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    static func string(from value: Any?) -> String? {
        switch value {
        case let string as String:
            string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        case let number as NSNumber:
            number.stringValue.nonEmpty
        default:
            nil
        }
    }

    static func joinedText(from value: Any?) -> String? {
        switch value {
        case nil:
            return nil
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        case let array as [Any]:
            let parts = array.compactMap(joinedText(from:))
            return parts.joined(separator: "\n").nonEmpty
        case let dictionary as [String: Any]:
            if let text = string(from: dictionary["text"]) ?? string(from: dictionary["message"]) ?? string(from: dictionary["content"]) {
                return text
            }
            let preferredKeys = ["delta", "result", "output", "content", "message", "summary", "body"]
            let parts = preferredKeys.compactMap { joinedText(from: dictionary[$0]) }
            return parts.joined(separator: "\n").nonEmpty
        default:
            return nil
        }
    }

    static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = string(from: object[key]) {
                return value
            }
        }
        return nil
    }

    static func nestedDictionary(in object: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = object[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    static func summarizeUnknownEvent(agent: AIAgentTool, line: String, object: [String: Any], fallbackID: String) -> StructuredAgentOutputChunk {
        let eventType = firstString(in: object, keys: ["type", "event", "kind"]) ?? "event"
        return StructuredAgentOutputChunk(
            renderedText: line + "\n",
            segments: [
                AgentRunSegment(
                    id: fallbackID,
                    sourceAgent: agent,
                    kind: .fallbackText,
                    title: "Unhandled \(agent.displayName) event",
                    subtitle: eventType,
                    bodyText: line,
                    detailText: prettyPrintedString(from: object)
                )
            ]
        )
    }
}

extension StructuredAgentOutputChunk {
    mutating func append(_ other: StructuredAgentOutputChunk) {
        renderedText += other.renderedText
        for segment in other.segments {
            if let index = segments.firstIndex(where: { $0.id == segment.id }) {
                segments[index] = segment
            } else {
                segments.append(segment)
            }
        }
    }
}
