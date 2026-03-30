@testable import Stackriot
import Testing

struct CopilotPromptJSONLParserTests {
    @Test
    func mapsRealCopilotStreamingEventsOntoSharedSegments() {
        let parser = CopilotPromptJSONLParser()

        let chunk = parser.consume("""
        {"type":"assistant.reasoning_delta","data":{"reasoningId":"reason-1","deltaContent":"Inspecting"},"id":"event-1","timestamp":"2026-03-30T02:10:41.000Z","ephemeral":true}
        {"type":"assistant.reasoning","data":{"reasoningId":"reason-1","content":"Inspecting the repo"},"id":"event-2","timestamp":"2026-03-30T02:10:42.000Z"}
        {"type":"assistant.message_delta","data":{"messageId":"msg-1","deltaContent":"hel"},"id":"event-3","timestamp":"2026-03-30T02:10:42.500Z","ephemeral":true}
        {"type":"assistant.message","data":{"messageId":"msg-1","content":"hello","toolRequests":[],"interactionId":"it-1","phase":"final_answer","reasoningOpaque":"opaque"},"id":"event-4","timestamp":"2026-03-30T02:10:43.000Z"}
        {"type":"tool.execution_start","data":{"toolCallId":"tool-1","toolName":"bash","arguments":{"command":"git status","description":"Inspect repo"}},"id":"event-5","timestamp":"2026-03-30T02:10:44.000Z"}
        {"type":"tool.execution_partial_result","data":{"toolCallId":"tool-1","partialOutput":"On branch "},"id":"event-6","timestamp":"2026-03-30T02:10:44.500Z","ephemeral":true}
        {"type":"tool.execution_complete","data":{"toolCallId":"tool-1","success":true,"result":{"content":"On branch main","detailedContent":"On branch main\\n<exited with exit code 0>"}},"id":"event-7","timestamp":"2026-03-30T02:10:45.000Z"}
        {"type":"mystery.event","data":{"foo":"bar"},"id":"event-8","timestamp":"2026-03-30T02:10:46.000Z"}
        """ + "\n")

        #expect(chunk.renderedText.contains("[copilot] Thinking: Inspecting the repo"))
        #expect(chunk.renderedText.contains("[copilot] hello"))
        #expect(chunk.renderedText.contains("[copilot] $ git status"))
        #expect(chunk.segments.count == 4)

        let reasoning = chunk.segments.first { $0.id == "reason-1" }
        #expect(reasoning?.kind == .reasoning)
        #expect(reasoning?.bodyText == "Inspecting the repo")
        #expect(reasoning?.revision == 2)

        let message = chunk.segments.first { $0.id == "msg-1" }
        #expect(message?.kind == .agentMessage)
        #expect(message?.bodyText == "hello")
        #expect(message?.revision == 2)
        #expect(message?.groupID == "it-1")

        let tool = chunk.segments.first { $0.id == "tool-1" }
        #expect(tool?.kind == .commandExecution)
        #expect(tool?.title == "git status")
        #expect(tool?.status == .completed)
        #expect(tool?.aggregatedOutput == "On branch main\n<exited with exit code 0>")
        #expect(tool?.revision == 3)

        let fallback = chunk.segments.first { $0.kind == .fallbackText }
        #expect(fallback?.subtitle == "mystery.event")
        #expect(fallback?.bodyText?.contains("\"type\":\"mystery.event\"") == true)
    }

    @Test
    func keepsReasoningTextSeparateFromFinalAssistantMessage() {
        let parser = CopilotPromptJSONLParser()

        let chunk = parser.consume("""
        {"type":"assistant.message","data":{"messageId":"msg-2","content":"done","reasoningText":"Need to inspect files first","phase":"final_answer"},"id":"event-9","timestamp":"2026-03-30T02:10:47.000Z"}
        """ + "\n")

        #expect(chunk.segments.count == 2)
        #expect(chunk.segments[0].id == "msg-2-reasoning")
        #expect(chunk.segments[0].kind == .reasoning)
        #expect(chunk.segments[0].bodyText == "Need to inspect files first")
        #expect(chunk.segments[1].id == "msg-2")
        #expect(chunk.segments[1].kind == .agentMessage)
        #expect(chunk.segments[1].bodyText == "done")
    }

