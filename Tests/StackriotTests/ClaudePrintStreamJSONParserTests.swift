@testable import Stackriot
import Testing

struct ClaudePrintStreamJSONParserTests {
    @Test
    func mapsClaudeEventsOntoSharedSegments() {
        let parser = ClaudePrintStreamJSONParser()

        let chunk = parser.consume("""
        {"type":"assistant.message","message":{"id":"msg-1","role":"assistant","content":[{"type":"text","text":"I fixed it."}]}}
        {"type":"thinking.delta","id":"think-1","text":"Inspecting the repo"}
        {"type":"tool.started","tool_name":"Bash","tool_use_id":"tool-1","input":{"command":"swift test"},"status":"running"}
        {"type":"tool.completed","tool_name":"Bash","tool_use_id":"tool-1","output":"All tests passed","status":"completed","exit_code":0}
        {"type":"error","error":{"message":"boom"}}
        {"type":"mystery.event","payload":{"foo":"bar"}}
        """ + "\n")

        #expect(chunk.renderedText.contains("[claude] I fixed it."))
        #expect(chunk.renderedText.contains("[claude] Thinking: Inspecting the repo"))
        #expect(chunk.renderedText.contains("[claude] $ swift test"))
        #expect(chunk.renderedText.contains("[claude] Error: boom"))
        #expect(chunk.segments.count == 5)
        #expect(chunk.segments[0].kind == .agentMessage)
        #expect(chunk.segments[0].bodyText == "I fixed it.")
        #expect(chunk.segments[1].kind == .reasoning)
        #expect(chunk.segments[1].bodyText == "Inspecting the repo")
        #expect(chunk.segments[2].kind == .commandExecution)
        #expect(chunk.segments[2].status == .completed)
        #expect(chunk.segments[2].aggregatedOutput == "All tests passed")
        #expect(chunk.segments[2].exitCode == 0)
        #expect(chunk.segments[3].kind == .error)
        #expect(chunk.segments[4].kind == .fallbackText)
        #expect(chunk.segments[4].subtitle == "mystery.event")
    }
}
