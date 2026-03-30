@testable import Stackriot
import Testing

struct CopilotPromptJSONLParserTests {
    @Test
    func mapsCopilotJsonlOntoSharedSegments() {
        let parser = CopilotPromptJSONLParser()

        let chunk = parser.consume("""
        {"type":"assistant_message","role":"assistant","id":"msg-1","text":"Updated the files."}
        {"type":"tool.started","tool":"shell","tool_call_id":"tool-1","input":{"command":"git status"},"status":"running"}
        {"type":"tool.completed","tool":"shell","tool_call_id":"tool-1","output":"On branch main","status":"completed","exit_code":0}
        {"type":"plan.updated","todoItems":[{"text":"Inspect files","completed":true},{"text":"Run tests","completed":false}]}
        {"type":"patch.summary","fileChanges":[{"path":"Sources/App.swift","kind":"updated"},{"path":"Tests/AppTests.swift","kind":"added"}]}
        {"type":"error","message":"boom"}
        {"type":"mystery.event","payload":{"foo":"bar"}}
        """ + "\n")

        #expect(chunk.renderedText.contains("[copilot] Updated the files."))
        #expect(chunk.renderedText.contains("[copilot] $ git status"))
        #expect(chunk.renderedText.contains("[copilot] Plan updated"))
        #expect(chunk.renderedText.contains("[copilot] File changes updated"))
        #expect(chunk.renderedText.contains("[copilot] Error: boom"))
        #expect(chunk.segments.count == 6)
        #expect(chunk.segments[0].kind == .agentMessage)
        #expect(chunk.segments[1].kind == .commandExecution)
        #expect(chunk.segments[1].aggregatedOutput == "On branch main")
        #expect(chunk.segments[2].kind == .todoList)
        #expect(chunk.segments[2].todoItems == [
            .init(text: "Inspect files", isCompleted: true),
            .init(text: "Run tests", isCompleted: false),
        ])
        #expect(chunk.segments[3].kind == .fileChange)
        #expect(chunk.segments[3].fileChanges == [
            .init(path: "Sources/App.swift", kind: .updated),
            .init(path: "Tests/AppTests.swift", kind: .added),
        ])
        #expect(chunk.segments[4].kind == .error)
        #expect(chunk.segments[5].kind == .fallbackText)
        #expect(chunk.segments[5].subtitle == "mystery.event")
    }
}
