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
    case runConfiguration

    var id: String { rawValue }
}

enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI
    case anthropic
    case openRouter
    case ollama
    case lmStudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .anthropic:
            "Anthropic"
        case .openRouter:
            "OpenRouter"
        case .ollama:
            "Ollama"
        case .lmStudio:
            "LM Studio"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI:
            "https://api.openai.com/v1"
        case .anthropic:
            "https://api.anthropic.com/v1"
        case .openRouter:
            "https://openrouter.ai/api/v1"
        case .ollama:
            "http://127.0.0.1:11434"
        case .lmStudio:
            "http://127.0.0.1:1234/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:
            "gpt-5.4-mini"
        case .anthropic:
            "claude-sonnet-4-5"
        case .openRouter:
            "openai/gpt-5.4-mini"
        case .ollama:
            "llama3.2"
        case .lmStudio:
            "local-model"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .anthropic, .openRouter:
            true
        case .ollama, .lmStudio:
            false
        }
    }
}

struct AIProviderConfiguration: Sendable, Equatable {
    let provider: AIProviderKind
    let apiKey: String?
    let model: String
    let baseURL: String

    var isConfigured: Bool {
        if provider.requiresAPIKey {
            return apiKey?.nonEmpty != nil
        }
        return true
    }
}

enum WorktreeIssueKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bug
    case feature
    case refactor
    case chore

    var id: String { rawValue }

    var branchPrefix: String { rawValue }

    var displayName: String { rawValue.uppercased() }
}

struct AIWorktreeNameSuggestion: Sendable, Equatable {
    let kind: WorktreeIssueKind
    let ticketNumber: Int?
    let shortSummary: String
    let branchName: String
}

struct AIRunSummary: Sendable, Equatable {
    let title: String
    let summary: String
}

enum RunConfigurationSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case native
    case vscode
    case cursor
    case xcode
    case jetbrains

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .native:
            "Native Configs"
        case .vscode:
            "VS Code"
        case .cursor:
            "Cursor"
        case .xcode:
            "Xcode"
        case .jetbrains:
            "JetBrains"
        }
    }
}

enum RunConfigurationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case makeTarget
    case npmScript
    case shellCommand
    case nodeLaunch
    case xcodeScheme
    case jetbrainsConfiguration

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .makeTarget:
            "Make"
        case .npmScript:
            "NPM Script"
        case .shellCommand:
            "Shell"
        case .nodeLaunch:
            "Node"
        case .xcodeScheme:
            "Xcode Scheme"
        case .jetbrainsConfiguration:
            "JetBrains"
        }
    }
}

enum RunConfigurationExecutionBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct
    case buildOnly
    case openInDevTool

    var id: String { rawValue }
}

enum SupportedDevTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case cursor
    case vscode
    case zed
    case xcode
    case intellijIdea
    case goland
    case phpstorm
    case webstorm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursor:
            "Cursor"
        case .vscode:
            "VS Code"
        case .zed:
            "Zed"
        case .xcode:
            "Xcode"
        case .intellijIdea:
            "IntelliJ IDEA"
        case .goland:
            "GoLand"
        case .phpstorm:
            "PhpStorm"
        case .webstorm:
            "WebStorm"
        }
    }

    var applicationName: String {
        switch self {
        case .cursor:
            "Cursor"
        case .vscode:
            "Visual Studio Code"
        case .zed:
            "Zed"
        case .xcode:
            "Xcode"
        case .intellijIdea:
            "IntelliJ IDEA"
        case .goland:
            "GoLand"
        case .phpstorm:
            "PhpStorm"
        case .webstorm:
            "WebStorm"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .cursor:
            nil
        case .vscode:
            "com.microsoft.VSCode"
        case .zed:
            "dev.zed.Zed"
        case .xcode:
            "com.apple.dt.Xcode"
        case .intellijIdea:
            "com.jetbrains.intellij"
        case .goland:
            "com.jetbrains.goland"
        case .phpstorm:
            "com.jetbrains.PhpStorm"
        case .webstorm:
            "com.jetbrains.WebStorm"
        }
    }

    var systemImageName: String {
        switch self {
        case .xcode:
            "hammer"
        case .cursor, .vscode, .zed:
            "laptopcomputer"
        case .intellijIdea, .goland, .phpstorm, .webstorm:
            "shippingbox"
        }
    }

    var sortPriority: Int {
        switch self {
        case .cursor:
            0
        case .vscode:
            1
        case .zed:
            2
        case .xcode:
            3
        case .goland:
            4
        case .webstorm:
            5
        case .phpstorm:
            6
        case .intellijIdea:
            7
        }
    }
}

struct RunConfiguration: Identifiable, Sendable {
    let id: String
    let name: String
    let source: RunConfigurationSource
    let kind: RunConfigurationKind
    let runnerType: String
    let workingDirectory: String?
    let command: String?
    let arguments: [String]
    let environment: [String: String]
    let isDebugCapable: Bool
    let rawSourcePath: String
    let executionBehavior: RunConfigurationExecutionBehavior
    let preferredDevTool: SupportedDevTool?
    let runtimeRequirement: NodeRuntimeRequirement?

    init(
        id: String,
        name: String,
        source: RunConfigurationSource,
        kind: RunConfigurationKind,
        runnerType: String,
        workingDirectory: String? = nil,
        command: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        isDebugCapable: Bool = false,
        rawSourcePath: String,
        executionBehavior: RunConfigurationExecutionBehavior = .direct,
        preferredDevTool: SupportedDevTool? = nil,
        runtimeRequirement: NodeRuntimeRequirement? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.kind = kind
        self.runnerType = runnerType
        self.workingDirectory = workingDirectory
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.isDebugCapable = isDebugCapable
        self.rawSourcePath = rawSourcePath
        self.executionBehavior = executionBehavior
        self.preferredDevTool = preferredDevTool
        self.runtimeRequirement = runtimeRequirement
    }

