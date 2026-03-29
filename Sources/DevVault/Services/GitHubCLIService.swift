import Foundation

/// Service für GitHub CLI (`gh`) Operationen — PR erstellen und Status abrufen.
enum GitHubCLIService {

    struct PRInfo: Sendable {
        let number: Int
        let url: String
    }

    enum PRStatus: String, Sendable, Equatable {
        case open
        case merged
        case closed
    }

    // MARK: - Availability

    /// `true` wenn `gh` CLI im PATH vorhanden ist.
    static func isGHAvailable() async -> Bool {
        do {
            let result = try await CommandRunner.runCollected(
                executable: "which",
                arguments: ["gh"]
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    /// `true` wenn `gh auth status` erfolgreich ist (User ist eingeloggt).
    static func isAuthenticated() async -> Bool {
        do {
            let result = try await CommandRunner.runCollected(
                executable: "gh",
                arguments: ["auth", "status"]
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    // MARK: - Remote Check

    /// Gibt zurück, ob die Remote-URL zu GitHub gehört.
    static func isGitHubRemote(url: String) -> Bool {
        url.localizedCaseInsensitiveContains("github.com")
    }

    // MARK: - PR Operations

    /// Erstellt einen GitHub Pull Request vom aktuellen Branch des Worktrees.
    static func createPR(
        worktreePath: URL,
        title: String,
        body: String,
        baseBranch: String
    ) async throws -> PRInfo {
        let result = try await CommandRunner.runCollected(
            executable: "gh",
            arguments: [
                "pr", "create",
                "--title", title,
                "--body", body.isEmpty ? " " : body,
                "--base", baseBranch,
                "--json", "number,url"
            ],
            currentDirectoryURL: worktreePath
        )

        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DevVaultError.commandFailed(message.isEmpty ? result.stdout : message)
        }

        struct PRResponse: Decodable {
            let number: Int
            let url: String
        }

        let data = Data(result.stdout.utf8)
        let decoded = try JSONDecoder().decode(PRResponse.self, from: data)
        return PRInfo(number: decoded.number, url: decoded.url)
    }

    /// Gibt den aktuellen Status eines Pull Requests zurück.
    static func getPRStatus(worktreePath: URL, prNumber: Int) async throws -> PRStatus {
        let result = try await CommandRunner.runCollected(
            executable: "gh",
            arguments: ["pr", "view", "\(prNumber)", "--json", "state"],
            currentDirectoryURL: worktreePath
        )

        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DevVaultError.commandFailed(message.isEmpty ? result.stdout : message)
        }

        struct PRStateResponse: Decodable {
            let state: String
        }

        let data = Data(result.stdout.utf8)
        let decoded = try JSONDecoder().decode(PRStateResponse.self, from: data)

        switch decoded.state.uppercased() {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: return .open
        }
    }
}
