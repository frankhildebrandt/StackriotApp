import Foundation
@testable import Stackriot
import Testing

struct OpenCodePromptJSONLParserTests {
    @Test
    func parserTracksSessionTextAndToolUsage() {
        let parser = OpenCodePromptJSONLParser()
        let expectedPlanPayload = "{\"status\":\"ready\",\"summary\":\"Done\",\"plan_markdown\":\"# Plan\"}"

        let chunk = """
        {"type":"step_start","timestamp":1767036059338,"sessionID":"ses_demo","part":{"id":"step-1","sessionID":"ses_demo","messageID":"msg-1","type":"step-start","snapshot":"abc"}}
        {"type":"tool_use","timestamp":1767036061199,"sessionID":"ses_demo","part":{"id":"tool-1","sessionID":"ses_demo","messageID":"msg-1","type":"tool","callID":"call-1","tool":"bash","state":{"status":"completed","input":{"command":"echo hello","description":"Print hello"},"output":"hello\\n","title":"Print hello","metadata":{"exit":0}}}}
        {"type":"text","timestamp":1767036064268,"sessionID":"ses_demo","part":{"id":"text-1","sessionID":"ses_demo","messageID":"msg-2","type":"text","text":"{\\"status\\":\\"ready\\",\\"summary\\":\\"Done\\",\\"plan_markdown\\":\\"# Plan\\"}"}}
        {"type":"step_finish","timestamp":1767036064273,"sessionID":"ses_demo","part":{"id":"step-2","sessionID":"ses_demo","messageID":"msg-2","type":"step-finish","reason":"stop","snapshot":"def","cost":0.001}}
        """

        let parsed = parser.consume(chunk)
        let finished = parser.finish()
        let segments = parsed.segments + finished.segments
        let hasToolSegment = segments.contains { segment in
            segment.sourceAgent == .openCode && segment.kind == .toolCall && segment.title == "Print hello"
        }
        let hasMessageSegment = segments.contains { segment in
            segment.sourceAgent == .openCode && segment.kind == .agentMessage
        }

        #expect(parser.currentSessionID == "ses_demo")
        #expect(parser.latestAssistantMessageText == expectedPlanPayload)
        #expect(hasToolSegment)
        #expect(hasMessageSegment)
        #expect(finished.renderedText.contains("opencode run --session ses_demo"))
    }

    @Test
    func parserRendersErrorsAsFailedSegments() throws {
        let parser = OpenCodePromptJSONLParser()

        _ = parser.consume("""
        {"type":"error","timestamp":1767036065000,"sessionID":"ses_demo","error":{"name":"APIError","data":{"message":"Rate limit exceeded","statusCode":429}}}
        """)
        let parsed = parser.finish()

        let segment = try #require(parsed.segments.first)
        #expect(segment.sourceAgent == .openCode)
        #expect(segment.kind == .error)
        #expect(segment.status == .failed)
        #expect(segment.bodyText == "Rate limit exceeded")
    }
}
