import Foundation

final class CursorAgentPrintJSONParser: StructuredAgentOutputParsing {
    private var bufferedOutput = ""

    var currentSessionID: String?
    var latestResultText: String?

    func consume(_ chunk: String) -> StructuredAgentOutputChunk {
        bufferedOutput += chunk
        return StructuredAgentOutputChunk()
    }

    func finish() -> StructuredAgentOutputChunk {
        let text = bufferedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        bufferedOutput.removeAll(keepingCapacity: false)
        guard let response = CursorAgentPrintedResponse.parse(from: text) else {
            guard let fallbackText = text.nonEmpty else { return StructuredAgentOutputChunk() }
            return StructuredAgentOutputChunk(
                renderedText: fallbackText + "\n",
                segments: [
                    AgentRunSegment(
                        id: "cursor-output",
                        sourceAgent: .cursorCLI,
                        kind: .fallbackText,
                        title: "Cursor output",
                        bodyText: fallbackText
                    )
                ]
            )
        }

        currentSessionID = response.sessionID ?? currentSessionID
        latestResultText = response.result ?? latestResultText

        var renderedParts: [String] = []
        var segments: [AgentRunSegment] = []

        if let result = response.result?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            renderedParts.append(result)
            segments.append(
                AgentRunSegment(
                    id: "cursor-result",
                    sourceAgent: .cursorCLI,
                    kind: .agentMessage,
                    title: "Antwort",
                    bodyText: result
                )
            )
        }

        if let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            renderedParts.append("[cursor] Error: \(error)")
            segments.append(
                AgentRunSegment(
                    id: "cursor-error",
                    sourceAgent: .cursorCLI,
                    kind: .error,
                    title: "Cursor error",
                    bodyText: error,
                    status: .failed
                )
            )
        }

        if let sessionID = currentSessionID?.nonEmpty {
            renderedParts.append("[cursor] Resume: cursor-agent --resume \(sessionID)")
        }

        if renderedParts.isEmpty, let fallbackText = text.nonEmpty {
            renderedParts.append(fallbackText)
            segments.append(
                AgentRunSegment(
                    id: "cursor-output",
                    sourceAgent: .cursorCLI,
                    kind: .fallbackText,
                    title: "Cursor output",
                    bodyText: fallbackText
                )
            )
        }

        return StructuredAgentOutputChunk(
            renderedText: renderedParts.joined(separator: "\n") + "\n",
            segments: segments
        )
    }
}
