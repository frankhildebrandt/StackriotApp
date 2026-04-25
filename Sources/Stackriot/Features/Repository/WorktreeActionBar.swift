import SwiftData
import SwiftUI

struct WorktreeRunConfigurationMenuItems: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let worktree: WorktreeRecord
    let repository: ManagedRepository
    let showsEmptyMessage: Bool

    var body: some View {
        ForEach(runConfigurationSections) { section in
            Section(section.title) {
                ForEach(section.configurations) { configuration in
                    runConfigurationMenuItem(for: configuration)
                }
            }
        }

        if showsEmptyMessage && runConfigurationSections.isEmpty {
            Text("Keine unterstützten Run Configurations gefunden")
        }
    }

    @ViewBuilder
    private func runConfigurationMenuItem(for configuration: RunConfiguration) -> some View {
        if configuration.isDirectlyRunnable {
            Button {
                let key = AsyncUIActionKey.worktree(worktree.id, "\(AsyncUIActionKey.Operation.launchRunConfiguration).\(configuration.id)")
                appModel.runUIAction(key: key, title: "Starting \(configuration.name)") {
                    await appModel.launchRunConfiguration(
                        configuration,
                        in: worktree,
                        repository: repository,
                        modelContext: modelContext
                    )
                }
            } label: {
                AsyncActionLabel(
                    title: runConfigurationTitle(for: configuration),
                    systemImage: iconName(for: configuration),
                    isRunning: appModel.isUIActionRunning(AsyncUIActionKey.worktree(worktree.id, "\(AsyncUIActionKey.Operation.launchRunConfiguration).\(configuration.id)"))
                )
            }
        } else if let preferredDevTool = configuration.preferredDevTool, availableDevTools.contains(preferredDevTool) {
            Button {
                let key = AsyncUIActionKey.worktree(worktree.id, "\(AsyncUIActionKey.Operation.launchRunConfiguration).\(configuration.id)")
                appModel.runUIAction(key: key, title: "Starting \(configuration.name)") {
                    await appModel.launchRunConfiguration(
                        configuration,
                        in: worktree,
                        repository: repository,
                        modelContext: modelContext
                    )
                }
            } label: {
                AsyncActionLabel(
                    title: "\(configuration.name) · Open in \(preferredDevTool.displayName)",
                    systemImage: preferredDevTool.systemImageName,
                    isRunning: appModel.isUIActionRunning(AsyncUIActionKey.worktree(worktree.id, "\(AsyncUIActionKey.Operation.launchRunConfiguration).\(configuration.id)"))
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

    private var availableDevTools: [SupportedDevTool] {
        appModel.cachedAvailableDevTools(for: worktree)
    }

    private var runConfigurations: [RunConfiguration] {
        appModel.cachedAvailableRunConfigurations(for: worktree)
    }

    private var runConfigurationSections: [RunConfigurationMenuSection] {
        RunConfigurationMenuGrouping.sections(for: runConfigurations)
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
                    appModel.runUIAction(
                        key: worktreeActionKey("\(AsyncUIActionKey.Operation.openDevTool).\(tool.rawValue)"),
                        title: "Opening \(tool.displayName)"
                    ) {
                        await appModel.openDevTool(tool, for: worktree, in: modelContext)
                    }
                } label: {
                    AsyncActionLabel(
                        title: "Open in \(tool.displayName)",
                        systemImage: tool.systemImageName,
                        isRunning: isWorktreeActionRunning("\(AsyncUIActionKey.Operation.openDevTool).\(tool.rawValue)")
                    )
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
                    appModel.runUIAction(
                        key: worktreeActionKey("\(AsyncUIActionKey.Operation.launchAgent).\(tool.rawValue)"),
                        title: "Starting \(tool.displayName)"
                    ) {
                        _ = await appModel.launchAgent(tool, for: worktree, in: modelContext)
                    }
                } label: {
                    AsyncActionLabel(
                        title: tool.displayName,
                        systemImage: tool.systemImageName,
                        isRunning: isWorktreeActionRunning("\(AsyncUIActionKey.Operation.launchAgent).\(tool.rawValue)")
                    )
                }
            }
        } label: {
            AsyncIconLabel(systemImage: worktree.assignedAgent.systemImageName, isRunning: isAnyWorktreeActionRunning(AsyncUIActionKey.Operation.launchAgent))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(installedAgents.isEmpty)
        .help("AI Agent starten")
    }

    private var terminalButton: some View {
        Button {
            appModel.runUIAction(key: worktreeActionKey(AsyncUIActionKey.Operation.openTerminal), title: "Opening terminal") {
                await appModel.openTerminal(for: worktree, in: modelContext)
            }
        } label: {
            AsyncIconLabel(systemImage: "terminal", isRunning: isWorktreeActionRunning(AsyncUIActionKey.Operation.openTerminal))
        }
        .buttonStyle(.bordered)
        .disabled(worktree.isDefaultBranchWorkspace || isWorktreeActionRunning(AsyncUIActionKey.Operation.openTerminal))
        .help("Neues Terminal öffnen")
    }

    private var devContainerButtonGroup: some View {
        let state = appModel.devContainerState(for: worktree)

        return HStack(spacing: 6) {
            Button {
                appModel.runUIAction(key: worktreeActionKey("\(AsyncUIActionKey.Operation.devContainer).start"), title: "Starting devcontainer") {
                    await appModel.startDevContainer(for: worktree)
                }
            } label: {
                AsyncIconLabel(systemImage: DevContainerOperation.start.systemImage, isRunning: state.isBusy)
            }
            .buttonStyle(.bordered)
            .disabled(!state.canStart)
            .help("Devcontainer starten")

            Button {
                appModel.runUIAction(key: worktreeActionKey("\(AsyncUIActionKey.Operation.devContainer).stop"), title: "Stopping devcontainer") {
                    await appModel.stopDevContainer(for: worktree)
                }
            } label: {
                AsyncIconLabel(systemImage: DevContainerOperation.stop.systemImage, isRunning: state.isBusy)
            }
            .buttonStyle(.bordered)
            .disabled(!state.canStop)
            .help("Devcontainer stoppen")

            Button {
                appModel.runUIAction(key: worktreeActionKey("\(AsyncUIActionKey.Operation.devContainer).restart"), title: "Restarting devcontainer") {
                    await appModel.restartDevContainer(for: worktree)
                }
            } label: {
                AsyncIconLabel(systemImage: DevContainerOperation.restart.systemImage, isRunning: state.isBusy)
            }
            .buttonStyle(.bordered)
            .disabled(!state.canRestart)
            .help("Devcontainer neu starten")

            Button {
                appModel.runUIAction(key: worktreeActionKey("\(AsyncUIActionKey.Operation.devContainer).rebuild"), title: "Rebuilding devcontainer") {
                    await appModel.rebuildDevContainer(for: worktree)
                }
            } label: {
                AsyncIconLabel(systemImage: DevContainerOperation.rebuild.systemImage, isRunning: state.isBusy)
            }
            .buttonStyle(.bordered)
            .disabled(!state.canRebuild)
            .help("Devcontainer ohne Build-Cache neu aufbauen")

            Button(role: .destructive) {
                appModel.runUIAction(key: worktreeActionKey("\(AsyncUIActionKey.Operation.devContainer).delete"), title: "Deleting devcontainer") {
                    await appModel.deleteDevContainer(for: worktree)
                }
            } label: {
                AsyncIconLabel(systemImage: DevContainerOperation.delete.systemImage, isRunning: state.isBusy)
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
            WorktreeRunConfigurationMenuItems(
                worktree: worktree,
                repository: repository,
                showsEmptyMessage: true
            )
        } label: {
            AsyncIconLabel(systemImage: "play.fill", isRunning: isAnyWorktreeActionRunning(AsyncUIActionKey.Operation.launchRunConfiguration))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(runConfigurations.isEmpty || worktree.isDefaultBranchWorkspace)
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
            AsyncIconLabel(systemImage: "shippingbox", isRunning: isAnyWorktreeActionRunning(AsyncUIActionKey.Operation.installDependencies))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(!hasDependencyActions)
        .help("Dependencies installieren oder aktualisieren")
    }

    private var gitMenuButton: some View {
        Menu {
            Button("Commit…") {
                pendingGitCommit = true
            }
            Button("Push") {
                appModel.runUIAction(key: worktreeActionKey(AsyncUIActionKey.Operation.gitPush), title: "Pushing branch") {
                    await appModel.runGitPush(in: worktree, repository: repository, modelContext: modelContext)
                }
            }
            Button("Pull") {
                appModel.runUIAction(key: worktreeActionKey(AsyncUIActionKey.Operation.gitPull), title: "Pulling branch") {
                    await appModel.runGitPull(in: worktree, repository: repository, modelContext: modelContext)
                }
            }
            if !worktree.isDefaultBranchWorkspace {
                Button("Integrate into Main/Default") {
                    appModel.runUIAction(key: worktreeActionKey(AsyncUIActionKey.Operation.integrate), title: "Integrating branch") {
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
            AsyncIconLabel(systemImage: "arrow.triangle.branch", isRunning: isAnyGitActionRunning)
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

    private func executeDependencyAction(_ mode: DependencyInstallMode) {
        appModel.runUIAction(
            key: worktreeActionKey("\(AsyncUIActionKey.Operation.installDependencies).\(mode.rawValue)"),
            title: mode.displayName
        ) {
            await appModel.installDependencies(
                mode: mode,
                in: worktree,
                repository: repository,
                modelContext: modelContext
            )
        }
    }

    private var isAnyGitActionRunning: Bool {
        [
            AsyncUIActionKey.Operation.gitPush,
            AsyncUIActionKey.Operation.gitPull,
            AsyncUIActionKey.Operation.integrate
        ].contains(where: isWorktreeActionRunning)
    }

    private func worktreeActionKey(_ operation: String) -> AsyncUIActionKey {
        AsyncUIActionKey.worktree(worktree.id, operation)
    }

    private func isWorktreeActionRunning(_ operation: String) -> Bool {
        appModel.isUIActionRunning(worktreeActionKey(operation))
    }

    private func isAnyWorktreeActionRunning(_ operationPrefix: String) -> Bool {
        appModel.activeUIActionKeys.contains { key in
            key.scope == .worktree
                && key.id == worktree.id.uuidString
                && key.operation.hasPrefix(operationPrefix)
        }
    }
}
