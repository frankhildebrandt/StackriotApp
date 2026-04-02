import Foundation
import SwiftData
import Testing
@testable import Stackriot

struct CopilotExecutionFlowTests {
    @Test
    func copilotModelDiscoveryParsesChoicesAndPrependsAuto() async throws {
        let service = CopilotModelDiscoveryService(
            runCommand: { _, _, _, _ in
                return CommandResult(
                    stdout: "",
                    stderr: #"Error: Invalid value for option "--model" (choices: "gpt-5.4", "claude-sonnet-4.5", "gpt-5.4")"#,
                    exitCode: 1
                )
            },
            environmentProvider: { ["PATH": "/usr/bin:/bin"] }
        )

        let models = try await service.discoverModels()

        #expect(models == [
            .auto,
            CopilotModelOption(id: "gpt-5.4", displayName: "gpt-5.4", isAuto: false),
            CopilotModelOption(id: "claude-sonnet-4.5", displayName: "claude-sonnet-4.5", isAuto: false),
        ])
    }

    @Test
    func copilotModelDiscoveryFallsBackToAutoWhenCliOmitsChoices() async throws {
        let service = CopilotModelDiscoveryService(
            runCommand: { _, _, _, _ in
                CommandResult(
                    stdout: "",
                    stderr: #"Error: Model "__stackriot_model_probe__" from --model flag is not available."#,
                    exitCode: 0
                )
            },
            environmentProvider: { [:] }
        )

        let models = try await service.discoverModels()

        #expect(models == [.auto])
    }

    @MainActor
    @Test
    func prepareCopilotExecutionWithPlanBuildsDraftAndDefaultsToAuto() async throws {
        let discovery = CopilotModelDiscoveryService(
            runCommand: { _, _, _, _ in
                CommandResult(
                    stdout: "",
                    stderr: #"Error: Invalid value for option "--model" (choices: "gpt-5.4-mini", "claude-sonnet-4.5")"#,
                    exitCode: 1
                )
            },
            environmentProvider: { [:] }
        )
        let appModel = AppModel(services: AppServices(
            copilotModelDiscovery: discovery,
            notificationService: NoopNotificationService()
        ))
        appModel.availableAgents = [.githubCopilot]

        let repository = makeRepository(name: "Copilot")
        let worktree = WorktreeRecord(branchName: "feature/copilot", path: "/tmp/copilot", repository: repository)
        repository.worktrees = [worktree]
        appModel.saveImplementationPlan("Ship the plan", for: worktree.id)
        appModel.terminalTabs.selectPrimaryPane(.implementationPlan, for: worktree.id)

        await appModel.prepareCopilotExecutionWithPlan(for: worktree, in: repository)

        let draft = try #require(appModel.pendingCopilotExecutionDraft)
        #expect(draft.tool == .githubCopilot)
        #expect(draft.promptSourceTitle == "Implementation Plan")
        #expect(draft.promptText == "Ship the plan")
        #expect(draft.activatesTerminalTab)
        #expect(draft.selectedCopilotModelID == CopilotModelOption.auto.id)
        #expect(draft.availableCopilotModels == [
            .auto,
            CopilotModelOption(id: "gpt-5.4-mini", displayName: "gpt-5.4-mini", isAuto: false),
            CopilotModelOption(id: "claude-sonnet-4.5", displayName: "claude-sonnet-4.5", isAuto: false),
        ])
        #expect(draft.modelDiscoveryErrorMessage == nil)
        #expect(!draft.isLoadingCopilotModels)
    }

    @MainActor
    @Test
    func prepareCopilotExecutionWithPlanKeepsDraftAndSurfacesDiscoveryError() async {
        let discovery = CopilotModelDiscoveryService(
            runCommand: { _, _, _, _ in
                throw StackriotError.commandFailed("copilot auth status is not successful")
            },
            environmentProvider: { [:] }
        )
        let appModel = AppModel(services: AppServices(
            copilotModelDiscovery: discovery,
            notificationService: NoopNotificationService()
        ))
        appModel.availableAgents = [.githubCopilot]

        let repository = makeRepository(name: "CopilotError")
        let worktree = WorktreeRecord(branchName: "feature/copilot-error", path: "/tmp/copilot-error", repository: repository)
        repository.worktrees = [worktree]
        appModel.saveIntent("Investigate auth handling", for: worktree.id)

        await appModel.prepareCopilotExecutionWithPlan(for: worktree, in: repository)

        let draft = appModel.pendingCopilotExecutionDraft
        #expect(draft != nil)
        #expect(draft?.activatesTerminalTab == true)
        #expect(draft?.selectedCopilotModelID == CopilotModelOption.auto.id)
        #expect(draft?.availableCopilotModels == [.auto])
        #expect(draft?.modelDiscoveryErrorMessage == "GitHub Copilot models could not be loaded: copilot auth status is not successful")
        #expect(draft?.isLoadingCopilotModels == false)
    }

    @MainActor
    @Test
    func prepareCopilotExecutionWithPlanKeepsBackgroundLaunchPreference() async throws {
        let discovery = CopilotModelDiscoveryService(
            runCommand: { _, _, _, _ in
                CommandResult(
                    stdout: "",
                    stderr: #"Error: Invalid value for option "--model" (choices: "gpt-5.4-mini")"#,
                    exitCode: 1
                )
            },
            environmentProvider: { [:] }
        )
        let appModel = AppModel(services: AppServices(
            copilotModelDiscovery: discovery,
            notificationService: NoopNotificationService()
        ))
        appModel.availableAgents = [.githubCopilot]

        let repository = makeRepository(name: "CopilotBackground")
        let worktree = WorktreeRecord(branchName: "feature/copilot-background", path: "/tmp/copilot-background", repository: repository)
        repository.worktrees = [worktree]
        appModel.saveIntent("Keep editing while Copilot runs", for: worktree.id)

        await appModel.prepareCopilotExecutionWithPlan(
            for: worktree,
            in: repository,
            options: AgentLaunchOptions(activatesTerminalTab: false)
        )

        let draft = try #require(appModel.pendingCopilotExecutionDraft)
        #expect(draft.activatesTerminalTab == false)
        #expect(draft.promptText == "Keep editing while Copilot runs")
    }

    @MainActor
    @Test
    func prepareCopilotPlanningWithIntentBuildsDraftAndDefaultsToAuto() async throws {
        let discovery = CopilotModelDiscoveryService(
            runCommand: { _, _, _, _ in
                CommandResult(
                    stdout: "",
                    stderr: #"Error: Invalid value for option "--model" (choices: "gpt-5.4-mini", "claude-sonnet-4.5")"#,
                    exitCode: 1
                )
            },
            environmentProvider: { [:] }
        )
        let appModel = AppModel(services: AppServices(
            copilotModelDiscovery: discovery,
            notificationService: NoopNotificationService()
        ))
        appModel.availableAgents = [.githubCopilot]

        let repository = makeRepository(name: "CopilotPlanning")
        let worktree = WorktreeRecord(branchName: "feature/copilot-planning", path: "/tmp/copilot-planning", repository: repository)
        repository.worktrees = [worktree]

        let modelContext = try makeInMemoryModelContext()
        appModel.storedModelContext = modelContext

        await appModel.prepareCopilotPlanningWithIntent(
            for: worktree,
            in: repository,
            currentIntentText: "Plan the feature rollout",
            modelContext: modelContext
        )

        let draft = try #require(appModel.pendingCopilotExecutionDraft)
        #expect(draft.purpose == .planning)
        #expect(draft.tool == .githubCopilot)
        #expect(draft.promptSourceTitle == "Intent")
        #expect(draft.promptText == "Plan the feature rollout")
        #expect(draft.selectedCopilotModelID == CopilotModelOption.auto.id)
        #expect(draft.availableCopilotModels == [
            .auto,
            CopilotModelOption(id: "gpt-5.4-mini", displayName: "gpt-5.4-mini", isAuto: false),
            CopilotModelOption(id: "claude-sonnet-4.5", displayName: "claude-sonnet-4.5", isAuto: false),
        ])
        #expect(draft.modelDiscoveryErrorMessage == nil)
        #expect(!draft.isLoadingCopilotModels)
    }

    private func makeRepository(name: String) -> ManagedRepository {
        ManagedRepository(
            displayName: name,
            bareRepositoryPath: "/tmp/\(name)",
            defaultBranch: "main"
        )
    }

    private func makeInMemoryModelContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RepositoryNamespace.self,
            RepositoryProject.self,
            ManagedRepository.self,
            RepositoryRemote.self,
            StoredSSHKey.self,
            WorktreeRecord.self,
            ActionTemplateRecord.self,
            RunRecord.self,
            AgentRawLogRecord.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}

private struct NoopNotificationService: AppNotificationServing {
    func prepareAuthorization() async -> AppNotificationAuthorizationState {
        .denied
    }

    func deliver(_ request: AppNotificationRequest) async -> AppNotificationDeliveryResult {
        .skipped(.denied)
    }
}
