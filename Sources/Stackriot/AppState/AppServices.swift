import Foundation
import OSLog
import UserNotifications

enum AppNotificationAuthorizationState: Sendable, Equatable {
    case authorized
    case denied
    case unsupported
}

enum AppNotificationKind: String, Sendable, Equatable {
    case success
    case failure
}

enum AppNotificationDeliveryResult: Sendable, Equatable {
    case delivered
    case skipped(AppNotificationAuthorizationState)
    case failed
}

struct AppNotificationRequest: Sendable, Equatable {
    let identifier: String
    let title: String
    let subtitle: String?
    let body: String
    let userInfo: [String: String]
    let kind: AppNotificationKind

    init(
        identifier: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        body: String,
        userInfo: [String: String] = [:],
        kind: AppNotificationKind = .success
    ) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.body = body
        self.userInfo = userInfo
        self.kind = kind
    }
}

protocol AppNotificationServing: Sendable {
    @discardableResult
    func prepareAuthorization() async -> AppNotificationAuthorizationState

    @discardableResult
    func deliver(_ request: AppNotificationRequest) async -> AppNotificationDeliveryResult
}

protocol UserNotificationCentering: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

struct SystemUserNotificationCenter: UserNotificationCentering, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: options) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

actor AppNotificationService: AppNotificationServing {
    private let center: any UserNotificationCentering
    private let logger = Logger(subsystem: "Stackriot", category: "notifications")
    private var cachedAuthorizationState: AppNotificationAuthorizationState?

    init(center: any UserNotificationCentering = SystemUserNotificationCenter()) {
        self.center = center
    }

    @discardableResult
    func prepareAuthorization() async -> AppNotificationAuthorizationState {
        await resolveAuthorizationState(requestIfNeeded: true)
    }

    @discardableResult
    func deliver(_ request: AppNotificationRequest) async -> AppNotificationDeliveryResult {
        let authorization = await resolveAuthorizationState(requestIfNeeded: true)
        guard authorization == .authorized else {
            if authorization == .denied {
                logger.notice("Skipping notification delivery because authorization was denied.")
            }
            return .skipped(authorization)
        }

        let content = UNMutableNotificationContent()
        content.title = request.title
        if let subtitle = request.subtitle {
            content.subtitle = subtitle
        }
        content.body = request.body
        content.sound = .default
        content.userInfo = request.userInfo
        content.threadIdentifier = request.kind.rawValue

        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: request.identifier,
                    content: content,
                    trigger: nil
                )
            )
            return .delivered
        } catch {
            logger.error("Failed to deliver notification: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private func resolveAuthorizationState(requestIfNeeded: Bool) async -> AppNotificationAuthorizationState {
        if let cachedAuthorizationState, cachedAuthorizationState != .unsupported {
            return cachedAuthorizationState
        }

        let authorizationStatus = await center.authorizationStatus()
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            cachedAuthorizationState = .authorized
            return .authorized
        case .denied:
            cachedAuthorizationState = .denied
            return .denied
        case .notDetermined:
            guard requestIfNeeded else {
                return .denied
            }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                let resolved: AppNotificationAuthorizationState = granted ? .authorized : .denied
                cachedAuthorizationState = resolved
                return resolved
            } catch {
                logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
                cachedAuthorizationState = .denied
                return .denied
            }
        @unknown default:
            logger.error("Encountered unsupported notification authorization status.")
            cachedAuthorizationState = .unsupported
            return .unsupported
        }
    }
}

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
    let copilotModelDiscovery: CopilotModelDiscoveryService
    let devContainerService: DevContainerService
    let mcpServerManager: MCPServerManager
    let rawLogArchive: AgentRawLogArchiveService
    let notificationService: any AppNotificationServing

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
        runConfigurationDiscovery: RunConfigurationDiscoveryService = RunConfigurationDiscoveryService(),
        copilotModelDiscovery: CopilotModelDiscoveryService = CopilotModelDiscoveryService(),
        devContainerService: DevContainerService = DevContainerService(),
        mcpServerManager: MCPServerManager = MCPServerManager(),
        rawLogArchive: AgentRawLogArchiveService = AgentRawLogArchiveService(),
        notificationService: any AppNotificationServing = AppNotificationService()
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
        self.copilotModelDiscovery = copilotModelDiscovery
        self.devContainerService = devContainerService
        self.mcpServerManager = mcpServerManager
        self.rawLogArchive = rawLogArchive
        self.notificationService = notificationService
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
        runConfigurationDiscovery: RunConfigurationDiscoveryService(),
        copilotModelDiscovery: CopilotModelDiscoveryService(),
        devContainerService: DevContainerService(),
        mcpServerManager: MCPServerManager(),
        rawLogArchive: AgentRawLogArchiveService(),
        notificationService: AppNotificationService()
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
