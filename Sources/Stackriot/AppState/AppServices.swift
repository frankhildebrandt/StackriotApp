import Foundation

@MainActor
struct AppServices {
    let repositoryManager: RepositoryManager
    let worktreeManager: WorktreeManager
    let gitHubCLIService: GitHubCLIService
    let jiraCloudService: JiraCloudService
    let aiProviderService: AIProviderService
    let ideManager: IDEManager
    let sshKeyManager: SSHKeyManager
    let agentManager: AIAgentManager
    let nodeTooling: NodeToolingService
    let nodeRuntimeManager: NodeRuntimeManager
    let makeTooling: MakeToolingService
    let worktreeStatusService: WorktreeStatusService
    let devToolDiscovery: DevToolDiscoveryService
    let runConfigurationDiscovery: RunConfigurationDiscoveryService

    init(
        repositoryManager: RepositoryManager = RepositoryManager(),
        worktreeManager: WorktreeManager = WorktreeManager(),
        gitHubCLIService: GitHubCLIService = GitHubCLIService(),
        jiraCloudService: JiraCloudService = JiraCloudService(),
        aiProviderService: AIProviderService = AIProviderService(),
        ideManager: IDEManager = IDEManager(),
        sshKeyManager: SSHKeyManager = SSHKeyManager(),
        agentManager: AIAgentManager = AIAgentManager(),
        nodeTooling: NodeToolingService = NodeToolingService(),
        nodeRuntimeManager: NodeRuntimeManager = NodeRuntimeManager(),
        makeTooling: MakeToolingService = MakeToolingService(),
        worktreeStatusService: WorktreeStatusService = WorktreeStatusService(),
        devToolDiscovery: DevToolDiscoveryService = DevToolDiscoveryService(),
        runConfigurationDiscovery: RunConfigurationDiscoveryService = RunConfigurationDiscoveryService()
    ) {
        self.repositoryManager = repositoryManager
        self.worktreeManager = worktreeManager
        self.gitHubCLIService = gitHubCLIService
        self.jiraCloudService = jiraCloudService
        self.aiProviderService = aiProviderService
        self.ideManager = ideManager
        self.sshKeyManager = sshKeyManager
        self.agentManager = agentManager
        self.nodeTooling = nodeTooling
        self.nodeRuntimeManager = nodeRuntimeManager
        self.makeTooling = makeTooling
        self.worktreeStatusService = worktreeStatusService
        self.devToolDiscovery = devToolDiscovery
        self.runConfigurationDiscovery = runConfigurationDiscovery
    }

    static let production = AppServices(
        repositoryManager: RepositoryManager(),
        worktreeManager: WorktreeManager(),
        gitHubCLIService: GitHubCLIService(),
        jiraCloudService: JiraCloudService(),
        aiProviderService: AIProviderService(),
        ideManager: IDEManager(),
        sshKeyManager: SSHKeyManager(),
        agentManager: AIAgentManager(),
        nodeTooling: NodeToolingService(),
        nodeRuntimeManager: NodeRuntimeManager(),
        makeTooling: MakeToolingService(),
        worktreeStatusService: WorktreeStatusService(),
        devToolDiscovery: DevToolDiscoveryService(),
        runConfigurationDiscovery: RunConfigurationDiscoveryService()
    )
}

extension AppServices {
    func ticketProviderService(for kind: TicketProviderKind) -> any TicketProviderService {
        switch kind {
        case .github:
            gitHubCLIService
        case .jira:
            jiraCloudService
        }
    }

    var ticketProviderServices: [any TicketProviderService] {
        TicketProviderKind.allCases.map { ticketProviderService(for: $0) }
    }
}
