import Foundation
import SwiftData

extension AppModel {
    func configureMCPServer() async {
        let registry = MCPToolRegistry(
            listRepositoriesHandler: { [weak self] in
                guard let self else { throw MCPToolRegistryError.toolFailed("AppModel unavailable.") }
                return try await self.mcpRepositoryListPayload()
            },
            listWorktreesHandler: { [weak self] repositoryID in
                guard let self else { throw MCPToolRegistryError.toolFailed("AppModel unavailable.") }
                return try await self.mcpWorktreeListPayload(repositoryID: repositoryID)
            },
            getWorktreeContextHandler: { [weak self] worktreeID in
                guard let self else { throw MCPToolRegistryError.toolFailed("AppModel unavailable.") }
                return try await self.mcpWorktreeContextPayload(worktreeID: worktreeID)
            },
            listRunsHandler: { [weak self] worktreeID, limit in
                guard let self else { throw MCPToolRegistryError.toolFailed("AppModel unavailable.") }
                return try await self.mcpRunListPayload(worktreeID: worktreeID, limit: limit)
            },
            openPlanHandler: { [weak self] worktreeID in
                guard let self else { throw MCPToolRegistryError.toolFailed("AppModel unavailable.") }
                return try await self.mcpPlanPayload(worktreeID: worktreeID)
            }
        )

        await services.mcpServerManager.configure(
            toolRegistry: registry,
            statusHandler: { [weak self] status in
                guard let self else { return }
                await MainActor.run {
                    self.mcpServerStatus = status
                }
            },
            logHandler: { [weak self] entry in
                guard let self else { return }
                await MainActor.run {
                    self.mcpLogEntries.insert(entry, at: 0)
                    if self.mcpLogEntries.count > 200 {
                        self.mcpLogEntries = Array(self.mcpLogEntries.prefix(200))
                    }
                }
            }
        )
        await services.mcpServerManager.refreshConfiguration()
    }

    func refreshMCPServerConfiguration() {
        Task {
            await services.mcpServerManager.refreshConfiguration()
            mcpServerStatus = await services.mcpServerManager.statusSnapshot()
        }
    }

    func startMCPServer() {
        Task {
            await services.mcpServerManager.start()
            mcpServerStatus = await services.mcpServerManager.statusSnapshot()
        }
    }

    func stopMCPServer() {
        Task {
            await services.mcpServerManager.stop()
            mcpServerStatus = await services.mcpServerManager.statusSnapshot()
        }
    }

    func restartMCPServer() {
        Task {
            await services.mcpServerManager.restart()
            mcpServerStatus = await services.mcpServerManager.statusSnapshot()
        }
    }

    func clearMCPLogs() {
        mcpLogEntries.removeAll()
    }

