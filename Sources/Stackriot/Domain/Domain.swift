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

/// Value passed to `WindowGroup(for:)` for read-only Cursor agent markdown snapshots.
struct AgentMarkdownWindowPayload: Hashable, Codable {
    let id: UUID
    var title: String
    var markdown: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case openIDE
    case makeTarget
    case npmScript
    case installDependencies
    case aiAgent
    case devContainer
    case gitOperation
    case runConfiguration

    var id: String { rawValue }
}

enum DevContainerCLIStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case devcontainerCLI
    case npx

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            "Auto"
        case .devcontainerCLI:
            "devcontainer CLI"
        case .npx:
            "npx @devcontainers/cli"
        }
    }
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

struct JiraConfiguration: Sendable, Equatable {
    let baseURL: String
    let userEmail: String
    let apiToken: String?

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedUserEmail: String {
        userEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        trimmedBaseURL.nonEmpty != nil
            && trimmedUserEmail.nonEmpty != nil
            && apiToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
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
    let ticketIdentifier: String?
    let shortSummary: String
    let branchName: String
}

extension AIWorktreeNameSuggestion {
    init(kind: WorktreeIssueKind, ticketNumber: Int?, shortSummary: String, branchName: String) {
        self.init(
            kind: kind,
            ticketIdentifier: ticketNumber.map(String.init),
            shortSummary: shortSummary,
            branchName: branchName
        )
    }

    var ticketNumber: Int? {
        ticketIdentifier.flatMap(Int.init)
    }
}

struct AIRunSummary: Sendable, Equatable {
    let title: String
    let summary: String
}

struct AIIntentSummary: Sendable, Equatable {
    let title: String
    let summary: String
}

struct QuickIntentModifierSet: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let shift = QuickIntentModifierSet(rawValue: 1 << 0)
    static let control = QuickIntentModifierSet(rawValue: 1 << 1)
    static let option = QuickIntentModifierSet(rawValue: 1 << 2)
    static let command = QuickIntentModifierSet(rawValue: 1 << 3)
}

enum QuickIntentCaptureSource: String, Codable, Sendable {
    case accessibilitySelection
    case clipboard
    case sharedText
    case sharedFile
    case empty

    var displayName: String {
        switch self {
        case .accessibilitySelection:
            "Markierung"
        case .clipboard:
            "Zwischenablage"
        case .sharedText:
            "Geteilter Text"
        case .sharedFile:
            "Geteilte Datei"
        case .empty:
            "Leer"
        }
    }
}

struct QuickIntentHotkeyConfiguration: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var keyCode: UInt16
    var modifiers: QuickIntentModifierSet

    static let `default` = QuickIntentHotkeyConfiguration(
        isEnabled: true,
        keyCode: 34,
        modifiers: [.command, .option]
    )
}

struct AgentLaunchOptions: Sendable, Equatable {
    let copilotModelOverride: String?
    let activatesTerminalTab: Bool

    init(copilotModelOverride: String? = nil, activatesTerminalTab: Bool = true) {
        let trimmedOverride = copilotModelOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        if let trimmedOverride, trimmedOverride.caseInsensitiveCompare("auto") != .orderedSame {
            self.copilotModelOverride = trimmedOverride
        } else {
            self.copilotModelOverride = nil
        }
        self.activatesTerminalTab = activatesTerminalTab
    }
}

struct AgentPromptCommandComponents: Sendable, Equatable {
    let arguments: [String]
    let displayCommandLine: String
}

struct CopilotModelOption: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let displayName: String
    let isAuto: Bool

    static let auto = CopilotModelOption(id: "auto", displayName: "Auto", isAuto: true)
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

