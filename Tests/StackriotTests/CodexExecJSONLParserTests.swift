@testable import Stackriot
import Testing

struct CodexExecJSONLParserTests {
    @Test
    func rendersStructuredCodexEventsAsReadableText() {
        let parser = CodexExecJSONLParser()

        let streamedOutput = parser.consume("""
        {"type":"thread.started","thread_id":"thread-123"}
        {"type":"turn.started"}
        {"type":"item.started","item":{"id":"cmd-1","type":"command_execution","command":"git status","aggregated_output":"","exit_code":null,"status":"in_progress"}}
        {"type":"item.completed","item":{"id":"cmd-1","type":"command_execution","command":"git status","aggregated_output":"On branch main","exit_code":0,"status":"completed"}}
        {"type":"item.completed","item":{"id":"msg-1","type":"agent_message","text":"Done."}}
        {"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":3,"output_tokens":7}}
        """).renderedText
        let output = streamedOutput + parser.finish().renderedText

        #expect(output.contains("[codex] Thread started: thread-123"))
        #expect(output.contains("[codex] $ git status"))
        #expect(output.contains("[codex] Command completed: git status (exit 0)"))
        #expect(output.contains("On branch main"))
        #expect(output.contains("Done."))
        #expect(output.contains("tokens in/out: 12 (+3 cached) / 7"))
    }

    @Test
    func buffersPartialJSONLinesAndAddsResumeHintOnFinish() {
        let parser = CodexExecJSONLParser()

        let first = parser.consume("{\"type\":\"thread.started\",\"thread_id\":\"thread-xyz\"}\n{\"type\":\"item.completed\",\"item\":{\"id\":\"todo-1\",\"type\":\"todo_list\",\"items\":[{\"text\":\"Parse output\",\"completed\":false}]")
        #expect(first.renderedText.contains("thread-xyz"))
        #expect(!first.renderedText.contains("Parse output"))

        let second = parser.consume("}}\n")
        #expect(second.renderedText.contains("[codex] Todo"))
        #expect(second.renderedText.contains("[ ] Parse output"))

        let finished = parser.finish().renderedText
        #expect(finished.contains("codex exec resume thread-xyz"))
    }

    @Test
    func preservesNonJSONLines() {
        let parser = CodexExecJSONLParser()

        let output = parser.consume("WARNING: plain stderr line\n").renderedText

        #expect(output == "WARNING: plain stderr line\n")
    }
}
