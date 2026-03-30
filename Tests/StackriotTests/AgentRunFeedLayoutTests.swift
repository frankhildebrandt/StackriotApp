@testable import Stackriot
import Testing

struct AgentRunFeedLayoutTests {
    @Test
    func groupsContiguousFileChangesIntoSingleSection() {
        let rows = AgentRunFeedLayout.rows(from: [
            AgentRunSegment(
                id: "message-1",
                sourceAgent: .codex,
                kind: .agentMessage,
                title: "Antwort",
                bodyText: "Done."
            ),
            AgentRunSegment(
                id: "files-1",
                sourceAgent: .codex,
                kind: .fileChange,
                title: "Changed files",
                fileChanges: [.init(path: "Sources/App.swift", kind: .updated)]
            ),
            AgentRunSegment(
                id: "files-2",
                sourceAgent: .codex,
                kind: .fileChange,
                title: "Changed files",
                fileChanges: [.init(path: "Tests/AppTests.swift", kind: .added)]
            ),
            AgentRunSegment(
                id: "tool-1",
                sourceAgent: .codex,
                kind: .commandExecution,
                title: "swift test",
                status: .completed
            ),
        ])

        #expect(rows.count == 3)
        if case .segment(let first) = rows[0] {
            #expect(first.kind == .agentMessage)
        } else {
            Issue.record("Expected first row to remain a standalone response segment")
        }

        if case .changedFiles(_, _, _, let files, _) = rows[1] {
            #expect(files == [
                .init(path: "Sources/App.swift", kind: .updated),
                .init(path: "Tests/AppTests.swift", kind: .added),
            ])
        } else {
            Issue.record("Expected second row to group changed files")
        }

        if case .segment(let last) = rows[2] {
            #expect(last.kind == .commandExecution)
        } else {
            Issue.record("Expected final row to remain a timeline segment")
        }
    }
}