struct RunConfiguration: Identifiable, Sendable, Equatable {
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
            "Cursor"
        }
    }

    var systemImageName: String {
        switch self {
        case .none:
            "sparkles"
        case .claudeCode:
            "sparkles.rectangle.stack"
        case .codex:
            "terminal"
        case .githubCopilot:
            "chevron.left.forwardslash.chevron.right"
        case .cursorCLI:
            "cursorarrow.click.2"
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
            "cursor-agent"
        }
    }

    var supportsPlanning: Bool {
        switch self {
        case .claudeCode, .codex, .githubCopilot, .cursorCLI:
            true
        default:
            false
        }
    }

    var supportsPlanResume: Bool {
        switch self {
        case .codex, .cursorCLI:
            true
        default:
            false
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
            "cd \(path.shellEscaped) && cursor-agent"
        }
    }

    /// Starts the agent with a pre-filled task prompt.
    /// For tools that support a documented non-interactive mode, prefer that over PTY stdin
    /// injection so scripted runs behave predictably.
    func launchCommandWithPrompt(
        _ prompt: String,
        in path: String,
        options: AgentLaunchOptions = AgentLaunchOptions()
    ) -> String {
        guard let components = promptCommandComponents(for: prompt, options: options) else {
            return launchCommand(in: path)
        }
        return "cd \(path.shellEscaped) && \(components.displayCommandLine)"
    }

    func promptCommandComponents(
        for prompt: String,
        options: AgentLaunchOptions = AgentLaunchOptions()
    ) -> AgentPromptCommandComponents? {
        switch self {
        case .none:
            return nil
        case .claudeCode:
            // Claude Code uses print mode for automation. Permissions must be non-interactive.
            return AgentPromptCommandComponents(
                arguments: ["-p", "--dangerously-skip-permissions", "--output-format", "stream-json", prompt],
                displayCommandLine: "claude -p --dangerously-skip-permissions --output-format stream-json \(prompt.shellEscaped)"
            )
        case .codex:
            // Codex CLI uses `exec` in automation contexts; `--full-auto` enables edits.
            return AgentPromptCommandComponents(
                arguments: ["exec", "--full-auto", "--json", "--color", "never", prompt],
                displayCommandLine: "codex exec --full-auto --json --color never \(prompt.shellEscaped)"
            )
        case .githubCopilot:
            // `--model` is only set when the user explicitly selects a concrete model.
            let modelArguments = options.copilotModelOverride.map { ["--model", $0] } ?? []
            let modelDisplaySuffix = options.copilotModelOverride.map { " --model \($0.shellEscaped)" } ?? ""
            return AgentPromptCommandComponents(
                arguments: ["-p", prompt] + modelArguments + ["--allow-all-tools", "--output-format", "json"],
                displayCommandLine: "copilot -p \(prompt.shellEscaped)\(modelDisplaySuffix) --allow-all-tools --output-format json"
            )
        case .cursorCLI:
            return AgentPromptCommandComponents(
                arguments: ["--print", "--output-format", "stream-json", "--stream-partial-output", "--trust", "--force", prompt],
                displayCommandLine: "cursor-agent --print --output-format stream-json --stream-partial-output --trust --force \(prompt.shellEscaped)"
            )
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

enum WorktreeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular
    case idea

    var id: String { rawValue }
}

enum WorktreeCardColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case blue
    case green
    case orange
    case purple
    case pink
    case slate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            "Keine"
        case .blue:
            "Blau"
        case .green:
            "Gruen"
        case .orange:
            "Orange"
        case .purple:
            "Lila"
        case .pink:
            "Pink"
        case .slate:
            "Slate"
        }
    }
}

enum TicketProviderKind: String, Codable, CaseIterable, Identifiable {
    case github
    case jira

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github:
            "GitHub"
        case .jira:
            "Jira Cloud"
        }
    }

    var ticketLabel: String {
        switch self {
        case .github:
            "Issue"
        case .jira:
            "Ticket"
        }
    }

    var searchPrompt: String {
        switch self {
        case .github:
            "Issue # oder Titel"
        case .jira:
            "Jira-Key oder Titel"
        }
    }

    var searchHint: String {
        switch self {
        case .github:
            "Suche nach einer Issue-Nummer oder einem Titel, um optional Kontext fuer diesen Worktree zu uebernehmen."
        case .jira:
            "Suche nach einem Jira-Key wie ABC-123 oder nach Begriffen aus dem Summary, um optional Kontext fuer diesen Worktree zu uebernehmen."
        }
    }
}

