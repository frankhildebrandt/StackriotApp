import Foundation

/// Parsed entry from `git worktree list --porcelain`.
struct GitWorktreeListEntry: Sendable {
    let path: String
    let isBare: Bool
    /// Value after the `branch ` line (e.g. `refs/heads/main`, `detached`).
    let rawBranchField: String?
    /// Short branch name (e.g. `main`) when on `refs/heads/...`; nil when bare or detached.
    let branchShortName: String?
}

enum GitWorktreeListParser {
    static func entries(fromPorcelain output: String) -> [GitWorktreeListEntry] {
        var results: [GitWorktreeListEntry] = []
        var currentPath: String?
        var currentBranchRef: String?
        var currentIsBare = false

        func closeBlock() {
            guard let path = currentPath else {
                currentPath = nil
                currentBranchRef = nil
                currentIsBare = false
                return
            }
            let rawBranch = currentBranchRef
            let shortName: String?
            if currentIsBare {
                shortName = nil
            } else if let ref = currentBranchRef {
                if ref == "detached" {
                    shortName = nil
                } else if ref.hasPrefix("refs/heads/") {
                    shortName = String(ref.dropFirst("refs/heads/".count))
                } else {
                    shortName = ref
                }
            } else {
                shortName = nil
            }
            results.append(
                GitWorktreeListEntry(path: path, isBare: currentIsBare, rawBranchField: rawBranch, branchShortName: shortName)
            )
            currentPath = nil
            currentBranchRef = nil
            currentIsBare = false
        }

        let normalizedLines = output.split(separator: "\n").map { line in
            String(line).replacingOccurrences(of: "\r", with: "")
        }
        for line in normalizedLines {
            if let value = line.stripPrefix("worktree ") {
                closeBlock()
                currentPath = value
                currentBranchRef = nil
                currentIsBare = false
            } else if let value = line.stripPrefix("branch ") {
                currentBranchRef = value
            } else if line == "bare" {
                currentIsBare = true
            } else if line.isEmpty {
                closeBlock()
            }
        }
        closeBlock()
        return results
    }

    /// Parses `git worktree list` (non-porcelain) lines for entries checked out on `defaultBranch`.
    static func pathsFromHumanReadableWorktreeList(_ output: String, defaultBranch: String) -> [String] {
        var paths: [String] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine).replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: CharacterSet.whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasSuffix("(bare)") {
                continue
            }
            guard let openBracket = line.lastIndex(of: "["),
                  let closeIdx = line[line.index(after: openBracket)...].firstIndex(of: "]")
            else { continue }
            let branchName = String(line[line.index(after: openBracket)..<closeIdx])
            guard branchName == defaultBranch else { continue }
            let before = line[..<openBracket].trimmingCharacters(in: CharacterSet.whitespaces)
            let tokens = before.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 2, let last = tokens.last else { continue }
            guard last.count >= 7, last.allSatisfy({ $0.isHexDigit }) else { continue }
            let path = tokens.dropLast().joined(separator: " ")
            guard !path.isEmpty else { continue }
            paths.append(path)
        }
        return paths
    }
}

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

        for entry in GitWorktreeListParser.entries(fromPorcelain: result.stdout) {
            if !entry.isBare,
               entry.branchShortName == branchName || entry.rawBranchField == "refs/heads/\(branchName)"
            {
                return URL(fileURLWithPath: entry.path)
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
