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
    case gitOperation

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

enum TerminalTabRetentionMode: String, Codable, CaseIterable, Identifiable {
    case shortRetain
    case manualClose
    case runningOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shortRetain:
            "Short Retain"
        case .manualClose:
            "Manual Close"
        case .runningOnly:
            "Running Only"
        }
    }
}

enum WorktreeLifecycle: String, Codable, CaseIterable, Identifiable {
    case active
    case integrating
    case merged

    var id: String { rawValue }
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
    let stdinText: String?
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
    let fetchErrorMessage: String?
    let defaultBranchSyncErrorMessage: String?
    let defaultBranchSyncSummary: String?

    var errorMessage: String? {
        [fetchErrorMessage, defaultBranchSyncErrorMessage]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
            .joined(separator: "\n\n")
            .nonEmpty
    }
}

struct WorktreeStatus: Sendable {
    var aheadCount: Int = 0
    var behindCount: Int = 0
    var addedLines: Int = 0
    var deletedLines: Int = 0
    var hasUncommittedChanges: Bool = false
    var hasConflicts: Bool = false
}

enum SyncStrategy {
    case rebase
    case merge
}

struct TerminalTabState: Sendable {
    let runID: UUID
    let worktreeID: UUID
    var isVisible = true
    var isPinned = false
    var lastViewedAt: Date?
    var completedAt: Date?
    var closedAt: Date?
}

struct WorktreeRemovalDraft: Identifiable, Sendable {
    let id: UUID
    let path: String
}

struct IntegrationConflictDraft: Identifiable, Sendable {
    let repositoryID: UUID
    let sourceWorktreeID: UUID
    let defaultWorktreeID: UUID
    let sourceBranch: String
    let defaultBranch: String
    let message: String

    var id: UUID { sourceWorktreeID }

    var commitMessage: String {
        "Integrate \(sourceBranch) into \(defaultBranch)"
    }
}

struct WorkspaceDiffSnapshot: Sendable {
    let files: [WorkspaceDiffFile]

    var hasChanges: Bool {
        !files.isEmpty
    }
}

struct WorkspaceDiffFile: Identifiable, Sendable {
    let path: String
    let status: WorkspaceDiffFileStatus
    let patch: String

    var id: String { path }
}

enum WorkspaceDiffFileStatus: String, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case unmerged
    case untracked
    case unknown

    var displayName: String {
        rawValue.capitalized
    }
}

enum WorktreeIntegrationResult: Sendable {
    case committed
    case conflicts(String)
}

struct TerminalTabBookkeeping: Sendable {
    private(set) var tabs: [UUID: TerminalTabState] = [:]
    private(set) var selectedRunIDsByWorktree: [UUID: UUID] = [:]
    private(set) var planTabSelectedWorktrees: Set<UUID> = []

    mutating func selectPlanTab(for worktreeID: UUID) {
        planTabSelectedWorktrees.insert(worktreeID)
    }

    mutating func deselectPlanTab(for worktreeID: UUID) {
        planTabSelectedWorktrees.remove(worktreeID)
    }

    func isPlanTabSelected(for worktreeID: UUID) -> Bool {
        planTabSelectedWorktrees.contains(worktreeID)
    }

    mutating func activate(runID: UUID, worktreeID: UUID, viewedAt: Date = .now) {
        var tab = tabs[runID] ?? TerminalTabState(runID: runID, worktreeID: worktreeID)
        tab.isVisible = true
        tab.closedAt = nil
        tab.lastViewedAt = viewedAt
        tabs[runID] = tab
        selectedRunIDsByWorktree[worktreeID] = runID
    }

    mutating func markCompleted(runID: UUID, at: Date = .now) {
        guard var tab = tabs[runID] else { return }
        tab.completedAt = at
        tabs[runID] = tab
    }

    mutating func setPinned(_ isPinned: Bool, for runID: UUID) {
        guard var tab = tabs[runID] else { return }
        tab.isPinned = isPinned
        tabs[runID] = tab
    }

    mutating func hide(runID: UUID) {
        guard var tab = tabs[runID] else { return }
        tab.isVisible = false
        tab.closedAt = .now
        tabs[runID] = tab

        guard selectedRunIDsByWorktree[tab.worktreeID] == runID else { return }
        selectedRunIDsByWorktree[tab.worktreeID] = visibleRunIDs(for: tab.worktreeID).first
    }

    mutating func removeWorktree(_ worktreeID: UUID) {
        tabs = tabs.filter { $0.value.worktreeID != worktreeID }
        selectedRunIDsByWorktree.removeValue(forKey: worktreeID)
        planTabSelectedWorktrees.remove(worktreeID)
    }

    func tabState(for runID: UUID) -> TerminalTabState? {
        tabs[runID]
    }

    func visibleRunIDs(for worktreeID: UUID) -> [UUID] {
        tabs.values
            .filter { $0.worktreeID == worktreeID && $0.isVisible }
            .sorted(by: compareTabs(_:_:))
            .map(\.runID)
    }

    func selectedVisibleRunID(for worktreeID: UUID) -> UUID? {
        if let selected = selectedRunIDsByWorktree[worktreeID], tabs[selected]?.isVisible == true {
            return selected
        }
        return visibleRunIDs(for: worktreeID).first
    }

    private func compareTabs(_ lhs: TerminalTabState, _ rhs: TerminalTabState) -> Bool {
        switch (lhs.lastViewedAt, rhs.lastViewedAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.runID.uuidString > rhs.runID.uuidString
        }
    }
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
    static let terminalTabRetentionModeKey = "terminal.tabs.retentionMode"
    static let nodeAutoUpdateEnabledKey = "node.autoUpdateEnabled"
    static let nodeAutoUpdateIntervalKey = "node.autoUpdateIntervalSeconds"
    static let nodeDefaultVersionSpecKey = "node.defaultVersionSpec"
    static let defaultNodeAutoUpdateEnabled = true
    static let defaultNodeAutoUpdateInterval: Double = 21_600
    static let defaultNodeVersionSpec = "lts/*"
    static let defaultTerminalTabRetentionMode = TerminalTabRetentionMode.shortRetain

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

    static var terminalTabRetentionMode: TerminalTabRetentionMode {
        let defaults = UserDefaults.standard
        guard
            let value = defaults.string(forKey: terminalTabRetentionModeKey),
            let mode = TerminalTabRetentionMode(rawValue: value)
        else {
            return defaultTerminalTabRetentionMode
        }
        return mode
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
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }

    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var shellEscaped: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
