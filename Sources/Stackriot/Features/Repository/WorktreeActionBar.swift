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

    @State private var pendingGitCommit = false
    @State private var showDiscardAIChangesConfirmation = false

    var body: some View {
        let discovery = appModel.cachedWorktreeDiscoverySnapshot(for: worktree)
        HStack(spacing: 6) {
            devToolMenuButton
            agentMenuButton
            terminalButton

            if discovery.hasDevContainerConfiguration {
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)

                devContainerButtonGroup
            }

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            runConfigButton

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)

            if hasDependencyActions {
                dependencyMenuButton

                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)
            }

            if !worktree.isDefaultBranchWorkspace && !worktree.isIdeaTree {
                gitMenuButton
            }

            Spacer()

            if let draft = appModel.agentPlanDraft(for: worktree.id) {
                Button {
                    appModel.presentAgentPlanDraft(for: worktree.id)
                } label: {
                    Label(
                        appModel.activeRunIDs.contains(draft.runID) ? "Plan Run" : "Open Plan Run",
                        systemImage: appModel.activeRunIDs.contains(draft.runID)
                            ? (draft.presentation == .background ? "moon.stars.fill" : "sparkles.rectangle.stack.fill")
                            : "sparkles.rectangle.stack"
                    )
                }
                .buttonStyle(.bordered)
                .help("Aktiven Planungslauf für diesen Worktree öffnen")
            }

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
        .task(id: worktree.id) {
            await appModel.refreshAvailableRunConfigurationsCache(for: worktree)
        }
        .sheet(isPresented: $pendingGitCommit) {
            GitCommitSheet(worktree: worktree, repository: repository)
        }
        .confirmationDialog(
            "AI-Implementierung verwerfen?",
            isPresented: $showDiscardAIChangesConfirmation,
            titleVisibility: .visible
        ) {
            let sourceBranch = worktree.sourceBranchName ?? "Quell-Branch"
            Button("Auf \(sourceBranch) zurücksetzen", role: .destructive) {
                Task {
                    await appModel.discardAgentImplementation(
                        worktree,
                        repository: repository,
                        modelContext: modelContext
                    )
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle nicht integrierten Änderungen im Worktree werden unwiderruflich gelöscht. Intent und Implementierungsplan bleiben erhalten.")
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
                    Task {
                        _ = await appModel.launchAgent(tool, for: worktree, in: modelContext)
                    }
                } label: {
                    Label(tool.displayName, systemImage: tool.systemImageName)
                }
            }
        } label: {
            Image(systemName: worktree.assignedAgent.systemImageName)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(installedAgents.isEmpty)
        .help("AI Agent starten")
    }

    private var terminalButton: some View {
        Button {
            Task {
                await appModel.openTerminal(for: worktree, in: modelContext)
            }
        } label: {
            Image(systemName: "terminal")
        }
        .buttonStyle(.bordered)
        .disabled(worktree.isDefaultBranchWorkspace)
        .help("Neues Terminal öffnen")
    }

    private var devContainerButtonGroup: some View {
        let state = appModel.devContainerState(for: worktree)

        return HStack(spacing: 6) {
            Button {
                Task {
                    await appModel.startDevContainer(for: worktree)
                }
            } label: {
                Image(systemName: DevContainerOperation.start.systemImage)
            }
            .buttonStyle(.bordered)
            .disabled(!state.canStart)
            .help("Devcontainer starten")

            Button {
                Task {
                    await appModel.stopDevContainer(for: worktree)
                }
            } label: {
                Image(systemName: DevContainerOperation.stop.systemImage)
            }
            .buttonStyle(.bordered)
            .disabled(!state.canStop)
            .help("Devcontainer stoppen")

            Button {
                Task {
                    await appModel.restartDevContainer(for: worktree)
                }
            } label: {
                Image(systemName: DevContainerOperation.restart.systemImage)
            }
            .buttonStyle(.bordered)
            .disabled(!state.canRestart)
            .help("Devcontainer neu starten")

            Button {
                Task {
                    await appModel.rebuildDevContainer(for: worktree)
                }
            } label: {
                Image(systemName: DevContainerOperation.rebuild.systemImage)
            }
            .buttonStyle(.bordered)
            .disabled(!state.canRebuild)
            .help("Devcontainer ohne Build-Cache neu aufbauen")

            Button(role: .destructive) {
                Task {
                    await appModel.deleteDevContainer(for: worktree)
                }
            } label: {
                Image(systemName: DevContainerOperation.delete.systemImage)
            }
            .buttonStyle(.bordered)
            .disabled(!state.canDelete)
            .help("Devcontainer entfernen")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Devcontainer controls")
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

    private var dependencyMenuButton: some View {
        Menu {
            ForEach(DependencyInstallMode.allCases) { mode in
                Button(mode.displayName) {
                    executeDependencyAction(mode)
                }
            }
        } label: {
            Image(systemName: "shippingbox")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(!hasDependencyActions)
        .help("Dependencies installieren oder aktualisieren")
    }

    @ViewBuilder
    private func runConfigurationMenuItem(for configuration: RunConfiguration) -> some View {
        let label = Label(runConfigurationTitle(for: configuration), systemImage: iconName(for: configuration))

        if configuration.isDirectlyRunnable {
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
                Task {
                    await appModel.runGitPush(in: worktree, repository: repository, modelContext: modelContext)
                }
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
            Divider()
            Button("AI-Implementierung verwerfen…", role: .destructive) {
                showDiscardAIChangesConfirmation = true
            }
        } label: {
            Image(systemName: "arrow.triangle.branch")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .help("Git Operationen")
    }

    private var installedAgents: [AIAgentTool] {
        appModel.installedAgentTools()
    }

    private var availableDevTools: [SupportedDevTool] {
        appModel.cachedAvailableDevTools(for: worktree)
    }

    private var runConfigurations: [RunConfiguration] {
        appModel.cachedAvailableRunConfigurations(for: worktree)
    }

    private var hasDependencyActions: Bool {
        appModel.hasCachedDependencyActions(for: worktree)
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

    private func executeDependencyAction(_ mode: DependencyInstallMode) {
        Task {
            await appModel.installDependencies(
                mode: mode,
                in: worktree,
                repository: repository,
                modelContext: modelContext
            )
        }
    }
}
