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

    init(
        configuration: DevContainerConfiguration?,
        runtimeStatus: DevContainerRuntimeStatus = .unknown,
        containerID: String? = nil,
        containerName: String? = nil,
        imageName: String? = nil,
        resourceUsage: DevContainerResourceUsage? = nil,
        containerCount: Int = 0,
        detailsErrorMessage: String? = nil,
        lastUpdatedAt: Date? = nil
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
    }

    var hasConfiguration: Bool {
        configuration != nil
    }

    var hasContainer: Bool {
        containerID != nil || containerCount > 0
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
        isLogStreaming: Bool = false
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
            lastUpdatedAt: snapshot.lastUpdatedAt
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
        hasConfiguration && !isBusy && !isRunning
    }

    var canStop: Bool {
        hasContainer && isRunning && !isBusy
    }

    var canRestart: Bool {
        hasConfiguration && hasContainer && !isBusy
    }

    var canRebuild: Bool {
        hasConfiguration && !isBusy
    }

    var canDelete: Bool {
        hasContainer && !isBusy
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
    }
}
