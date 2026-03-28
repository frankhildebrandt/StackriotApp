import Foundation

enum RepositoryHealth: String, Codable, CaseIterable, Identifiable {
    case ready
    case missing
    case broken

    var id: String { rawValue }
}

enum RunStatusKind: String, Codable, CaseIterable, Identifiable {
    case pending
    case running
    case succeeded
    case failed
    case cancelled

    var id: String { rawValue }
}

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case openIDE
    case makeTarget
    case npmScript
    case installDependencies
    case aiAgent

    var id: String { rawValue }
}

enum SupportedIDE: String, Codable, CaseIterable, Identifiable {
    case cursor
    case vscode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursor:
            "Cursor"
        case .vscode:
            "VS Code"
        }
    }

    var applicationName: String {
        switch self {
        case .cursor:
            "Cursor"
        case .vscode:
            "Visual Studio Code"
        }
    }
}

enum AIAgentTool: String, Codable, CaseIterable, Identifiable {
    case none
    case claudeCode
    case codex
    case githubCopilot
    case cursorCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            "None"
        case .claudeCode:
            "Claude Code"
        case .codex:
            "Codex"
        case .githubCopilot:
            "GitHub Copilot"
        case .cursorCLI:
            "Cursor CLI"
        }
    }

    var executableName: String? {
        switch self {
        case .none:
            nil
        case .claudeCode:
            "claude"
        case .codex:
            "codex"
        case .githubCopilot:
            "gh"
        case .cursorCLI:
            "cursor"
        }
    }

    func launchCommand(in path: String) -> String {
        switch self {
        case .none:
            ""
        case .claudeCode:
            "cd \(path.shellEscaped) && claude"
        case .codex:
            "cd \(path.shellEscaped) && codex"
        case .githubCopilot:
            "cd \(path.shellEscaped) && gh copilot suggest"
        case .cursorCLI:
            "cd \(path.shellEscaped) && cursor ."
        }
    }
}

enum DependencyInstallMode: String, Codable, CaseIterable, Identifiable {
    case install
    case update

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .install:
            "Install"
        case .update:
            "Update"
        }
    }
}

enum SSHKeyKind: String, Codable, CaseIterable, Identifiable {
    case imported
    case generated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .imported:
            "Imported"
        case .generated:
            "Generated"
        }
    }
}

struct ClonedRepositoryInfo: Sendable {
    let displayName: String
    let remoteURL: URL
    let bareRepositoryPath: URL
    let defaultBranch: String
    let initialRemoteName: String
}

struct CreatedWorktreeInfo: Sendable {
    let branchName: String
    let path: URL
}

struct CommandExecutionDescriptor: Sendable {
    let title: String
    let actionKind: ActionKind
    let executable: String
    let arguments: [String]
    let displayCommandLine: String?
    let currentDirectoryURL: URL?
    let repositoryID: UUID
    let worktreeID: UUID?
    let runtimeRequirement: NodeRuntimeRequirement?
}

struct RemoteExecutionContext: Sendable {
    let name: String
    let url: String
    let fetchEnabled: Bool
    let privateKeyRef: String?
}

struct RepositoryRefreshInfo: Sendable {
    let status: RepositoryHealth
    let defaultBranch: String
    let fetchedAt: Date?
    let errorMessage: String?
}

struct SSHKeyMaterial: Sendable {
    let displayName: String
    let kind: SSHKeyKind
    let publicKey: String
    let privateKeyData: Data
}

enum PackageManagerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case npm
    case pnpm
    case yarn

    var id: String { rawValue }
}

enum NodeVersionSource: String, Codable, Sendable {
    case packageEngines
    case nvmrc
    case nodeVersionFile
    case defaultLTS
}

struct NodeRuntimeRequirement: Sendable {
    let packageManager: PackageManagerKind
    let nodeVersionSpec: String
    let versionSource: NodeVersionSource
}

struct ResolvedNodeRuntime: Sendable {
    let requestedVersionSpec: String
    let resolvedVersion: String
    let versionSource: NodeVersionSource
    let nodeBinaryPath: String
    let npmBinaryPath: String
    let corepackBinaryPath: String
    let binDirectoryPath: String
    let environment: [String: String]
}

struct PreparedCommandExecution: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
}

struct NodeRuntimeStatusSnapshot: Codable, Sendable {
    var bootstrapState = "Not initialized"
    var defaultVersionSpec = "lts/*"
    var resolvedDefaultVersion = "Unavailable"
    var runtimeRootPath = ""
    var npmCachePath = ""
    var lastUpdatedAt: Date?
    var lastErrorMessage: String?
}

enum AppPreferences {
    static let autoRefreshEnabledKey = "repositories.autoRefreshEnabled"
    static let autoRefreshIntervalKey = "repositories.autoRefreshIntervalSeconds"
    static let defaultAutoRefreshEnabled = true
    static let defaultAutoRefreshInterval: Double = 900
    static let nodeAutoUpdateEnabledKey = "node.autoUpdateEnabled"
    static let nodeAutoUpdateIntervalKey = "node.autoUpdateIntervalSeconds"
    static let nodeDefaultVersionSpecKey = "node.defaultVersionSpec"
    static let defaultNodeAutoUpdateEnabled = true
    static let defaultNodeAutoUpdateInterval: Double = 21_600
    static let defaultNodeVersionSpec = "lts/*"

    static var autoRefreshEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: autoRefreshEnabledKey) == nil {
            return defaultAutoRefreshEnabled
        }
        return defaults.bool(forKey: autoRefreshEnabledKey)
    }

    static var autoRefreshInterval: TimeInterval {
        let defaults = UserDefaults.standard
        let value = defaults.double(forKey: autoRefreshIntervalKey)
        return value > 0 ? value : defaultAutoRefreshInterval
    }

    static var nodeAutoUpdateEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: nodeAutoUpdateEnabledKey) == nil {
            return defaultNodeAutoUpdateEnabled
        }
        return defaults.bool(forKey: nodeAutoUpdateEnabledKey)
    }

    static var nodeAutoUpdateInterval: TimeInterval {
        let defaults = UserDefaults.standard
        let value = defaults.double(forKey: nodeAutoUpdateIntervalKey)
        return value > 0 ? value : defaultNodeAutoUpdateInterval
    }

    static var nodeDefaultVersionSpec: String {
        let defaults = UserDefaults.standard
        let value = defaults.string(forKey: nodeDefaultVersionSpecKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : defaultNodeVersionSpec
    }
}

struct AgentSessionState: Sendable {
    let id: UUID
    let worktreeID: UUID
    let tool: AIAgentTool
    var pid: pid_t
    let startedAt: Date
    var phase: AgentSessionPhase
}

enum AgentSessionPhase: Sendable {
    case launching
    case running
    case finished(exitCode: Int32?)
    case errored(String)
}

extension String {
    var shellEscaped: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
