import Foundation
struct WorktreeStatusService {
    func fetchStatus(worktreePath: URL, defaultBranch: String) async -> WorktreeStatus {
        var status = WorktreeStatus()

        do {
            let revListResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["-C", worktreePath.path, "rev-list", "--left-right", "--count", "\(defaultBranch)...HEAD"]
            )

            if revListResult.exitCode == 0 {
                let values = revListResult.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0 == "\t" || $0 == " " })
                if values.count >= 2 {
                    status.behindCount = Int(values[0]) ?? 0
                    status.aheadCount = Int(values[1]) ?? 0
                }
            }

            let diffResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["-C", worktreePath.path, "diff", "--numstat", "HEAD"]
            )

            if diffResult.exitCode == 0 {
                let lines = diffResult.stdout
                    .split(whereSeparator: \Character.isNewline)
                    .map(String.init)
                for line in lines {
                    let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                    guard columns.count >= 2 else { continue }
                    status.addedLines += Int(columns[0]) ?? 0
                    status.deletedLines += Int(columns[1]) ?? 0
                }

                status.hasUncommittedChanges = !lines.isEmpty
            }
        } catch {
            return WorktreeStatus()
        }

        return status
    }

    func rebase(worktreePath: URL, onto: String) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath.path, "rebase", onto]
        )

        guard result.exitCode == 0 else {
            _ = try? await CommandRunner.runCollected(
                executable: "git",
                arguments: ["-C", worktreePath.path, "rebase", "--abort"]
            )
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func merge(worktreePath: URL, from branch: String) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath.path, "merge", branch]
        )

        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}
