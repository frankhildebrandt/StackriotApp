import Foundation
import SwiftData
import Testing
@testable import Stackriot

struct CopilotExecutionFlowTests {
    @Test
    func copilotRepoAgentDiscoveryListsRepositoryAgentFiles() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let agentsDirectoryURL = rootURL
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: agentsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        FileManager.default.createFile(
            atPath: agentsDirectoryURL.appendingPathComponent("security-expert.agent.md").path,
            contents: Data("# Security Expert".utf8)
        )
        FileManager.default.createFile(
            atPath: agentsDirectoryURL.appendingPathComponent("code-review.agent.md").path,
            contents: Data("# Code Review".utf8)
        )
        FileManager.default.createFile(
            atPath: agentsDirectoryURL.appendingPathComponent("README.md").path,
            contents: Data("# Ignore".utf8)
        )

        let agents = try CopilotRepoAgent.discover(in: rootURL)

        #expect(agents == [
            CopilotRepoAgent(id: "code-review", displayName: "Code Review"),
            CopilotRepoAgent(id: "security-expert", displayName: "Security Expert"),
        ])
    }

    @MainActor
    @Test
    func prepareCopilotExecutionWithPlanBuildsDraftAndDefaultsToAuto() async throws {
        let defaults = UserDefaults.standard
        let previousModels = defaults.object(forKey: AppPreferences.copilotModelsKey)
        let previousDefaultModel = defaults.object(forKey: AppPreferences.copilotDefaultModelIDKey)
        defer {
            if let previousModels {
                defaults.set(previousModels, forKey: AppPreferences.copilotModelsKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.copilotModelsKey)
            }
            if let previousDefaultModel {
                defaults.set(previousDefaultModel, forKey: AppPreferences.copilotDefaultModelIDKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.copilotDefaultModelIDKey)
            }
        }

        AppPreferences.setCopilotModelOptions([
            CopilotModelOption(id: "gpt-5.4", displayName: "gpt-5.4", isAuto: false),
            CopilotModelOption(id: "claude-sonnet-4.6", displayName: "Claude Sonnet 4.6", isAuto: false),
        ])
        AppPreferences.setDefaultCopilotModelID(CopilotModelOption.auto.id)

        let appModel = AppModel(services: AppServices(notificationService: NoopNotificationService()))
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
            CopilotModelOption(id: "gpt-5.4", displayName: "gpt-5.4", isAuto: false),
            CopilotModelOption(id: "claude-sonnet-4.6", displayName: "Claude Sonnet 4.6", isAuto: false),
        ])
        #expect(draft.availableCopilotRepoAgents.isEmpty)
        #expect(draft.selectedCopilotRepoAgentID == nil)
    }

    @MainActor
    @Test
    func prepareCopilotExecutionWithPlanUsesConfiguredDefaultModel() async {
        let defaults = UserDefaults.standard
        let previousModels = defaults.object(forKey: AppPreferences.copilotModelsKey)
        let previousDefaultModel = defaults.object(forKey: AppPreferences.copilotDefaultModelIDKey)
        defer {
            if let previousModels {
                defaults.set(previousModels, forKey: AppPreferences.copilotModelsKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.copilotModelsKey)
            }
            if let previousDefaultModel {
                defaults.set(previousDefaultModel, forKey: AppPreferences.copilotDefaultModelIDKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.copilotDefaultModelIDKey)
            }
        }

        AppPreferences.setCopilotModelOptions([
            CopilotModelOption(id: "gpt-5.4", displayName: "gpt-5.4", isAuto: false),
            CopilotModelOption(id: "claude-opus-4.6", displayName: "Claude Opus 4.6", isAuto: false),
        ])
        AppPreferences.setDefaultCopilotModelID("claude-opus-4.6")

        let appModel = AppModel(services: AppServices(notificationService: NoopNotificationService()))
        appModel.availableAgents = [.githubCopilot]

        let repository = makeRepository(name: "CopilotConfiguredDefault")
        let worktree = WorktreeRecord(branchName: "feature/copilot-default", path: "/tmp/copilot-default", repository: repository)
        repository.worktrees = [worktree]
        appModel.saveIntent("Investigate auth handling", for: worktree.id)

        await appModel.prepareCopilotExecutionWithPlan(for: worktree, in: repository)

        let draft = appModel.pendingCopilotExecutionDraft
        #expect(draft != nil)
        #expect(draft?.activatesTerminalTab == true)
        #expect(draft?.selectedCopilotModelID == "claude-opus-4.6")
        #expect(draft?.availableCopilotModels == [
            .auto,
            CopilotModelOption(id: "gpt-5.4", displayName: "gpt-5.4", isAuto: false),
            CopilotModelOption(id: "claude-opus-4.6", displayName: "Claude Opus 4.6", isAuto: false),
        ])
        #expect(draft?.availableCopilotRepoAgents == [])
        #expect(draft?.selectedCopilotRepoAgentID == nil)
    }

    @MainActor
    @Test
    func prepareCopilotExecutionWithPlanKeepsBackgroundLaunchPreference() async throws {
        let appModel = AppModel(services: AppServices(notificationService: NoopNotificationService()))
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
        let defaults = UserDefaults.standard
        let previousModels = defaults.object(forKey: AppPreferences.copilotModelsKey)
        let previousDefaultModel = defaults.object(forKey: AppPreferences.copilotDefaultModelIDKey)
        defer {
            if let previousModels {
                defaults.set(previousModels, forKey: AppPreferences.copilotModelsKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.copilotModelsKey)
            }
            if let previousDefaultModel {
                defaults.set(previousDefaultModel, forKey: AppPreferences.copilotDefaultModelIDKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.copilotDefaultModelIDKey)
            }
        }

        AppPreferences.setCopilotModelOptions([
            CopilotModelOption(id: "gpt-5.4", displayName: "gpt-5.4", isAuto: false),
            CopilotModelOption(id: "gemini-3.1-pro", displayName: "Google Gemini Pro 3.1", isAuto: false),
        ])
        AppPreferences.setDefaultCopilotModelID(CopilotModelOption.auto.id)

        let appModel = AppModel(services: AppServices(notificationService: NoopNotificationService()))
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
            CopilotModelOption(id: "gpt-5.4", displayName: "gpt-5.4", isAuto: false),
            CopilotModelOption(id: "gemini-3.1-pro", displayName: "Google Gemini Pro 3.1", isAuto: false),
        ])
        #expect(draft.availableCopilotRepoAgents.isEmpty)
        #expect(draft.selectedCopilotRepoAgentID == nil)
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
