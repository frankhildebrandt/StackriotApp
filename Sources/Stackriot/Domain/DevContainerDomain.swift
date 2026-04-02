import Foundation

enum DevContainerRuntimeStatus: String, Codable, Sendable {
    case unknown
    case stopped
    case running

    var displayName: String {
        switch self {
        case .unknown:
            "Unknown"
        case .stopped:
            "Stopped"
        case .running:
            "Running"
        }
    }
}

enum DevContainerOperation: String, CaseIterable, Identifiable, Sendable {
    case start
    case stop
    case restart
    case rebuild
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start:
            "Start"
        case .stop:
            "Stop"
        case .restart:
            "Restart"
        case .rebuild:
            "Rebuild"
        case .delete:
            "Delete"
        }
    }

    var progressTitle: String {
        switch self {
        case .start:
            "Starting"
        case .stop:
            "Stopping"
        case .restart:
            "Restarting"
        case .rebuild:
            "Rebuilding"
        case .delete:
            "Deleting"
        }
    }

    var systemImage: String {
        switch self {
        case .start:
            "play.fill"
        case .stop:
            "stop.fill"
        case .restart:
            "arrow.clockwise"
        case .rebuild:
            "hammer.fill"
        case .delete:
            "trash.fill"
        }
    }
}

enum DevContainerResolvedCLIKind: String, Codable, Sendable {
    case devcontainerCLI
    case npx

    var displayName: String {
        switch self {
        case .devcontainerCLI:
            "devcontainer CLI"
        case .npx:
            "npx @devcontainers/cli"
        }
    }
}

enum DevContainerDiagnosticIssue: String, Codable, Sendable {
    case featureDisabled
    case dockerMissing
    case dockerUnreachable
    case cliUnavailable
    case noConfiguration
    case containerUnreachable

    var displayTitle: String {
        switch self {
        case .featureDisabled:
            "Disabled in Settings"
        case .dockerMissing:
            "Docker CLI Missing"
        case .dockerUnreachable:
            "Docker Not Reachable"
        case .cliUnavailable:
            "Devcontainer CLI Missing"
        case .noConfiguration:
            "No Devcontainer Configuration"
        case .containerUnreachable:
            "Container Not Reachable"
        }
    }
}

struct DevContainerToolingStatus: Equatable, Sendable {
    var isFeatureEnabled: Bool
    var cliStrategy: DevContainerCLIStrategy
    var dockerInstalled: Bool
    var devcontainerInstalled: Bool
    var npxInstalled: Bool
    var resolvedCLI: DevContainerResolvedCLIKind?

    init(
        isFeatureEnabled: Bool = AppPreferences.devContainerEnabled,
        cliStrategy: DevContainerCLIStrategy = AppPreferences.devContainerCLIStrategy,
        dockerInstalled: Bool = false,
        devcontainerInstalled: Bool = false,
        npxInstalled: Bool = false,
        resolvedCLI: DevContainerResolvedCLIKind? = nil
    ) {
        self.isFeatureEnabled = isFeatureEnabled
        self.cliStrategy = cliStrategy
        self.dockerInstalled = dockerInstalled
        self.devcontainerInstalled = devcontainerInstalled
        self.npxInstalled = npxInstalled
        self.resolvedCLI = resolvedCLI
    }

    var isCLIAvailable: Bool {
        resolvedCLI != nil
    }

    var missingRequiredTools: [String] {
        var tools: [String] = []
        if !dockerInstalled {
            tools.append("docker")
        }
        if !isCLIAvailable {
            tools.append("devcontainer")
        }
        return tools
    }

    var summaryLine: String {
        let docker = dockerInstalled ? "docker" : "docker missing"
        let cli = resolvedCLI?.displayName ?? "no devcontainer CLI"
        return "\(docker) · \(cli)"
    }
}

struct DevContainerConfiguration: Equatable, Sendable {
    let workspaceFolderURL: URL
    let configFileURL: URL