struct TicketProviderStatus: Sendable, Equatable {
    let provider: TicketProviderKind
    let isAvailable: Bool
    let message: String
}

struct TicketReference: Sendable, Equatable, Codable {
    let provider: TicketProviderKind
    let id: String
    let displayID: String
}

struct TicketSearchResult: Identifiable, Sendable, Equatable {
    let reference: TicketReference
    let title: String
    let url: String
    let status: String

    var id: String { "\(reference.provider.rawValue):\(reference.id)" }
}

extension TicketSearchResult {
    init(number: Int, title: String, url: String, state: String) {
        self.init(
            reference: TicketReference(provider: .github, id: String(number), displayID: "#\(number)"),
            title: title,
            url: url,
            status: state
        )
    }

    var number: Int {
        Int(reference.id) ?? 0
    }

    var state: String { status }
}

struct TicketComment: Identifiable, Sendable, Equatable {
    let author: String
    let body: String
    let createdAt: Date
    let url: String?

    var id: String { url ?? "\(author)-\(createdAt.timeIntervalSince1970)" }
}

struct TicketDetails: Sendable, Equatable {
    let reference: TicketReference
    let title: String
    let body: String
    let url: String
    let labels: [String]
    let comments: [TicketComment]

    var provider: TicketProviderKind { reference.provider }
}

extension TicketDetails {
    init(number: Int, title: String, body: String, url: String, labels: [String], comments: [TicketComment]) {
        self.init(
            reference: TicketReference(provider: .github, id: String(number), displayID: "#\(number)"),
            title: title,
            body: body,
            url: url,
            labels: labels,
            comments: comments
        )
    }

    var number: Int {
        Int(reference.id) ?? 0
    }
}

typealias GitHubIssueSearchResult = TicketSearchResult
typealias GitHubIssueComment = TicketComment
typealias GitHubIssueDetails = TicketDetails

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
    let activatesTerminalTab: Bool
    let runConfigurationID: String?
    let executable: String
    let arguments: [String]
    let displayCommandLine: String?
    let currentDirectoryURL: URL?
    let repositoryID: UUID
    let worktreeID: UUID?
    let runtimeRequirement: NodeRuntimeRequirement?
    let stdinText: String?
    let environment: [String: String]
    let usesTerminalSession: Bool
    let outputInterpreter: RunOutputInterpreterKind?
    let agentTool: AIAgentTool?
    let initialPrompt: String?

    init(
        title: String,
        actionKind: ActionKind,
        showsAgentIndicator: Bool = false,
        activatesTerminalTab: Bool = true,
        runConfigurationID: String? = nil,
        executable: String,
        arguments: [String],
        displayCommandLine: String? = nil,
        currentDirectoryURL: URL? = nil,
        repositoryID: UUID,
        worktreeID: UUID? = nil,
        runtimeRequirement: NodeRuntimeRequirement? = nil,
        stdinText: String? = nil,
        environment: [String: String] = [:],
        usesTerminalSession: Bool = true,
        outputInterpreter: RunOutputInterpreterKind? = nil,
        agentTool: AIAgentTool? = nil,
        initialPrompt: String? = nil
    ) {
        self.title = title
        self.actionKind = actionKind
        self.showsAgentIndicator = showsAgentIndicator
        self.activatesTerminalTab = activatesTerminalTab
        self.runConfigurationID = runConfigurationID
        self.executable = executable
        self.arguments = arguments
        self.displayCommandLine = displayCommandLine
        self.currentDirectoryURL = currentDirectoryURL
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
        self.runtimeRequirement = runtimeRequirement
        self.stdinText = stdinText
        self.environment = environment
        self.usesTerminalSession = usesTerminalSession
        self.outputInterpreter = outputInterpreter
        self.agentTool = agentTool
        self.initialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
}

enum RunOutputInterpreterKind: String, Codable, Sendable {
    case codexExecJSONL
    case claudePrintStreamJSON
    case copilotPromptJSONL
    case cursorAgentPrintJSON
}

