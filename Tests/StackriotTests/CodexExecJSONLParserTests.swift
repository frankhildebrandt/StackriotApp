@testable import Stackriot
import Testing

struct CodexExecJSONLParserTests {
    @Test
    func rendersStructuredCodexEventsAsReadableText() {
        let parser = CodexExecJSONLParser()

        let chunk = parser.consume("""
        {"type":"thread.started","thread_id":"thread-123"}
        {"type":"turn.started"}
        {"type":"item.started","item":{"id":"cmd-1","type":"command_execution","command":"git status","aggregated_output":"","exit_code":null,"status":"in_progress"}}
        {"type":"item.completed","item":{"id":"cmd-1","type":"command_execution","command":"git status","aggregated_output":"On branch main","exit_code":0,"status":"completed"}}
        {"type":"item.completed","item":{"id":"msg-1","type":"agent_message","text":"Done."}}
        {"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":3,"output_tokens":7}}
        """)
        let output = chunk.renderedText + parser.finish().renderedText

        #expect(output.contains("[codex] Thread started: thread-123"))
        #expect(output.contains("[codex] $ git status"))
        #expect(output.contains("[codex] Command completed: git status (exit 0)"))
        #expect(output.contains("On branch main"))
        #expect(output.contains("Done."))
        #expect(output.contains("tokens in/out: 12 (+3 cached) / 7"))

        #expect(chunk.segments.count == 2)
        #expect(chunk.segments[0].kind == .commandExecution)
        #expect(chunk.segments[0].status == .completed)
        #expect(chunk.segments[0].aggregatedOutput == "On branch main")
        #expect(chunk.segments[0].exitCode == 0)
        #expect(chunk.segments[1].kind == .agentMessage)
        #expect(chunk.segments[1].bodyText == "Done.")
    }

    @Test
    func buffersPartialJSONLinesAndAddsResumeHintOnFinish() {
        let parser = CodexExecJSONLParser()

        let first = parser.consume("{\"type\":\"thread.started\",\"thread_id\":\"thread-xyz\"}\n{\"type\":\"item.completed\",\"item\":{\"id\":\"todo-1\",\"type\":\"todo_list\",\"items\":[{\"text\":\"Parse output\",\"completed\":false}]")
        #expect(first.renderedText.contains("thread-xyz"))
        #expect(!first.renderedText.contains("Parse output"))
        #expect(first.segments.isEmpty)

        let second = parser.consume("}}\n")
        #expect(second.renderedText.contains("[codex] Todo"))
        #expect(second.renderedText.contains("[ ] Parse output"))
        #expect(second.segments.count == 1)
        #expect(second.segments[0].kind == .todoList)
        #expect(second.segments[0].todoItems == [.init(text: "Parse output", isCompleted: false)])

        let finished = parser.finish().renderedText
        #expect(finished.contains("codex exec resume thread-xyz"))
    }

    @Test
    func preservesNonJSONLines() {
        let parser = CodexExecJSONLParser()

        let chunk = parser.consume("WARNING: plain stderr line\n")

        #expect(chunk.renderedText == "WARNING: plain stderr line\n")
        #expect(chunk.segments.count == 1)
        #expect(chunk.segments[0].kind == .fallbackText)
        #expect(chunk.segments[0].bodyText == "WARNING: plain stderr line")
    }

    @Test
    func updatesRunningSegmentsWithoutAppendingDuplicates() {
        let parser = CodexExecJSONLParser()

        let started = parser.consume("""
        {"type":"item.started","item":{"id":"reason-1","type":"reasoning","text":"Planning","status":"in_progress"}}
        {"type":"item.started","item":{"id":"cmd-1","type":"command_execution","command":"swift test","aggregated_output":"","exit_code":null,"status":"in_progress"}}
        """ + "\n")
        let completed = parser.consume("""
        {"type":"item.completed","item":{"id":"reason-1","type":"reasoning","text":"Planning complete","status":"completed"}}
        {"type":"item.completed","item":{"id":"cmd-1","type":"command_execution","command":"swift test","aggregated_output":"All tests passed","exit_code":0,"status":"completed"}}
        """ + "\n")

        #expect(started.segments.count == 2)
        #expect(started.segments[0].revision == 1)
        #expect(started.segments[1].revision == 1)
        #expect(completed.segments.count == 2)
        #expect(completed.segments[0].id == "reason-1")
        #expect(completed.segments[0].revision == 2)
        #expect(completed.segments[0].bodyText == "Planning complete")
        #expect(completed.segments[1].id == "cmd-1")
        #expect(completed.segments[1].revision == 2)
        #expect(completed.segments[1].aggregatedOutput == "All tests passed")
    }

    @Test
    func capturesToolErrorsAndFileChangesAsStructuredSegments() {
        let parser = CodexExecJSONLParser()

        let chunk = parser.consume("""
        {"type":"item.completed","item":{"id":"mcp-1","type":"mcp_tool_call","server":"github","tool":"create_issue","status":"failed","error":{"message":"boom","code":500}}}
        {"type":"item.completed","item":{"id":"files-1","type":"file_change","status":"completed","changes":[{"path":"Sources/App.swift","kind":"update"},{"path":"Tests/AppTests.swift","kind":"add"}]}}
        """ + "\n")

        #expect(chunk.segments.count == 2)
        #expect(chunk.segments[0].kind == .mcpToolCall)
        #expect(chunk.segments[0].status == .failed)
        #expect(chunk.segments[0].detailText?.contains("\"code\" : 500") == true)
        #expect(chunk.segments[1].kind == .fileChange)
        #expect(chunk.segments[1].fileChanges == [
            .init(path: "Sources/App.swift", kind: .updated),
            .init(path: "Tests/AppTests.swift", kind: .added),
        ])
    }

    @Test
    func deduplicatesRepeatedTodoSnapshots() {
        let parser = CodexExecJSONLParser()

        let first = parser.consume("""
        {"type":"item.updated","item":{"id":"todo-1","type":"todo_list","items":[{"text":"One","completed":false},{"text":"Two","completed":true}]}}
        """ + "\n")
        let second = parser.consume("""
        {"type":"item.completed","item":{"id":"todo-1","type":"todo_list","items":[{"text":"One","completed":false},{"text":"Two","completed":true}]}}
        """ + "\n")

        #expect(first.segments.count == 1)
        #expect(second.segments.isEmpty)
    }
}
