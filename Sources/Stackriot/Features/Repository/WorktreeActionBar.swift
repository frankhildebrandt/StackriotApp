import SwiftData
import SwiftUI

private struct RunConfigurationMenuSection: Identifiable {
    let id: String
    let title: String
    let configurations: [RunConfiguration]
}

struct WorktreeActionBar: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let worktree: WorktreeRecord
    let repository: ManagedRepository

    @State private var pendingRunConfiguration: RunConfiguration?
    @State private var pendingGitPush = false
    @State private var pendingGitCommit = false

    var body: some View {
        HStack(spacing: 6) {
            devToolMenuButton
            agentMenuButton
            terminalButton

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            runConfigButton

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            if !worktree.isDefaultBranchWorkspace {
                gitMenuButton
            }

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
        .confirmationDialog("Run Configuration ausführen?", isPresented: Binding(
            get: { pendingRunConfiguration != nil },
            set: { if !$0 { pendingRunConfiguration = nil } }
        )) {
            Button("Ausführen") {
                guard let configuration = pendingRunConfiguration else { return }
                Task {
                    await appModel.launchRunConfiguration(
                        configuration,
                        in: worktree,
                        repository: repository,
                        modelContext: modelContext
                    )
                    pendingRunConfiguration = nil
                }
            }
        } message: {
            Text(pendingRunConfiguration?.displayCommandLine ?? pendingRunConfiguration?.name ?? "")
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

    private var devToolMenuButton: some View {
        Menu {
            ForEach(availableDevTools) { tool in
                Button {
                    Task {
                        await appModel.openDevTool(tool, for: worktree, in: modelContext)
                    }
                } label: {
                    Label("Open in \(tool.displayName)", systemImage: tool.systemImageName)
                }
            }
            if availableDevTools.isEmpty {
                Text("Keine passenden DevTools gefunden")
            }
        } label: {
            Image(systemName: "laptopcomputer")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(availableDevTools.isEmpty)
        .help("DevTool öffnen")
    }

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

    private var terminalButton: some View {
        Button {
            appModel.openTerminal(for: worktree, in: modelContext)
        } label: {
            Image(systemName: "terminal")
        }
        .buttonStyle(.bordered)
        .disabled(worktree.isDefaultBranchWorkspace)
        .help("Neues Terminal öffnen")
    }

    private var runConfigButton: some View {
        Menu {
            ForEach(runConfigurationSections) { section in
                Section(section.title) {
                    ForEach(section.configurations) { configuration in
                        runConfigurationMenuItem(for: configuration)
                    }
                }
            }

            if runConfigurationSections.isEmpty {
                Text("Keine unterstützten Run Configurations gefunden")
            }
        } label: {
            Image(systemName: "play.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(runConfigurationSections.isEmpty || worktree.isDefaultBranchWorkspace)
        .help("Run Configuration ausführen")
    }

    @ViewBuilder
    private func runConfigurationMenuItem(for configuration: RunConfiguration) -> some View {
        let label = Label(runConfigurationTitle(for: configuration), systemImage: iconName(for: configuration))

        if configuration.isDirectlyRunnable {
            Button {
                pendingRunConfiguration = configuration
            } label: {
                label
            }
        } else if let preferredDevTool = configuration.preferredDevTool, availableDevTools.contains(preferredDevTool) {
            Button {
                Task {
                    await appModel.launchRunConfiguration(
                        configuration,
                        in: worktree,
                        repository: repository,
                        modelContext: modelContext
                    )
                }
            } label: {
                Label(
                    "\(configuration.name) · Open in \(preferredDevTool.displayName)",
                    systemImage: preferredDevTool.systemImageName
                )
            }
        } else if let preferredDevTool = configuration.preferredDevTool {
            Label(
                "\(configuration.name) · Requires \(preferredDevTool.displayName)",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
        } else {
            Label(configuration.name, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

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

    private var installedAgents: [AIAgentTool] {
        AIAgentTool.allCases.filter { tool in
            tool != .none && appModel.availableAgents.contains(tool)
        }
    }

    private var availableDevTools: [SupportedDevTool] {
        appModel.availableDevTools(for: worktree)
    }

    private var runConfigurations: [RunConfiguration] {
        appModel.availableRunConfigurations(for: worktree)
    }

    private var runConfigurationSections: [RunConfigurationMenuSection] {
        var sections: [RunConfigurationMenuSection] = []

        let nativeConfigurations = runConfigurations.filter { $0.source == .native }
        if !nativeConfigurations.isEmpty {
            sections.append(
                RunConfigurationMenuSection(
                    id: "native",
                    title: "Native Configs",
                    configurations: nativeConfigurations
                )
            )
        }

        let grouped = Dictionary(grouping: runConfigurations.filter { $0.source != .native }) { $0.displaySourceName }
        let sortedKeys = grouped.keys.sorted { lhs, rhs in
            let lhsRank = grouped[lhs]?.first?.preferredDevTool?.sortPriority ?? Int.max
            let rhsRank = grouped[rhs]?.first?.preferredDevTool?.sortPriority ?? Int.max
            if lhsRank == rhsRank {
                return lhs < rhs
            }
            return lhsRank < rhsRank
        }

        sections.append(contentsOf: sortedKeys.map { key in
            RunConfigurationMenuSection(
                id: key,
                title: key,
                configurations: grouped[key]?.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                } ?? []
            )
        })

        return sections
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

    private func iconName(for configuration: RunConfiguration) -> String {
        switch configuration.executionBehavior {
        case .direct:
            return configuration.isDebugCapable ? "play.circle" : "play"
        case .buildOnly:
            return "hammer"
        case .openInDevTool:
            return configuration.preferredDevTool?.systemImageName ?? "laptopcomputer"
        }
    }

    private func runConfigurationTitle(for configuration: RunConfiguration) -> String {
        switch configuration.source {
        case .native:
            return "\(configuration.name) · \(configuration.kind.displayName)"
        case .xcode:
            return "\(configuration.name) · Build"
        default:
            return "\(configuration.name) · \(configuration.runnerType)"
        }
    }
}