    private func mcpRepositoryListPayload() throws -> MCPRepositoryListPayload {
        guard let modelContext = storedModelContext else {
            throw MCPToolRegistryError.toolFailed("Stackriot model context is unavailable.")
        }
        let repositories = try modelContext.fetch(FetchDescriptor<ManagedRepository>())
            .sorted {
                if $0.namespace?.name != $1.namespace?.name {
                    return ($0.namespace?.name ?? "") < ($1.namespace?.name ?? "")
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        return MCPRepositoryListPayload(
            repositories: repositories.map { repository in
                MCPRepositorySummary(
                    id: repository.id.uuidString,
                    displayName: repository.displayName,
                    namespaceName: repository.namespace?.name,
                    projectName: repository.project?.name,
                    defaultBranch: repository.defaultBranch,
                    defaultRemoteName: repository.defaultRemoteName,
                    remoteURL: repository.remoteURL,
                    bareRepositoryPath: repository.bareRepositoryPath,
                    status: repository.status.rawValue,
                    lastFetchedAt: repository.lastFetchedAt,
                    updatedAt: repository.updatedAt,
                    worktreeCount: repository.worktrees.count
                )
            }
        )
    }

    private func mcpWorktreeListPayload(repositoryID: UUID) throws -> MCPWorktreeListPayload {
        guard let repository = repositoryRecord(with: repositoryID) else {
            throw MCPToolRegistryError.toolFailed("Repository \(repositoryID.uuidString) was not found.")
        }
        return MCPWorktreeListPayload(
            repositoryID: repository.id.uuidString,
            worktrees: worktrees(for: repository).map { mcpWorktreeSummary(for: $0, repository: repository) }
        )
    }

    private func mcpWorktreeContextPayload(worktreeID: UUID) throws -> MCPWorktreeContextPayload {
        guard let worktree = worktreeRecord(with: worktreeID), let repository = worktree.repository else {
            throw MCPToolRegistryError.toolFailed("Worktree \(worktreeID.uuidString) was not found.")
        }
        return MCPWorktreeContextPayload(
            worktree: mcpWorktreeSummary(for: worktree, repository: repository),
            intentText: loadIntent(for: worktree.id),
            planText: loadImplementationPlan(for: worktree.id),
            latestRuns: Array(runs(forWorktreeID: worktree.id, in: repository).prefix(10)).map(mcpRunSummary)
        )
    }

    private func mcpRunListPayload(worktreeID: UUID, limit: Int) throws -> MCPRunListPayload {
        guard let worktree = worktreeRecord(with: worktreeID), let repository = worktree.repository else {
            throw MCPToolRegistryError.toolFailed("Worktree \(worktreeID.uuidString) was not found.")
        }
        return MCPRunListPayload(
            worktreeID: worktree.id.uuidString,
            runs: Array(runs(forWorktreeID: worktree.id, in: repository).prefix(limit)).map(mcpRunSummary)
        )
    }

    private func mcpPlanPayload(worktreeID: UUID) throws -> MCPPlanPayload {
        guard let worktree = worktreeRecord(with: worktreeID) else {
            throw MCPToolRegistryError.toolFailed("Worktree \(worktreeID.uuidString) was not found.")
        }
        let planURL = AppPaths.implementationPlanFile(for: worktree.id)
        let attributes = try? FileManager.default.attributesOfItem(atPath: planURL.path)
        let modifiedAt = attributes?[.modificationDate] as? Date
        return MCPPlanPayload(
            worktreeID: worktree.id.uuidString,
            branchName: worktree.branchName,
            path: worktree.path,
            planText: loadImplementationPlan(for: worktree.id),
            intentText: loadIntent(for: worktree.id),
            lastModifiedAt: modifiedAt
        )
    }

    private func mcpWorktreeSummary(for worktree: WorktreeRecord, repository: ManagedRepository) -> MCPWorktreeSummary {
        MCPWorktreeSummary(
            id: worktree.id.uuidString,
            repositoryID: repository.id.uuidString,
            repositoryName: repository.displayName,
            branchName: worktree.branchName,
            path: worktree.path,
            issueContext: worktree.issueContext,
            isDefaultBranchWorkspace: worktree.isDefaultBranchWorkspace,
            isPinned: worktree.isPinned,
            lifecycleState: worktree.lifecycleState.rawValue,
            assignedAgent: worktree.assignedAgent.rawValue,
            ticketProvider: worktree.ticketProvider?.rawValue,
            ticketIdentifier: worktree.ticketIdentifier,
            ticketURL: worktree.ticketURL,
            prNumber: worktree.prNumber,
            prURL: worktree.prURL,
            createdAt: worktree.createdAt,
            lastOpenedAt: worktree.lastOpenedAt,
            primaryContext: worktree.resolvedPrimaryContext.map {
                MCPPrimaryContextSummary(
                    kind: $0.kind.rawValue,
                    provider: $0.provider.rawValue,
                    canonicalURL: $0.canonicalURL,
                    title: $0.title,
                    label: $0.label,
                    prNumber: $0.prNumber,
                    ticketID: $0.ticketID,
                    upstreamReference: $0.upstreamReference,
                    upstreamSHA: $0.upstreamSHA
                )
            }
        )
    }

    private func mcpRunSummary(_ run: RunRecord) -> MCPRunSummary {
        MCPRunSummary(
            id: run.id.uuidString,
            title: run.title,
            actionKind: run.actionKind.rawValue,
            status: run.status.rawValue,
            commandLine: run.commandLine,
            startedAt: run.startedAt,
            endedAt: run.endedAt,
            exitCode: run.exitCode,
            summaryTitle: run.aiSummaryTitle,
            summaryText: run.aiSummaryText
        )
    }
}
