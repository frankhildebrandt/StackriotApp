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

    func ensureDefaultBranchWorkspace(
        bareRepositoryPath: URL,
        repositoryName: String,
        defaultBranch: String
    ) async throws -> CreatedWorktreeInfo {
        if let existingPath = try await existingWorktreePath(
            bareRepositoryPath: bareRepositoryPath,
            branchName: defaultBranch
        ) {
            return CreatedWorktreeInfo(branchName: defaultBranch, path: existingPath)
        }

        try AppPaths.ensureBaseDirectories()
        let worktreeRoot = AppPaths.worktreesRoot.appendingPathComponent(
            AppPaths.sanitizedPathComponent(repositoryName),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)

        let destination = worktreeRoot.appendingPathComponent("default-branch", isDirectory: true)
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "worktree", "add", destination.path, defaultBranch]
        )
        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return CreatedWorktreeInfo(branchName: defaultBranch, path: destination)
    }

    func existingWorktreePath(
        bareRepositoryPath: URL,
        branchName: String
    ) async throws -> URL? {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "worktree", "list", "--porcelain"]
        )
        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        var currentPath: String?
        var currentBranch: String?
        for line in result.stdout.split(whereSeparator: \.isNewline).map(String.init) + [""] {
            if line.isEmpty {
                if currentBranch == "refs/heads/\(branchName)", let currentPath {
                    return URL(fileURLWithPath: currentPath)
                }
                currentPath = nil
                currentBranch = nil
                continue
            }

            if let value = line.stripPrefix("worktree ") {
                currentPath = value
            } else if let value = line.stripPrefix("branch ") {
                currentBranch = value
            }
        }

        return nil
    }

    private func branchExistsInRepository(_ branchName: String, bareRepositoryPath: URL) async throws -> Bool {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"]
        )
        return result.exitCode == 0
    }
}
