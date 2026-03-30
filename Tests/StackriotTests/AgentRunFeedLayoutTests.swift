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
        if case .turnGroup(_, let sourceAgent, let header, let title, let subtitle, let status, let summary, let segments) = rows[0] {
            #expect(sourceAgent == .githubCopilot)
            #expect(header == "Exploring codebase")
            #expect(title == "git status")
            #expect(subtitle == "Inspect repo")
            #expect(status == .running)
            #expect(summary == "2 actions · User prompt + 1 more")
            #expect(segments.map(\.id) == ["turn-1", "user-1", "tool-1"])
        } else {
            Issue.record("Expected Copilot rows with the same parent group to collapse into one turn card")
        }
    }

    @Test
    func prefersAssistantTitleAndSummarizesCompletedToolCallsInsideTurnCards() {
        let rows = AgentRunFeedLayout.rows(from: [
            AgentRunSegment(
                id: "turn-2",
                sourceAgent: .githubCopilot,
                kind: .toolCall,
                title: "Exploring discovery UI",
                subtitle: "turn-2",
                status: .completed,
                groupID: "turn-2"
            ),
            AgentRunSegment(
                id: "intent-2",
                sourceAgent: .githubCopilot,
                kind: .toolCall,
                title: "Exploring discovery UI",
                subtitle: "report_intent",
                bodyText: "Exploring discovery UI",
                status: .completed,
                groupID: "turn-2"
            ),
            AgentRunSegment(
                id: "tool-a",
                sourceAgent: .githubCopilot,
                kind: .toolCall,
                title: "glob",
                subtitle: "Inspect matching files",
                status: .completed,
                groupID: "turn-2"
            ),
            AgentRunSegment(
                id: "tool-b",
                sourceAgent: .githubCopilot,
                kind: .toolCall,
                title: "rg",
                subtitle: "Search event types",
                status: .completed,
                groupID: "turn-2"
            ),
            AgentRunSegment(
                id: "msg-2",
                sourceAgent: .githubCopilot,
                kind: .agentMessage,
                title: "Final answer",
                bodyText: "Done",
                groupID: "turn-2"
            ),
        ])

        #expect(rows.count == 1)
        if case .turnGroup(_, _, let header, let title, let subtitle, let status, let summary, let segments) = rows[0] {
            #expect(header == "Exploring discovery UI")
            #expect(title == "Final answer")
            #expect(subtitle == "Search event types")
            #expect(status == .completed)
            #expect(summary == "3 actions · Exploring discovery UI + 2 more · 2 completed")
            #expect(segments.count == 5)
        } else {
            Issue.record("Expected grouped turn row with assistant title and summarized tool calls")
        }
    }
}
