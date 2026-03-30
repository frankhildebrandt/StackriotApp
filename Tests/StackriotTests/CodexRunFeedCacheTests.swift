@testable import Stackriot
import Testing

@MainActor
struct CodexRunFeedCacheTests {
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

        appModel.ensureCodexSegmentsLoaded(for: run)
        let segments = appModel.codexSegments(for: run)

        #expect(segments.count == 3)
        #expect(segments[0].kind == .fallbackText)
        #expect(segments[1].kind == .agentMessage)
        #expect(segments[1].bodyText == "Done.")
        #expect(segments[2].kind == .commandExecution)
        #expect(segments[2].aggregatedOutput == "On branch main")
    }

    @Test
    func ignoresNonCodexRunsDuringRehydration() {
        let appModel = makeAppModel()
        let run = RunRecord(
            actionKind: .makeTarget,
            title: "Build",
            commandLine: "swift test",
            outputText: "plain log output",
            status: .succeeded
        )

        appModel.ensureCodexSegmentsLoaded(for: run)

        #expect(appModel.codexSegments(for: run).isEmpty)
    }

    private func makeAppModel() -> AppModel {
        let suiteName = "CodexRunFeedCacheTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(userDefaults: defaults)
    }
}