    var isDirectlyRunnable: Bool {
        command?.nonEmpty != nil && executionBehavior != .openInDevTool
    }

    var displaySourceName: String {
        if source == .jetbrains, let preferredDevTool {
            return preferredDevTool.displayName
        }
        return source.displayName
    }

    var displayCommandLine: String? {
        guard let command = command?.nonEmpty else { return nil }
        return ([command] + arguments).joined(separator: " ")
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
            "copilot"
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
            "cd \(path.shellEscaped) && copilot"
        case .cursorCLI:
            "cd \(path.shellEscaped) && cursor ."
        }
    }

    /// Starts the agent with a pre-filled task prompt.
    /// For tools that support a documented non-interactive mode, prefer that over PTY stdin
    /// injection so scripted runs behave predictably.
    func launchCommandWithPrompt(_ prompt: String, in path: String) -> String {
        switch self {
        case .none:
            ""
        case .claudeCode:
            // Claude Code uses print mode for automation. Permissions must be non-interactive.
            "cd \(path.shellEscaped) && claude -p --dangerously-skip-permissions \(prompt.shellEscaped)"
        case .codex:
            // Codex CLI uses `exec` in automation contexts; `--full-auto` enables edits.
            "cd \(path.shellEscaped) && codex exec --full-auto \(prompt.shellEscaped)"
        case .githubCopilot:
            // copilot -p executes the task and exits cleanly; --allow-all-tools enables agentic execution
            "cd \(path.shellEscaped) && copilot -p \(prompt.shellEscaped) --allow-all-tools"
        case .cursorCLI:
            launchCommand(in: path)
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

enum TicketProviderKind: String, Codable, CaseIterable, Identifiable {
    case github

    var id: String { rawValue }
}

struct TicketProviderStatus: Sendable, Equatable {
    let provider: TicketProviderKind
    let isAvailable: Bool
    let message: String
}

struct GitHubIssueSearchResult: Identifiable, Sendable, Equatable {
    let number: Int
    let title: String
    let url: String
    let state: String

    var id: Int { number }
}

struct GitHubIssueComment: Identifiable, Sendable, Equatable {
    let author: String
    let body: String
    let createdAt: Date
    let url: String?

    var id: String { url ?? "\(author)-\(createdAt.timeIntervalSince1970)" }
}

struct GitHubIssueDetails: Sendable, Equatable {
    let number: Int
    let title: String
    let body: String
    let url: String
    let labels: [String]
    let comments: [GitHubIssueComment]
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
    let showsAgentIndicator: Bool
    let executable: String
    let arguments: [String]
    let displayCommandLine: String?
    let currentDirectoryURL: URL?
    let repositoryID: UUID
    let worktreeID: UUID?
    let runtimeRequirement: NodeRuntimeRequirement?
    let stdinText: String?
    let environment: [String: String]

    init(
        title: String,
        actionKind: ActionKind,
        showsAgentIndicator: Bool = false,
        executable: String,
        arguments: [String],
        displayCommandLine: String? = nil,
        currentDirectoryURL: URL? = nil,
        repositoryID: UUID,
        worktreeID: UUID? = nil,
        runtimeRequirement: NodeRuntimeRequirement? = nil,
        stdinText: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.title = title
        self.actionKind = actionKind
        self.showsAgentIndicator = showsAgentIndicator
        self.executable = executable
        self.arguments = arguments
        self.displayCommandLine = displayCommandLine
        self.currentDirectoryURL = currentDirectoryURL
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
        self.runtimeRequirement = runtimeRequirement
        self.stdinText = stdinText
        self.environment = environment
    }
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
    var openedAt: Date?
    var lastViewedAt: Date?
    var completedAt: Date?
    var closedAt: Date?
}

struct TerminalCloseConfirmationDraft: Identifiable, Sendable {
    let runID: UUID
    let title: String
    let message: String

    var id: UUID { runID }
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
        if tab.isVisible == false || tab.openedAt == nil {
            tab.openedAt = viewedAt
        }
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
        switch (lhs.openedAt, rhs.openedAt) {
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
    static let aiProviderKey = "ai.provider"
    static let aiAPIKeyKey = "ai.apiKey"
    static let aiBaseURLKey = "ai.baseURL"
    static let aiModelKey = "ai.model"
    static let defaultNodeAutoUpdateEnabled = true
    static let defaultNodeAutoUpdateInterval: Double = 21_600
    static let defaultNodeVersionSpec = "lts/*"
    static let defaultTerminalTabRetentionMode = TerminalTabRetentionMode.shortRetain
    static let defaultAIProvider = AIProviderKind.openAI

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

    static var aiProvider: AIProviderKind {
        let defaults = UserDefaults.standard
        guard
            let value = defaults.string(forKey: aiProviderKey),
            let provider = AIProviderKind(rawValue: value)
        else {
            return defaultAIProvider
        }
        return provider
    }

    static var aiAPIKey: String? {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: aiAPIKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    static var aiBaseURL: String {
        let defaults = UserDefaults.standard
        let value = defaults.string(forKey: aiBaseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.nonEmpty ?? aiProvider.defaultBaseURL
    }

    static var aiModel: String {
        let defaults = UserDefaults.standard
        let value = defaults.string(forKey: aiModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.nonEmpty ?? aiProvider.defaultModel
    }

    static var aiConfiguration: AIProviderConfiguration {
        AIProviderConfiguration(
            provider: aiProvider,
            apiKey: aiAPIKey,
            model: aiModel,
            baseURL: aiBaseURL
        )
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
