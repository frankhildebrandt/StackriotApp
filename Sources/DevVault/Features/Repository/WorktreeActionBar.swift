import SwiftData
import SwiftUI

struct WorktreeActionBar: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let worktree: WorktreeRecord
    let repository: ManagedRepository

    @State private var pendingMakeTarget: String?
    @State private var pendingScript: String?
    @State private var pendingGitPush = false
    @State private var pendingGitCommit = false

    var body: some View {
        HStack(spacing: 6) {
            ideMenuButton
            agentMenuButton
            terminalButton

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            runConfigButton

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            gitMenuButton

            Spacer()

            if appModel.isAgentRunning(for: worktree) {
                HStack(spacing: 6) {
                    Text("Agent")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    AgentActivityDot()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .confirmationDialog("Make Target ausführen?", isPresented: Binding(
            get: { pendingMakeTarget != nil },
            set: { if !$0 { pendingMakeTarget = nil } }
        )) {
            Button("Ausführen") {
                if let target = pendingMakeTarget {
                    appModel.runMakeTarget(target, in: worktree, repository: repository, modelContext: modelContext)
                    pendingMakeTarget = nil
                }
            }
        } message: {
            Text(pendingMakeTarget.map { "make \($0) in \(worktree.branchName) ausführen?" } ?? "")
        }
        .confirmationDialog("NPM Script ausführen?", isPresented: Binding(
            get: { pendingScript != nil },
            set: { if !$0 { pendingScript = nil } }
        )) {
            Button("Ausführen") {
                if let script = pendingScript {
                    appModel.runNPMScript(script, in: worktree, repository: repository, modelContext: modelContext)
                    pendingScript = nil
                }
            }
        } message: {
            Text(pendingScript.map { "npm run \($0) ausführen?" } ?? "")
        }
        .confirmationDialog("Git Push", isPresented: $pendingGitPush) {
            Button("Push") {
                Task {
                    await appModel.runGitPush(in: worktree, repository: repository, modelContext: modelContext)
                }
            }
        } message: {
            Text("Branch \(worktree.branchName) pushen?")
        }
        .sheet(isPresented: $pendingGitCommit) {
            GitCommitSheet(worktree: worktree, repository: repository)
        }
    }

    // MARK: – IDE Menu

    private var ideMenuButton: some View {
        Menu {
            ForEach(SupportedIDE.allCases) { ide in
                Button("Open in \(ide.displayName)") {
                    Task {
                        await appModel.openIDE(ide, for: worktree, in: modelContext)
                    }
                }
            }
        } label: {
            Image(systemName: "laptopcomputer")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .help("IDE öffnen")
    }

    // MARK: – Agent Menu

    private var agentMenuButton: some View {
        Menu {
            ForEach(installedAgents) { tool in
                Button {
                    appModel.launchAgent(tool, for: worktree, in: modelContext)
                } label: {
                    Label(tool.displayName, systemImage: agentIcon(for: tool))
                }
            }
        } label: {
            Image(systemName: agentIcon(for: worktree.assignedAgent))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(installedAgents.isEmpty)
        .help("AI Agent starten")
    }

    // MARK: – Terminal Button

    private var terminalButton: some View {
        Button {
            appModel.openTerminal(for: worktree, in: modelContext)
        } label: {
            Image(systemName: "terminal")
        }
        .buttonStyle(.bordered)
        .help("Neues Terminal öffnen")
    }

    // MARK: – Run Config Menu

    private var runConfigButton: some View {
        let makeTargets = appModel.availableMakeTargets(for: worktree)
        let npmScripts = appModel.availableNPMScripts(for: worktree)
        let hasConfigs = !makeTargets.isEmpty || !npmScripts.isEmpty

        return Menu {
            if !makeTargets.isEmpty {
                Section("Make Targets") {
                    ForEach(makeTargets, id: \.self) { target in
                        Button(target) {
                            pendingMakeTarget = target
                        }
                    }
                }
            }
            if !npmScripts.isEmpty {
                Section("NPM Scripts") {
                    ForEach(npmScripts, id: \.self) { script in
                        Button(script) {
                            pendingScript = script
                        }
                    }
                }
            }
            if !hasConfigs {
                Text("Kein Makefile / package.json gefunden")
            }
        } label: {
            Image(systemName: "play.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(!hasConfigs)
        .help("Run Configuration ausführen")
    }

    // MARK: – Git Menu

    private var gitMenuButton: some View {
        Menu {
            Button("Commit…") {
                pendingGitCommit = true
            }
            Button("Push") {
                pendingGitPush = true
            }
            if !worktree.isDefaultBranchWorkspace {
                Button("Integrate into Main/Default") {
                    Task {
                        await appModel.integrateIntoDefaultBranch(
                            worktree,
                            repository: repository,
                            modelContext: modelContext
                        )
                    }
                }
            }
            Divider()
            Button("Publish Branch…") {
                appModel.presentPublishSheet(for: repository, worktree: worktree)
            }
        } label: {
            Image(systemName: "arrow.triangle.branch")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .help("Git Operationen")
    }

    // MARK: – Helpers

    private var installedAgents: [AIAgentTool] {
        AIAgentTool.allCases.filter { tool in
            tool != .none && appModel.availableAgents.contains(tool)
        }
    }

    private func agentIcon(for tool: AIAgentTool) -> String {
        switch tool {
        case .none:
            "sparkles"
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
