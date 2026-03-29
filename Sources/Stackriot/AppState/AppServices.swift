import Foundation

@MainActor
struct AppServices {
    let repositoryManager: RepositoryManager
    let worktreeManager: WorktreeManager
    let ideManager: IDEManager
    let sshKeyManager: SSHKeyManager
    let agentManager: AIAgentManager
    let nodeTooling: NodeToolingService
    let nodeRuntimeManager: NodeRuntimeManager
    let makeTooling: MakeToolingService
    let worktreeStatusService: WorktreeStatusService

    static let production = AppServices(
        repositoryManager: RepositoryManager(),
        worktreeManager: WorktreeManager(),
        ideManager: IDEManager(),
        sshKeyManager: SSHKeyManager(),
        agentManager: AIAgentManager(),
        nodeTooling: NodeToolingService(),
        nodeRuntimeManager: NodeRuntimeManager(),
        makeTooling: MakeToolingService(),
        worktreeStatusService: WorktreeStatusService()
    )
}
