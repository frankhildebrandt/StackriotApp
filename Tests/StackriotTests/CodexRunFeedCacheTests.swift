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
        return AppModel(userDefaults: defaults)
    }
}