    var displayPath: String {
        let workspacePath = workspaceFolderURL.standardizedFileURL.path
        let configPath = configFileURL.standardizedFileURL.path
        guard configPath.hasPrefix(workspacePath) else { return configPath }

        let relative = String(configPath.dropFirst(workspacePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? configFileURL.lastPathComponent : relative
    }
}

struct DevContainerResourceUsage: Equatable, Sendable {
    var cpuPercent: String?
    var memoryUsage: String?
    var memoryPercent: String?
}

struct DevContainerWorkspaceSnapshot: Equatable, Sendable {
    var configuration: DevContainerConfiguration?
    var runtimeStatus: DevContainerRuntimeStatus
    var containerID: String?
    var containerName: String?
    var imageName: String?
    var resourceUsage: DevContainerResourceUsage?
    var containerCount: Int
    var detailsErrorMessage: String?
    var lastUpdatedAt: Date?
    var toolingStatus: DevContainerToolingStatus
    var diagnosticIssue: DevContainerDiagnosticIssue?

    init(
        configuration: DevContainerConfiguration?,
        runtimeStatus: DevContainerRuntimeStatus = .unknown,
        containerID: String? = nil,
        containerName: String? = nil,
        imageName: String? = nil,
        resourceUsage: DevContainerResourceUsage? = nil,
        containerCount: Int = 0,
        detailsErrorMessage: String? = nil,
        lastUpdatedAt: Date? = nil,
        toolingStatus: DevContainerToolingStatus = DevContainerToolingStatus(),
        diagnosticIssue: DevContainerDiagnosticIssue? = nil
    ) {
        self.configuration = configuration
        self.runtimeStatus = runtimeStatus
        self.containerID = containerID
        self.containerName = containerName
        self.imageName = imageName
        self.resourceUsage = resourceUsage
        self.containerCount = containerCount
        self.detailsErrorMessage = detailsErrorMessage
        self.lastUpdatedAt = lastUpdatedAt
        self.toolingStatus = toolingStatus
        self.diagnosticIssue = diagnosticIssue
    }

    var hasConfiguration: Bool {
        configuration != nil
    }

    var hasContainer: Bool {
        containerID != nil || containerCount > 0
    }

    var canOpenTerminal: Bool {
        runtimeStatus == .running && containerID?.nonEmpty != nil
    }
}

struct DevContainerWorkspaceState: Equatable, Sendable {
    var configuration: DevContainerConfiguration?
    var runtimeStatus: DevContainerRuntimeStatus
    var containerID: String?
    var containerName: String?
    var imageName: String?
    var resourceUsage: DevContainerResourceUsage?
    var containerCount: Int
    var detailsErrorMessage: String?
    var lastUpdatedAt: Date?
    var activeOperation: DevContainerOperation?
    var logs: String
    var isLogStreaming: Bool
    var toolingStatus: DevContainerToolingStatus
    var diagnosticIssue: DevContainerDiagnosticIssue?

    init(
        configuration: DevContainerConfiguration? = nil,
        runtimeStatus: DevContainerRuntimeStatus = .unknown,
        containerID: String? = nil,
        containerName: String? = nil,
        imageName: String? = nil,
        resourceUsage: DevContainerResourceUsage? = nil,
        containerCount: Int = 0,
        detailsErrorMessage: String? = nil,
        lastUpdatedAt: Date? = nil,
        activeOperation: DevContainerOperation? = nil,
        logs: String = "",
        isLogStreaming: Bool = false,
        toolingStatus: DevContainerToolingStatus = DevContainerToolingStatus(),
        diagnosticIssue: DevContainerDiagnosticIssue? = nil
    ) {
        self.configuration = configuration
        self.runtimeStatus = runtimeStatus
        self.containerID = containerID
        self.containerName = containerName
        self.imageName = imageName
        self.resourceUsage = resourceUsage
        self.containerCount = containerCount
        self.detailsErrorMessage = detailsErrorMessage
        self.lastUpdatedAt = lastUpdatedAt
        self.activeOperation = activeOperation
        self.logs = logs
        self.isLogStreaming = isLogStreaming
        self.toolingStatus = toolingStatus
        self.diagnosticIssue = diagnosticIssue
    }

    init(snapshot: DevContainerWorkspaceSnapshot) {
        self.init(
            configuration: snapshot.configuration,
            runtimeStatus: snapshot.runtimeStatus,
            containerID: snapshot.containerID,
            containerName: snapshot.containerName,
            imageName: snapshot.imageName,
            resourceUsage: snapshot.resourceUsage,
            containerCount: snapshot.containerCount,
            detailsErrorMessage: snapshot.detailsErrorMessage,
            lastUpdatedAt: snapshot.lastUpdatedAt,
            toolingStatus: snapshot.toolingStatus,
            diagnosticIssue: snapshot.diagnosticIssue
        )
    }

    var isBusy: Bool {
        activeOperation != nil
    }

    var hasConfiguration: Bool {
        configuration != nil
    }

    var hasContainer: Bool {
        containerID != nil || containerCount > 0
    }

    var isRunning: Bool {
        runtimeStatus == .running
    }

    var canStart: Bool {
        toolingStatus.isFeatureEnabled && hasConfiguration && !isBusy && !isRunning
    }

    var canStop: Bool {
        toolingStatus.isFeatureEnabled && hasContainer && isRunning && !isBusy
    }

    var canRestart: Bool {
        toolingStatus.isFeatureEnabled && hasConfiguration && hasContainer && !isBusy
    }

    var canRebuild: Bool {
        toolingStatus.isFeatureEnabled && hasConfiguration && !isBusy
    }

    var canDelete: Bool {
        toolingStatus.isFeatureEnabled && hasContainer && !isBusy
    }

    var canOpenTerminal: Bool {
        toolingStatus.isFeatureEnabled && isRunning && containerID?.nonEmpty != nil && !isBusy
    }

    mutating func apply(snapshot: DevContainerWorkspaceSnapshot) {
        configuration = snapshot.configuration
        runtimeStatus = snapshot.runtimeStatus
        containerID = snapshot.containerID
        containerName = snapshot.containerName
        imageName = snapshot.imageName
        resourceUsage = snapshot.resourceUsage
        containerCount = snapshot.containerCount
        detailsErrorMessage = snapshot.detailsErrorMessage
        lastUpdatedAt = snapshot.lastUpdatedAt
        toolingStatus = snapshot.toolingStatus
        diagnosticIssue = snapshot.diagnosticIssue
    }
}

struct DevContainerGlobalSummary: Identifiable, Equatable, Sendable {
    let worktreeID: UUID
    let repositoryID: UUID
    let namespaceName: String
    let repositoryName: String
    let worktreeName: String
    let runtimeStatus: DevContainerRuntimeStatus
    let containerName: String?
    let containerID: String?
    let imageName: String?
    let resourceUsage: DevContainerResourceUsage?
    let activeOperation: DevContainerOperation?
    let detailsErrorMessage: String?
    let toolingStatus: DevContainerToolingStatus
    let diagnosticIssue: DevContainerDiagnosticIssue?
    let lastUpdatedAt: Date?

    var id: UUID { worktreeID }

    var isActive: Bool {
        activeOperation != nil || runtimeStatus == .running
    }
}