    @Test
    func mapsTurnLifecycleAndUserMessagesWithoutFallbackSegments() {
        let parser = CopilotPromptJSONLParser()

        let chunk = parser.consume("""
        {"type":"assistant.turn_start","data":{"turnId":"22","interactionId":"it-22"},"id":"event-20","timestamp":"2026-03-30T06:40:17.441Z"}
        {"type":"user.message","data":{"content":"# Cursor CLI Integration","transformedContent":"normalized content","interactionId":"it-22"},"id":"event-21","timestamp":"2026-03-30T06:40:17.500Z"}
        {"type":"assistant.reasoning_delta","data":{"reasoningId":"reason-22","deltaContent":"Inspecting"},"id":"event-22","timestamp":"2026-03-30T06:40:17.600Z","ephemeral":true}
        {"type":"assistant.message","data":{"messageId":"msg-22","content":"I am checking the parser","interactionId":"it-22"},"id":"event-23","timestamp":"2026-03-30T06:40:17.700Z"}
        {"type":"assistant.turn_end","data":{"turnId":"22","interactionId":"it-22"},"id":"event-24","timestamp":"2026-03-30T06:40:17.800Z"}
        """ + "\n")

        #expect(chunk.renderedText.contains("[copilot] Turn 22 started"))
        #expect(chunk.renderedText.contains("[user] # Cursor CLI Integration"))
        #expect(chunk.renderedText.contains("[copilot] I am checking the parser"))
        #expect(chunk.renderedText.contains("[copilot] Turn 22 finished"))

        let turn = chunk.segments.first { $0.id == "turn-22" }
        #expect(turn?.kind == .toolCall)
        #expect(turn?.title == "Turn 22")
        #expect(turn?.status == .completed)
        #expect(turn?.revision == 2)
        #expect(turn?.groupID == "it-22")

        let userMessage = chunk.segments.first { $0.id == "user-event-21" }
        #expect(userMessage?.kind == .toolCall)
        #expect(userMessage?.title == "User prompt")
        #expect(userMessage?.bodyText == "# Cursor CLI Integration")
        #expect(userMessage?.status == .completed)
        #expect(userMessage?.groupID == "it-22")

        let reasoning = chunk.segments.first { $0.id == "reason-22" }
        #expect(reasoning?.kind == .reasoning)
        #expect(reasoning?.bodyText == "Inspecting")

        let message = chunk.segments.first { $0.id == "msg-22" }
        #expect(message?.kind == .agentMessage)
        #expect(message?.bodyText == "I am checking the parser")

        #expect(chunk.segments.contains { $0.kind == .fallbackText } == false)
    }

    @Test
    func parsesPlanAndFileEventsFromRealCopilotSchemas() {
        let parser = CopilotPromptJSONLParser()

        let chunk = parser.consume("""
        {"type":"exit_plan_mode.requested","data":{"requestId":"plan-1","summary":"Update parser and tests","planContent":"# Plan\\n- [x] Inspect existing parser\\n- [ ] Update Copilot mapping\\n- [ ] Add regression tests","actions":["approve"],"recommendedAction":"approve"},"id":"event-10","timestamp":"2026-03-30T02:10:48.000Z","ephemeral":true}
        {"type":"permission.requested","data":{"requestId":"perm-1","permissionRequest":{"kind":"write","toolCallId":"tool-write-1","fileName":"Sources/App.swift","intention":"Update parser","diff":"@@ -1 +1 @@\\n-old\\n+new"}},"id":"event-11","timestamp":"2026-03-30T02:10:49.000Z","ephemeral":true}
        {"type":"session.workspace_file_changed","data":{"path":"files/plan.md","operation":"create"},"id":"event-12","timestamp":"2026-03-30T02:10:50.000Z"}
        {"type":"result","timestamp":"2026-03-30T02:10:51.000Z","sessionId":"sess-1","exitCode":0,"usage":{"codeChanges":{"linesAdded":3,"linesRemoved":1,"filesModified":["Sources/App.swift","Tests/AppTests.swift"]}}}
        """ + "\n")

        #expect(chunk.segments.count == 4)

        let todo = chunk.segments.first { $0.kind == .todoList }
        #expect(todo?.todoItems == [
            .init(text: "Inspect existing parser", isCompleted: true),
            .init(text: "Update Copilot mapping", isCompleted: false),
            .init(text: "Add regression tests", isCompleted: false),
            .init(text: "Update parser and tests", isCompleted: false),
        ])

        let pendingWrite = chunk.segments.first {
            $0.kind == .fileChange && $0.fileChanges == [.init(path: "Sources/App.swift", kind: .updated)]
        }
        #expect(pendingWrite?.status == .pending)
        #expect(pendingWrite?.detailText?.contains("@@ -1 +1 @@") == true)

        let workspaceChange = chunk.segments.first {
            $0.kind == .fileChange && $0.fileChanges == [.init(path: "files/plan.md", kind: .added)]
        }
        #expect(workspaceChange?.status == .completed)

        let resultChange = chunk.segments.first {
            $0.kind == .fileChange && $0.fileChanges == [
                .init(path: "Sources/App.swift", kind: .unknown),
                .init(path: "Tests/AppTests.swift", kind: .unknown),
            ]
        }
        #expect(resultChange?.status == .completed)
        #expect(resultChange?.fileChanges == [
            .init(path: "Sources/App.swift", kind: .unknown),
            .init(path: "Tests/AppTests.swift", kind: .unknown),
        ])
    }

    @Test
    func mapsSessionErrorsWithoutTurningToolFailuresIntoAgentMessages() {
        let parser = CopilotPromptJSONLParser()

        let chunk = parser.consume("""
        {"type":"tool.execution_complete","data":{"toolCallId":"tool-2","toolName":"bash","arguments":{"command":"swift test"},"success":false,"error":{"message":"command failed","code":1}},"id":"event-13","timestamp":"2026-03-30T02:10:52.000Z"}
        {"type":"session.error","data":{"message":"boom","errorType":"session_failed"},"id":"event-14","timestamp":"2026-03-30T02:10:53.000Z"}
        """ + "\n")

        #expect(chunk.segments.count == 2)
        #expect(chunk.segments[0].kind == .commandExecution)
        #expect(chunk.segments[0].status == .failed)
        #expect(chunk.segments[0].aggregatedOutput == nil)
        #expect(chunk.segments[1].kind == .error)
        #expect(chunk.segments[1].bodyText == "boom")
    }
}
