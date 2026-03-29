import SwiftData
import SwiftUI


struct AgentAssignmentRow: View {
    let worktree: WorktreeRecord
    let availableAgents: Set<AIAgentTool>
    let isRunning: Bool
    let onLaunch: (AIAgentTool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI Agents")
                .font(.headline)

            if installedAgents.isEmpty {
                Text("No supported local agent CLI was detected.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ForEach(installedAgents) { tool in
                        if tool == worktree.assignedAgent {
                            Button {
                                onLaunch(tool)
                            } label: {
                                Label(tool.displayName, systemImage: icon(for: tool))
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                onLaunch(tool)
                            } label: {
                                Label(tool.displayName, systemImage: icon(for: tool))
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if isRunning {
                        Label("Running", systemImage: "terminal.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        AgentActivityDot()
                    }

                    Spacer()
                }
            }
        }
    }

    private var installedAgents: [AIAgentTool] {
        AIAgentTool.allCases.filter { tool in
            tool != .none && availableAgents.contains(tool)
        }
    }

    private func icon(for tool: AIAgentTool) -> String {
        switch tool {
        case .none:
            "circle"
        case .claudeCode:
            "sparkles.rectangle.stack"
        case .codex:
            "terminal"
        case .githubCopilot:
            "chevron.left.forwardslash.chevron.right"
        case .cursorCLI:
            "cursorarrow.click.2"
        }
    }
}

