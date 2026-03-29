import Foundation
struct WorktreeManager {
    func createWorktree(
        bareRepositoryPath: URL,
        repositoryName: String,
        branchName: String,
        sourceBranch: String
    ) async throws -> CreatedWorktreeInfo {
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else {
            throw DevVaultError.branchNameRequired
        }

        try AppPaths.ensureBaseDirectories()
        let worktreeRoot = AppPaths.worktreesRoot.appendingPathComponent(
            AppPaths.sanitizedPathComponent(repositoryName),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)

        let destination = AppPaths.uniqueDirectory(in: worktreeRoot, preferredName: trimmedBranch)
        let branchExists = try await branchExistsInRepository(trimmedBranch, bareRepositoryPath: bareRepositoryPath)

        let arguments: [String]
        if branchExists {
            arguments = ["--git-dir", bareRepositoryPath.path, "worktree", "add", destination.path, trimmedBranch]
        } else {
            arguments = ["--git-dir", bareRepositoryPath.path, "worktree", "add", "-b", trimmedBranch, destination.path, sourceBranch]
        }

        let result = try await CommandRunner.runCollected(executable: "git", arguments: arguments)
        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return CreatedWorktreeInfo(branchName: trimmedBranch, path: destination)
    }

    func removeWorktree(bareRepositoryPath: URL, worktreePath: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "worktree", "remove", "--force", worktreePath.path]
        )

        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func branchExistsInRepository(_ branchName: String, bareRepositoryPath: URL) async throws -> Bool {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"]
        )
        return result.exitCode == 0
    }
}
