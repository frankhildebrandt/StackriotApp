import Foundation

enum MCPServerLifecycleState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case error
}

enum MCPLogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
}

struct MCPServerConfiguration: Sendable, Equatable {
    static let endpointPath = "/mcp"
    static let sseEndpointPath = "/sse"

    var enabled: Bool
    var listenAddress: String
    var port: Int
    var apiToken: String?
    var exposeReadOnlyToolsOnly: Bool

    var endpointURLString: String {
        "http://\(formattedHost):\(port)\(Self.endpointPath)"
    }

    var sseEndpointURLString: String {
        "http://\(formattedHost):\(port)\(Self.sseEndpointPath)"
    }

    var formattedHost: String {
        if listenAddress.contains(":") && !listenAddress.hasPrefix("[") {
            return "[\(listenAddress)]"
        }
        return listenAddress
    }
}

struct MCPServerStatus: Sendable, Equatable {
    var state: MCPServerLifecycleState
    var listenAddress: String
    var port: Int
    var endpointPath: String
    var activeSessionCount: Int
    var startedAt: Date?
    var lastErrorMessage: String?
    var lastEventMessage: String?

    static func idle(configuration: MCPServerConfiguration = AppPreferences.mcpConfiguration) -> Self {
        Self(
            state: configuration.enabled ? .starting : .stopped,
            listenAddress: configuration.listenAddress,
            port: configuration.port,
            endpointPath: MCPServerConfiguration.endpointPath,
            activeSessionCount: 0,
            startedAt: nil,
            lastErrorMessage: nil,
            lastEventMessage: configuration.enabled ? "Waiting to start MCP server." : "MCP server is disabled."
        )
    }

    var isRunning: Bool {
        state == .running
    }

    var endpointURLString: String {
        MCPServerConfiguration(
            enabled: state != .stopped,
            listenAddress: listenAddress,
            port: port,
            apiToken: nil,
            exposeReadOnlyToolsOnly: true
        )
        .endpointURLString
    }

    var sseEndpointURLString: String {
        MCPServerConfiguration(
            enabled: state != .stopped,
            listenAddress: listenAddress,
            port: port,
            apiToken: nil,
            exposeReadOnlyToolsOnly: true
        )
        .sseEndpointURLString
    }
}

struct MCPLogEntry: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var timestamp: Date
    var level: MCPLogLevel
    var category: String
    var message: String
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        level: MCPLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

enum MCPClientSnippetKind: String, CaseIterable, Identifiable, Sendable {
    case codex
    case cursor
    case claudeDesktop
    case generic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            "Codex"
        case .cursor:
            "Cursor"
        case .claudeDesktop:
            "Claude Desktop"
        case .generic:
            "Generic Client"
        }
    }

    var fileHint: String {
        switch self {
        case .codex:
            "~/.codex/config.toml"
        case .cursor:
            "~/.cursor/mcp.json"
        case .claudeDesktop:
            "~/Library/Application Support/Claude/claude_desktop_config.json"
        case .generic:
            "client config"
        }
    }
}
