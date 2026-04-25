import Foundation

struct AsyncUIActionKey: Hashable, Sendable {
    enum Scope: String, Sendable {
        case global
        case repository
        case worktree
        case run
        case tool
        case remote
    }

    let scope: Scope
    let id: String
    let operation: String

    static func global(_ operation: String) -> AsyncUIActionKey {
        AsyncUIActionKey(scope: .global, id: "global", operation: operation)
    }

    static func repository(_ repositoryID: UUID, _ operation: String) -> AsyncUIActionKey {
        AsyncUIActionKey(scope: .repository, id: repositoryID.uuidString, operation: operation)
    }

    static func worktree(_ worktreeID: UUID, _ operation: String) -> AsyncUIActionKey {
        AsyncUIActionKey(scope: .worktree, id: worktreeID.uuidString, operation: operation)
    }

    static func run(_ runID: UUID, _ operation: String) -> AsyncUIActionKey {
        AsyncUIActionKey(scope: .run, id: runID.uuidString, operation: operation)
    }

    static func tool(_ toolID: String, _ operation: String) -> AsyncUIActionKey {
        AsyncUIActionKey(scope: .tool, id: toolID, operation: operation)
    }

    static func remote(_ remoteID: UUID, _ operation: String) -> AsyncUIActionKey {
        AsyncUIActionKey(scope: .remote, id: remoteID.uuidString, operation: operation)
    }
}

extension AsyncUIActionKey {
    enum Operation {
        static let refreshRepository = "refreshRepository"
        static let refreshWorktreeStatus = "refreshWorktreeStatus"
        static let rebase = "rebase"
        static let gitPull = "gitPull"
        static let gitPush = "gitPush"
        static let gitCommit = "gitCommit"
        static let publishBranch = "publishBranch"
        static let integrate = "integrate"
        static let loadDiff = "loadDiff"
        static let loadChangelogDiff = "loadChangelogDiff"
        static let loadHistory = "loadHistory"
        static let launchAgent = "launchAgent"
        static let openDevTool = "openDevTool"
        static let openTerminal = "openTerminal"
        static let launchRunConfiguration = "launchRunConfiguration"
        static let installDependencies = "installDependencies"
        static let devContainer = "devContainer"
        static let nodeRuntime = "nodeRuntime"
        static let localToolStatus = "localToolStatus"
        static let installLocalTool = "installLocalTool"
        static let mcpServer = "mcpServer"
        static let remoteManagement = "remoteManagement"
        static let sshKey = "sshKey"
        static let commandBar = "commandBar"
        static let aiProvider = "aiProvider"
    }
}

extension AppModel {
    func isUIActionRunning(_ key: AsyncUIActionKey) -> Bool {
        activeUIActionKeys.contains(key)
    }

    func activeUIActionTitle(for key: AsyncUIActionKey) -> String? {
        activeUIActionTitlesByKey[key]
    }

    @discardableResult
    func beginUIAction(_ key: AsyncUIActionKey, title: String? = nil) -> Bool {
        guard !activeUIActionKeys.contains(key) else { return false }
        activeUIActionKeys.insert(key)
        if let title {
            activeUIActionTitlesByKey[key] = title
        }
        return true
    }

    func endUIAction(_ key: AsyncUIActionKey) {
        activeUIActionKeys.remove(key)
        activeUIActionTitlesByKey.removeValue(forKey: key)
    }

    func runUIAction(
        key: AsyncUIActionKey,
        title: String? = nil,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard beginUIAction(key, title: title) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.endUIAction(key) }
            do {
                try await operation()
            } catch {
                self.pendingErrorMessage = error.localizedDescription
            }
        }
    }

    func performUIAction(
        key: AsyncUIActionKey,
        title: String? = nil,
        operation: @MainActor () async throws -> Void
    ) async {
        guard beginUIAction(key, title: title) else { return }
        defer { endUIAction(key) }
        do {
            try await operation()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }
}
