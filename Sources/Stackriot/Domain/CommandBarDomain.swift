import Foundation

enum CommandBarTriggerSource: String, Codable, Sendable {
    case globalHotkey
    case menu
    case inAppShortcut
}

enum CommandBarContextSource: String, Codable, Sendable {
    case frontmostCursor
    case stackriotSelection
    case none

    var displayName: String {
        switch self {
        case .frontmostCursor:
            "Cursor"
        case .stackriotSelection:
            "Stackriot"
        case .none:
            "Kein Kontext"
        }
    }
}

struct CommandBarWorkspaceContext: Identifiable, Equatable, Sendable {
    let id = UUID()
    let source: CommandBarContextSource
    let namespaceName: String?
    let repositoryID: UUID?
    let repositoryName: String?
    let worktreeID: UUID?
    let worktreeName: String?
    let worktreePath: String?
    let frontmostApplicationName: String?
    let frontmostWindowTitle: String?
    let matchedPath: String?

    var contextLabel: String {
        if let repositoryName, let worktreeName {
            return "\(repositoryName) / \(worktreeName)"
        }
        if let repositoryName {
            return repositoryName
        }
        return "Kein Workspace ausgewaehlt"
    }
}

struct CommandBarSession: Identifiable, Equatable, Sendable {
    let id = UUID()
    let triggerSource: CommandBarTriggerSource
    var context: CommandBarWorkspaceContext
    var query: String = ""
    var selectedCommandID: String?
}

enum CommandBarCommandCategory: String, Codable, CaseIterable, Sendable {
    case run
    case navigation
    case repository
    case utility

    var displayName: String {
        switch self {
        case .run:
            "Runs"
        case .navigation:
            "Navigation"
        case .repository:
            "Repository"
        case .utility:
            "Utility"
        }
    }
}

enum CommandBarCommandAction: Equatable, Sendable {
    case rerunSelectedRun(repositoryID: UUID, worktreeID: UUID, runID: UUID)
    case startRunConfiguration(repositoryID: UUID, worktreeID: UUID, configurationID: String)
    case openQuickIntent
    case refreshRepository(repositoryID: UUID)
    case selectRepository(repositoryID: UUID)
    case selectWorktree(repositoryID: UUID, worktreeID: UUID)
    case presentNewWorktree(repositoryID: UUID)
    case openDevTool(repositoryID: UUID, worktreeID: UUID, tool: SupportedDevTool)
    case openExternalTerminal(repositoryID: UUID, worktreeID: UUID, terminal: SupportedExternalTerminal)
    case syncRepository(repositoryID: UUID)
    case pushDefaultBranch(repositoryID: UUID, worktreeID: UUID)
}

struct CommandBarCommand: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let category: CommandBarCommandCategory
    let systemImage: String
    let keywords: [String]
    let action: CommandBarCommandAction
    var isEnabled: Bool = true
    var disabledReason: String?
    var isFavorite: Bool = false
    var lastUsedAt: Date?

    var searchableText: String {
        ([title, subtitle, category.displayName] + keywords).joined(separator: " ")
    }
}

struct CommandBarRankedCommand: Identifiable, Equatable, Sendable {
    let command: CommandBarCommand
    let score: Int

    var id: String { command.id }
}

struct CommandBarCommandUsage: Codable, Equatable, Sendable {
    let commandID: String
    let usedAt: Date
}

enum CommandBarRanking {
    static func rankedCommands(
        _ commands: [CommandBarCommand],
        query: String,
        now: Date = .now
    ) -> [CommandBarRankedCommand] {
        let normalizedQuery = normalize(query)
        return commands.compactMap { command in
            let score = score(command: command, query: normalizedQuery, now: now)
            guard score > 0 else { return nil }
            return CommandBarRankedCommand(command: command, score: score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.command.isFavorite != rhs.command.isFavorite { return lhs.command.isFavorite }
            return lhs.command.title.localizedCaseInsensitiveCompare(rhs.command.title) == .orderedAscending
        }
    }

    static func score(command: CommandBarCommand, query: String, now: Date = .now) -> Int {
        var score = command.isEnabled ? 100 : 20
        if command.isFavorite { score += 150 }
        if let lastUsedAt = command.lastUsedAt {
            let age = max(0, now.timeIntervalSince(lastUsedAt))
            score += max(0, 120 - Int(age / 3_600))
        }

        guard !query.isEmpty else { return score }

        let searchable = normalize(command.searchableText)
        if searchable == query {
            score += 1_000
        } else if searchable.hasPrefix(query) {
            score += 700
        } else if searchable.contains(query) {
            score += 450
        } else if fuzzyMatches(query, in: searchable) {
            score += 250
        } else {
            return 0
        }

        if normalize(command.title).contains(query) {
            score += 200
        }
        return score
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fuzzyMatches(_ query: String, in value: String) -> Bool {
        var remaining = query[...]
        for character in value {
            if remaining.first == character {
                remaining = remaining.dropFirst()
                if remaining.isEmpty { return true }
            }
        }
        return remaining.isEmpty
    }
}
