import Foundation
import SwiftData

extension AppModel {
    func commandBarWorkspaceContext() -> CommandBarWorkspaceContext {
        let frontmost = services.frontmostWorkspaceContextService.captureFrontmostWorkspaceContext()
        if frontmost.isCursor, let matched = matchedWorkspaceContext(for: frontmost) {
            return matched
        }
        return stackriotSelectionCommandBarContext(frontmost: frontmost)
    }

    func refreshCommandBarContext() {
        guard var session = commandBarSession else { return }
        session.context = commandBarWorkspaceContext()
        commandBarSession = session
    }

    func rankedCommandBarCommands(query: String) -> [CommandBarRankedCommand] {
        CommandBarRanking.rankedCommands(commandBarCommands(), query: query)
    }

    func toggleCommandBarFavorite(_ command: CommandBarCommand) {
        var favorites = commandBarFavoriteCommandIDs()
        if favorites.contains(command.id) {
            favorites.remove(command.id)
        } else {
            favorites.insert(command.id)
        }
        persistCommandBarFavoriteCommandIDs(favorites)
    }

    func executeCommandBarCommand(_ command: CommandBarCommand, in modelContext: ModelContext) {
        guard command.isEnabled else {
            pendingErrorMessage = command.disabledReason ?? "Dieser Command ist aktuell nicht verfuegbar."
            return
        }

        recordCommandBarUsage(command.id)

        switch command.action {
        case let .rerunSelectedRun(repositoryID, worktreeID, runID):
            guard
                let repository = repositoryRecord(with: repositoryID),
                let worktree = worktreeRecord(with: worktreeID),
                let run = repository.runs.first(where: { $0.id == runID })
            else {
                pendingErrorMessage = "Der ausgewaehlte Run ist nicht mehr verfuegbar."
                return
            }
            selectedRepositoryID = repository.id
            selectWorktree(worktree, in: repository)
            selectTab(run)
            rerunRunConfiguration(run, in: modelContext)
            dismissCommandBarSession()

        case let .startRunConfiguration(repositoryID, worktreeID, configurationID):
            guard
                let repository = repositoryRecord(with: repositoryID),
                let worktree = worktreeRecord(with: worktreeID)
            else {
                pendingErrorMessage = "Der Workspace fuer diese Run Configuration ist nicht mehr verfuegbar."
                return
            }
            guard let configuration = availableRunConfigurations(for: worktree).first(where: { $0.id == configurationID }) else {
                pendingErrorMessage = "Diese Run Configuration ist nicht mehr verfuegbar."
                return
            }
            selectedRepositoryID = repository.id
            selectWorktree(worktree, in: repository)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.launchRunConfiguration(configuration, in: worktree, repository: repository, modelContext: modelContext)
                self.dismissCommandBarSession()
            }

        case .openQuickIntent:
            dismissCommandBarSession()
            presentQuickIntentFromSystemTrigger()

        case let .refreshRepository(repositoryID):
            guard let repository = repositoryRecord(with: repositoryID) else {
                pendingErrorMessage = "Das Repository ist nicht mehr verfuegbar."
                return
            }
            selectedRepositoryID = repository.id
            dismissCommandBarSession()
            refreshSelectedRepository()
        }
    }

    private func commandBarCommands() -> [CommandBarCommand] {
        let context = commandBarSession?.context ?? commandBarWorkspaceContext()
        let favorites = commandBarFavoriteCommandIDs()
        let usage = commandBarUsageByCommandID()
        var commands: [CommandBarCommand] = []

        if let repositoryID = context.repositoryID, let repository = repositoryRecord(with: repositoryID) {
            commands.append(enrichedCommand(
                CommandBarCommand(
                    id: "repository.refresh.\(repository.id.uuidString)",
                    title: "Repository aktualisieren",
                    subtitle: repository.displayName,
                    category: .repository,
                    systemImage: "arrow.clockwise",
                    keywords: ["refresh", "sync", "fetch", "repository", repository.displayName],
                    action: .refreshRepository(repositoryID: repository.id)
                ),
                favorites: favorites,
                usage: usage
            ))
        }

        if let repositoryID = context.repositoryID,
           let worktreeID = context.worktreeID,
           let repository = repositoryRecord(with: repositoryID),
           let worktree = worktreeRecord(with: worktreeID)
        {
            let selectedRun = selectedTab(for: worktree, in: repository)
            let rerunCommand = CommandBarCommand(
                id: selectedRun.map { "run.rerun.\($0.id.uuidString)" } ?? "run.rerun.unavailable.\(worktree.id.uuidString)",
                title: "Aktuelles Run Target erneut ausfuehren",
                subtitle: selectedRun.map { "\($0.title) - \(context.contextLabel)" } ?? "Kein Run-Tab fuer \(context.contextLabel) ausgewaehlt",
                category: .run,
                systemImage: "arrow.clockwise",
                keywords: ["rerun", "run", "restart", "target", "again", "build", worktree.branchName, repository.displayName],
                action: .rerunSelectedRun(repositoryID: repository.id, worktreeID: worktree.id, runID: selectedRun?.id ?? UUID()),
                isEnabled: selectedRun.map { supportsRunConsoleRuntimeTools(for: $0) } ?? false,
                disabledReason: selectedRun == nil
                    ? "Es ist kein Run-Tab fuer diesen Workspace ausgewaehlt."
                    : "Dieser Run wurde nicht aus einer Run Configuration gestartet."
            )
            commands.append(enrichedCommand(rerunCommand, favorites: favorites, usage: usage))

            let configurations = cachedAvailableRunConfigurations(for: worktree).isEmpty
                ? availableRunConfigurations(for: worktree)
                : cachedAvailableRunConfigurations(for: worktree)
            commands.append(contentsOf: configurations.map { configuration in
                enrichedCommand(
                    CommandBarCommand(
                        id: "run.start.\(worktree.id.uuidString).\(configuration.id)",
                        title: "Run Target starten: \(configuration.name)",
                        subtitle: "\(configuration.displaySourceName) - \(context.contextLabel)",
                        category: .run,
                        systemImage: "play.fill",
                        keywords: [
                            "run",
                            "start",
                            "target",
                            "execute",
                            configuration.name,
                            configuration.displaySourceName,
                            configuration.displayCommandLine ?? ""
                        ],
                        action: .startRunConfiguration(
                            repositoryID: repository.id,
                            worktreeID: worktree.id,
                            configurationID: configuration.id
                        ),
                        isEnabled: configuration.isDirectlyRunnable || configuration.preferredDevTool != nil,
                        disabledReason: "Diese Run Configuration kann von Stackriot nicht direkt ausgefuehrt werden."
                    ),
                    favorites: favorites,
                    usage: usage
                )
            })
        } else {
            commands.append(enrichedCommand(
                CommandBarCommand(
                    id: "run.rerun.no-context",
                    title: "Aktuelles Run Target erneut ausfuehren",
                    subtitle: "Kein Workspace-Kontext gefunden",
                    category: .run,
                    systemImage: "arrow.clockwise",
                    keywords: ["rerun", "run", "target", "cursor", "workspace"],
                    action: .openQuickIntent,
                    isEnabled: false,
                    disabledReason: "Cursor-Workspace oder Stackriot-Auswahl konnte keinem Worktree zugeordnet werden."
                ),
                favorites: favorites,
                usage: usage
            ))
        }

        commands.append(enrichedCommand(
            CommandBarCommand(
                id: "utility.quick-intent",
                title: "Quick Intent oeffnen",
                subtitle: "Aus markiertem Text oder Zwischenablage einen IdeaTree starten",
                category: .utility,
                systemImage: "sparkles",
                keywords: ["quick", "intent", "idea", "agent", "prompt"],
                action: .openQuickIntent
            ),
            favorites: favorites,
            usage: usage
        ))

        return commands
    }

    private func matchedWorkspaceContext(for frontmost: FrontmostWorkspaceContext) -> CommandBarWorkspaceContext? {
        for repository in allRepositories() {
            for worktree in worktrees(for: repository) {
                guard let worktreePath = worktree.materializedURL?.standardizedFileURL.path else { continue }
                if frontmost.candidatePaths.contains(where: { pathMatches(candidate: $0, worktreePath: worktreePath) })
                    || windowTitle(frontmost.windowTitle, matches: repository, worktree: worktree)
                {
                    return commandBarContext(
                        source: .frontmostCursor,
                        repository: repository,
                        worktree: worktree,
                        frontmost: frontmost,
                        matchedPath: worktreePath
                    )
                }
            }
        }
        return nil
    }

    private func stackriotSelectionCommandBarContext(frontmost: FrontmostWorkspaceContext) -> CommandBarWorkspaceContext {
        let repository = selectedRepository()
        let worktree = repository.flatMap { selectedWorktree(for: $0) }
        return commandBarContext(
            source: repository == nil ? .none : .stackriotSelection,
            repository: repository,
            worktree: worktree,
            frontmost: frontmost,
            matchedPath: nil
        )
    }

    private func commandBarContext(
        source: CommandBarContextSource,
        repository: ManagedRepository?,
        worktree: WorktreeRecord?,
        frontmost: FrontmostWorkspaceContext,
        matchedPath: String?
    ) -> CommandBarWorkspaceContext {
        CommandBarWorkspaceContext(
            source: source,
            namespaceName: repository?.namespace?.name,
            repositoryID: repository?.id,
            repositoryName: repository?.displayName,
            worktreeID: worktree?.id,
            worktreeName: worktree?.branchName,
            worktreePath: worktree?.displayPath,
            frontmostApplicationName: frontmost.applicationName,
            frontmostWindowTitle: frontmost.windowTitle,
            matchedPath: matchedPath
        )
    }

    private func allRepositories() -> [ManagedRepository] {
        guard let modelContext = storedModelContext else { return [] }
        let descriptor = FetchDescriptor<ManagedRepository>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func pathMatches(candidate: String, worktreePath: String) -> Bool {
        let candidatePath = URL(fileURLWithPath: candidate).standardizedFileURL.path
        return candidatePath == worktreePath || candidatePath.hasPrefix(worktreePath + "/")
    }

    private func windowTitle(_ title: String?, matches repository: ManagedRepository, worktree: WorktreeRecord) -> Bool {
        guard let normalizedTitle = title?.lowercased() else { return false }
        return normalizedTitle.contains(repository.displayName.lowercased())
            || normalizedTitle.contains(worktree.branchName.lowercased())
            || worktree.materializedURL.map { normalizedTitle.contains($0.lastPathComponent.lowercased()) } == true
    }

    private func enrichedCommand(
        _ command: CommandBarCommand,
        favorites: Set<String>,
        usage: [String: Date]
    ) -> CommandBarCommand {
        var command = command
        command.isFavorite = favorites.contains(command.id)
        command.lastUsedAt = usage[command.id]
        return command
    }

    private func commandBarFavoriteCommandIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: AppPreferences.commandBarFavoriteCommandIDsKey) ?? [])
    }

    private func persistCommandBarFavoriteCommandIDs(_ favorites: Set<String>) {
        UserDefaults.standard.set(Array(favorites).sorted(), forKey: AppPreferences.commandBarFavoriteCommandIDsKey)
    }

    private func commandBarUsageByCommandID() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: AppPreferences.commandBarCommandUsageKey),
              let usages = try? JSONDecoder().decode([CommandBarCommandUsage].self, from: data)
        else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: usages.map { ($0.commandID, $0.usedAt) })
    }

    private func recordCommandBarUsage(_ commandID: String) {
        var usage = commandBarUsageByCommandID()
        usage[commandID] = .now
        let recent = usage
            .map { CommandBarCommandUsage(commandID: $0.key, usedAt: $0.value) }
            .sorted { $0.usedAt > $1.usedAt }
            .prefix(50)
        if let data = try? JSONEncoder().encode(Array(recent)) {
            UserDefaults.standard.set(data, forKey: AppPreferences.commandBarCommandUsageKey)
        }
    }
}