struct CursorAgentPrintedResponse: Decodable, Equatable, Sendable {
    let result: String?
    let sessionID: String?
    let error: String?

    init(result: String?, sessionID: String?, error: String?) {
        self.result = result
        self.sessionID = sessionID
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case result
        case output
        case response
        case message
        case error
        case sessionID = "session_id"
        case sessionId
        case chatID = "chat_id"
        case chatId
        case id
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = container.decodeFirstString(forKeys: [.result, .output, .response, .message])
        sessionID = container.decodeFirstString(forKeys: [.sessionID, .sessionId, .chatID, .chatId, .id])
        error = container.decodeFirstString(forKeys: [.error])
    }

    static func parse(from text: String) -> CursorAgentPrintedResponse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return CursorAgentPrintedResponse(
            result: cursorPrintedResponseString(in: object, keys: ["result", "output", "response", "message"]),
            sessionID: cursorPrintedResponseString(in: object, keys: ["session_id", "sessionId", "chat_id", "chatId", "id"]),
            error: cursorPrintedResponseString(in: object, keys: ["error"])
        )
    }

    private static func cursorPrintedResponseString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               let text = value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return text
            }
        }
        return nil
    }
}

private extension KeyedDecodingContainer where K == CursorAgentPrintedResponse.CodingKeys {
    func decodeFirstString(forKeys keys: [K]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key), let text = value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                return text
            }
        }
        return nil
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
    /// Historically “plan tab”; means “primary context column” (Intent / Plan / Browser / README) is active instead of a run tab.
    private(set) var planTabSelectedWorktrees: Set<UUID> = []
    private(set) var primaryPaneByWorktree: [UUID: WorktreePrimaryPaneKind] = [:]

    mutating func selectPlanTab(for worktreeID: UUID) {
        planTabSelectedWorktrees.insert(worktreeID)
        if primaryPaneByWorktree[worktreeID] == nil {
            primaryPaneByWorktree[worktreeID] = .intent
        }
    }

    mutating func selectPrimaryPane(_ pane: WorktreePrimaryPaneKind, for worktreeID: UUID) {
        planTabSelectedWorktrees.insert(worktreeID)
        primaryPaneByWorktree[worktreeID] = pane
    }

    func primaryPane(for worktreeID: UUID) -> WorktreePrimaryPaneKind {
        primaryPaneByWorktree[worktreeID] ?? .intent
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

    mutating func showInBackground(runID: UUID, worktreeID: UUID, openedAt: Date = .now) {
        var tab = tabs[runID] ?? TerminalTabState(runID: runID, worktreeID: worktreeID)
        if tab.isVisible == false || tab.openedAt == nil {
            tab.openedAt = openedAt
        }
        tab.isVisible = true
        tab.closedAt = nil
        tabs[runID] = tab
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
        primaryPaneByWorktree.removeValue(forKey: worktreeID)
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

struct NodeRuntimeRequirement: Sendable, Equatable {
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
    var resolvedDefaultBinPath: String?
    var runtimeRootPath = ""
    var npmCachePath = ""
    var lastUpdatedAt: Date?
    var lastErrorMessage: String?
}

enum AppPreferences {
    static let selectedNamespaceIDKey = "navigation.selectedNamespaceID"
    static let selectedSettingsCategoryKey = "settings.selectedCategory"
    static let quickIntentHotkeyEnabledKey = "shortcuts.quickIntent.enabled"
    static let quickIntentHotkeyKeyCodeKey = "shortcuts.quickIntent.keyCode"
    static let quickIntentHotkeyModifiersKey = "shortcuts.quickIntent.modifiers"
    static let autoRefreshEnabledKey = "repositories.autoRefreshEnabled"
    static let autoRefreshIntervalKey = "repositories.autoRefreshIntervalSeconds"
    static let worktreeStatusPollingEnabledKey = "repositories.worktreeStatusPollingEnabled"
    static let worktreeStatusPollingIntervalKey = "repositories.worktreeStatusPollingIntervalSeconds"
    static let defaultAutoRefreshEnabled = true
    static let defaultAutoRefreshInterval: Double = 900
    static let defaultWorktreeStatusPollingEnabled = true
    static let defaultWorktreeStatusPollingInterval: Double = 120
    static let defaultQuickIntentHotkey = QuickIntentHotkeyConfiguration.default
    static let terminalTabRetentionModeKey = "terminal.tabs.retentionMode"
    static let performanceDebugModeEnabledKey = "debug.performance.enabled"
    static let nodeAutoUpdateEnabledKey = "node.autoUpdateEnabled"
    static let nodeAutoUpdateIntervalKey = "node.autoUpdateIntervalSeconds"
    static let nodeDefaultVersionSpecKey = "node.defaultVersionSpec"
    static let aiProviderKey = "ai.provider"
    static let aiAPIKeyKey = "ai.apiKey"
    static let aiBaseURLKey = "ai.baseURL"
    static let aiModelKey = "ai.model"
    static let jiraBaseURLKey = "jira.baseURL"
    static let jiraUserEmailKey = "jira.userEmail"
    static let mcpEnabledKey = "mcp.enabled"
    static let mcpListenAddressKey = "mcp.listenAddress"
    static let mcpPortKey = "mcp.port"
    static let mcpExposeReadOnlyToolsOnlyKey = "mcp.readOnlyOnly"
    static let devContainerEnabledKey = "devcontainer.enabled"
    static let devContainerCLIStrategyKey = "devcontainer.cliStrategy"
    static let devContainerMonitoringEnabledKey = "devcontainer.monitoringEnabled"
    static let devContainerMonitoringIntervalKey = "devcontainer.monitoringIntervalSeconds"
    static let devContainerGlobalVisibilityEnabledKey = "devcontainer.globalVisibilityEnabled"
    static let defaultNodeAutoUpdateEnabled = true
    static let defaultNodeAutoUpdateInterval: Double = 21_600
    static let defaultNodeVersionSpec = "lts/*"
    static let defaultTerminalTabRetentionMode = TerminalTabRetentionMode.shortRetain
    static let defaultPerformanceDebugModeEnabled = false
    static let defaultAIProvider = AIProviderKind.openAI
    static let defaultMCPEnabled = false
    static let defaultMCPListenAddress = "127.0.0.1"
    static let defaultMCPPort = 8765
    static let defaultMCPExposeReadOnlyToolsOnly = true
    static let defaultDevContainerEnabled = true
    static let defaultDevContainerCLIStrategy: DevContainerCLIStrategy = .auto
    static let defaultDevContainerMonitoringEnabled = true
    static let defaultDevContainerMonitoringInterval: Double = 30
    static let defaultDevContainerGlobalVisibilityEnabled = true

    static var autoRefreshEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: autoRefreshEnabledKey) == nil {
            return defaultAutoRefreshEnabled
        }
        return defaults.bool(forKey: autoRefreshEnabledKey)
    }

    static var quickIntentHotkeyConfiguration: QuickIntentHotkeyConfiguration {
        let defaults = UserDefaults.standard
        let isEnabled: Bool
        if defaults.object(forKey: quickIntentHotkeyEnabledKey) == nil {
            isEnabled = defaultQuickIntentHotkey.isEnabled
        } else {
            isEnabled = defaults.bool(forKey: quickIntentHotkeyEnabledKey)
        }

        let storedKeyCode = defaults.object(forKey: quickIntentHotkeyKeyCodeKey) as? NSNumber
        let keyCode = storedKeyCode.map(\.uint16Value) ?? defaultQuickIntentHotkey.keyCode

        let storedModifiers = defaults.object(forKey: quickIntentHotkeyModifiersKey) as? NSNumber
        let modifiers = QuickIntentModifierSet(rawValue: storedModifiers.map(\.intValue) ?? defaultQuickIntentHotkey.modifiers.rawValue)

        return QuickIntentHotkeyConfiguration(
            isEnabled: isEnabled,
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    static var autoRefreshInterval: TimeInterval {
        let defaults = UserDefaults.standard
        let value = defaults.double(forKey: autoRefreshIntervalKey)
        return value > 0 ? value : defaultAutoRefreshInterval
    }

    static var worktreeStatusPollingEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: worktreeStatusPollingEnabledKey) == nil {
            return defaultWorktreeStatusPollingEnabled
        }
        return defaults.bool(forKey: worktreeStatusPollingEnabledKey)
    }

    static var worktreeStatusPollingInterval: TimeInterval {
        let defaults = UserDefaults.standard
        let value = defaults.double(forKey: worktreeStatusPollingIntervalKey)
        return value > 0 ? value : defaultWorktreeStatusPollingInterval
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

    static var performanceDebugModeEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: performanceDebugModeEnabledKey) == nil {
            return defaultPerformanceDebugModeEnabled
        }
        return defaults.bool(forKey: performanceDebugModeEnabledKey)
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

    static var jiraBaseURL: String {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: jiraBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var jiraUserEmail: String {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: jiraUserEmailKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var jiraAPIToken: String? {
        try? KeychainSecretStore.loadString(
            service: KeychainSecretStore.jiraService,
            account: KeychainSecretStore.jiraTokenAccount
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty
    }

    static var jiraConfiguration: JiraConfiguration {
        JiraConfiguration(
            baseURL: jiraBaseURL,
            userEmail: jiraUserEmail,
            apiToken: jiraAPIToken
        )
    }

    static var mcpEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: mcpEnabledKey) == nil {
            return defaultMCPEnabled
        }
        return defaults.bool(forKey: mcpEnabledKey)
    }

    static var mcpListenAddress: String {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: mcpListenAddressKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? defaultMCPListenAddress
    }

    static var mcpPort: Int {
        let defaults = UserDefaults.standard
        let value = defaults.integer(forKey: mcpPortKey)
        return (1 ... 65_535).contains(value) ? value : defaultMCPPort
    }

    static var mcpAPIToken: String? {
        try? KeychainSecretStore.loadString(
            service: KeychainSecretStore.mcpService,
            account: KeychainSecretStore.mcpTokenAccount
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty
    }

    static var mcpExposeReadOnlyToolsOnly: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: mcpExposeReadOnlyToolsOnlyKey) == nil {
            return defaultMCPExposeReadOnlyToolsOnly
        }
        return defaults.bool(forKey: mcpExposeReadOnlyToolsOnlyKey)
    }

    static var mcpConfiguration: MCPServerConfiguration {
        MCPServerConfiguration(
            enabled: mcpEnabled,
            listenAddress: mcpListenAddress,
            port: mcpPort,
            apiToken: mcpAPIToken,
            exposeReadOnlyToolsOnly: mcpExposeReadOnlyToolsOnly
        )
    }

    static var devContainerEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: devContainerEnabledKey) == nil {
            return defaultDevContainerEnabled
        }
        return defaults.bool(forKey: devContainerEnabledKey)
    }

    static var devContainerCLIStrategy: DevContainerCLIStrategy {
        let defaults = UserDefaults.standard
        guard
            let value = defaults.string(forKey: devContainerCLIStrategyKey),
            let strategy = DevContainerCLIStrategy(rawValue: value)
        else {
            return defaultDevContainerCLIStrategy
        }
        return strategy
    }

    static var devContainerMonitoringEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: devContainerMonitoringEnabledKey) == nil {
            return defaultDevContainerMonitoringEnabled
        }
        return defaults.bool(forKey: devContainerMonitoringEnabledKey)
    }

    static var devContainerMonitoringInterval: TimeInterval {
        let defaults = UserDefaults.standard
        let value = defaults.double(forKey: devContainerMonitoringIntervalKey)
        return value > 0 ? value : defaultDevContainerMonitoringInterval
    }

    static var devContainerGlobalVisibilityEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: devContainerGlobalVisibilityEnabledKey) == nil {
            return defaultDevContainerGlobalVisibilityEnabled
        }
        return defaults.bool(forKey: devContainerGlobalVisibilityEnabledKey)
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
