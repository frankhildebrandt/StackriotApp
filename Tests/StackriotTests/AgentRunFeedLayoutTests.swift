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

    @Test
    func groupsCopilotTurnSegmentsIntoSingleTurnCard() {
        let rows = AgentRunFeedLayout.rows(from: [
            AgentRunSegment(
                id: "turn-1",
                sourceAgent: .githubCopilot,
                kind: .toolCall,
                title: "Exploring codebase",
                subtitle: "it-1",
                status: .running,
                groupID: "parent-1"
            ),
            AgentRunSegment(
                id: "user-1",
                sourceAgent: .githubCopilot,
                kind: .toolCall,
                title: "User prompt",
                bodyText: "Investigate the parser",
                status: .completed,
                groupID: "parent-1"
            ),
            AgentRunSegment(
                id: "tool-1",
                sourceAgent: .githubCopilot,
                kind: .commandExecution,
                title: "git status",
                subtitle: "Inspect repo",
                status: .completed,
                groupID: "parent-1"
            ),
        ])

        #expect(rows.count == 1)
        if case .turnGroup(_, let sourceAgent, let title, let subtitle, let status, let summary, let segments) = rows[0] {
            #expect(sourceAgent == .githubCopilot)
            #expect(title == "Exploring codebase")
            #expect(subtitle == "Inspect repo")
            #expect(status == .running)
            #expect(summary == "2 actions · User prompt + 1 more")
            #expect(segments.map(\.id) == ["turn-1", "user-1", "tool-1"])
        } else {
            Issue.record("Expected Copilot rows with the same parent group to collapse into one turn card")
        }
    }
}
