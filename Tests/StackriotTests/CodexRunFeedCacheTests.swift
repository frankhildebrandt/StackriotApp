import Foundation
@testable import Stackriot
import Foundation
import Testing

@MainActor
struct StructuredAgentOutputCacheTests {
    @Test
    func rehydratesStructuredSegmentsFromPersistedCodexOutput() {
        let appModel = makeAppModel()
        let run = RunRecord(
            actionKind: .aiAgent,
            title: "Codex",
            commandLine: "codex exec",
            outputText: """
            $ codex exec
            {"type":"item.completed","item":{"id":"msg-1","type":"agent_message","text":"Done."}}
            {"type":"item.completed","item":{"id":"cmd-1","type":"command_execution","command":"git status","aggregated_output":"On branch main","exit_code":0,"status":"completed"}}
            """,
            outputInterpreter: .codexExecJSONL,
            status: .succeeded
        )

        appModel.ensureStructuredSegmentsLoaded(for: run)
        let segments = appModel.structuredSegments(for: run)

        #expect(segments.count == 3)
        #expect(segments[0].kind == .fallbackText)
        #expect(segments[1].kind == .agentMessage)
        #expect(segments[1].bodyText == "Done.")
        #expect(segments[2].kind == .commandExecution)
        #expect(segments[2].aggregatedOutput == "On branch main")
    }

    @Test
    func rehydratesStructuredSegmentsWithInterpreterSpecificParser() {
        let appModel = makeAppModel()
        let run = RunRecord(
            actionKind: .aiAgent,
            title: "Claude Code",
            commandLine: "claude -p",
            outputText: """
            $ claude -p
            {"type":"assistant.message","message":{"id":"msg-1","role":"assistant","content":[{"type":"text","text":"Done."}]}}
            {"type":"tool.completed","tool_name":"Bash","tool_use_id":"tool-1","input":{"command":"swift test"},"output":"All tests passed","status":"completed","exit_code":0}
            """,
            outputInterpreter: .claudePrintStreamJSON,
            status: .succeeded
        )

        appModel.ensureStructuredSegmentsLoaded(for: run)
        let segments = appModel.structuredSegments(for: run)

        #expect(segments.count == 3)
        #expect(segments[1].sourceAgent == .claudeCode)
        #expect(segments[1].kind == .agentMessage)
        #expect(segments[1].bodyText == "Done.")
        #expect(segments[2].kind == .commandExecution)
        #expect(segments[2].aggregatedOutput == "All tests passed")
    }

    @Test
    func rehydratesStructuredSegmentsFromRealCopilotSessionEvents() {
        let appModel = makeAppModel()
        let run = RunRecord(
            actionKind: .aiAgent,
            title: "GitHub Copilot",
            commandLine: "copilot -p",
            outputText: """
            $ copilot -p
            {"type":"assistant.reasoning","data":{"reasoningId":"reason-1","content":"Inspecting the repo"}}
            {"type":"assistant.message","data":{"messageId":"msg-1","content":"Done.","interactionId":"it-1","phase":"final_answer"}}
            {"type":"tool.execution_complete","data":{"toolCallId":"tool-1","toolName":"bash","arguments":{"command":"git status"},"success":true,"result":{"detailedContent":"On branch main","content":"On branch main"}}}
            """,
            outputInterpreter: .copilotPromptJSONL,
            status: .succeeded
        )

        appModel.ensureStructuredSegmentsLoaded(for: run)
        let segments = appModel.structuredSegments(for: run)

        #expect(segments.count == 4)
        #expect(segments[1].sourceAgent == .githubCopilot)
        #expect(segments[1].kind == .reasoning)
        #expect(segments[1].bodyText == "Inspecting the repo")
        #expect(segments[2].kind == .agentMessage)
        #expect(segments[2].bodyText == "Done.")
        #expect(segments[3].kind == .commandExecution)
        #expect(segments[3].aggregatedOutput == "On branch main")
    }

    @Test
    func ignoresRunsWithoutStructuredInterpreterDuringRehydration() {
        let appModel = makeAppModel()
        let run = RunRecord(
            actionKind: .makeTarget,
            title: "Build",
            commandLine: "swift test",
            outputText: "plain log output",
            status: .succeeded
        )

        appModel.ensureStructuredSegmentsLoaded(for: run)

        #expect(appModel.structuredSegments(for: run).isEmpty)
    }

    private func makeAppModel() -> AppModel {
        let suiteName = "CodexRunFeedCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            services: AppServices(notificationService: CacheNoopNotificationService()),
            userDefaults: defaults
        )
    }
}

private actor CacheNoopNotificationService: AppNotificationServing {
    @discardableResult
    func prepareAuthorization() async -> AppNotificationAuthorizationState {
        .unsupported
    }

    @discardableResult
    func deliver(_: AppNotificationRequest) async -> AppNotificationDeliveryResult {
        .skipped(.unsupported)
    }
}
