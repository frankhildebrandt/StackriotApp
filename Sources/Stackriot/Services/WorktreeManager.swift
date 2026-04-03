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
    typealias CommandExecutor = @Sendable (_ executable: String, _ arguments: [String], _ currentDirectoryURL: URL?, _ environment: [String: String]) async throws -> CommandResult

    private let runCommand: CommandExecutor

    init(runCommand: @escaping CommandExecutor = WorktreeManager.liveCommand) {
        self.runCommand = runCommand
    }

    static func normalizedWorktreeName(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalizedSeparators = trimmed.replacingOccurrences(of: "\\", with: "/")
        let segments = normalizedSeparators
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { normalizedWorktreeSegment(from: String($0)) }
            .filter { !$0.isEmpty }
        return segments.joined(separator: "/")
    }

    static func normalizedPullRequestBranchName(number: Int, title: String) -> String {
        let slug = normalizedWorktreeName(from: title).replacingOccurrences(of: "/", with: "-")
        let suffix = slug.nilIfBlank ?? "pull-request"
        return "pr/\(number)-\(suffix)"
    }

    func createWorktree(
        bareRepositoryPath: URL,
        repositoryName: String,
        branchName: String,
        sourceBranch: String,
        directoryName: String? = nil,
        destinationRoot: URL? = nil
    ) async throws -> CreatedWorktreeInfo {
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else {
            throw StackriotError.branchNameRequired
        }

        let worktreeRoot = try resolvedWorktreeRoot(
            repositoryName: repositoryName,
            destinationRoot: destinationRoot
        )
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)

        let destination: URL
        if let directoryName, directoryName.nilIfBlank != nil {
            destination = try uniquePreservingDirectory(in: worktreeRoot, preferredName: directoryName)
        } else {
            destination = AppPaths.uniqueDirectory(in: worktreeRoot, preferredName: trimmedBranch)
        }
        let branchExists = try await branchExistsInRepository(trimmedBranch, bareRepositoryPath: bareRepositoryPath)

        let arguments: [String]
        if branchExists {
            arguments = ["--git-dir", bareRepositoryPath.path, "worktree", "add", destination.path, trimmedBranch]
        } else {
            arguments = ["--git-dir", bareRepositoryPath.path, "worktree", "add", "-b", trimmedBranch, destination.path, sourceBranch]
        }

        let result = try await runCommand("git", arguments, nil, [:])
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return CreatedWorktreeInfo(branchName: trimmedBranch, path: destination)
    }

    func checkoutPullRequest(
        bareRepositoryPath: URL,
        repositoryName: String,
        prNumber: Int,
        title: String,
        destinationRoot: URL? = nil
    ) async throws -> CreatedWorktreeInfo {
        let branchName = Self.normalizedPullRequestBranchName(number: prNumber, title: title)
        if let existingPath = try await existingWorktreePath(
            bareRepositoryPath: bareRepositoryPath,
            branchName: branchName
        ) {
            return CreatedWorktreeInfo(branchName: branchName, path: existingPath)
        }

        let fetchResult = try await runCommand(
            "git",
            [
                "--git-dir", bareRepositoryPath.path,
                "fetch", "--force", "origin",
                "pull/\(prNumber)/head:refs/heads/\(branchName)",
            ],
            nil,
            [:]
        )
        guard fetchResult.exitCode == 0 else {
            throw StackriotError.commandFailed(fetchResult.stderr.isEmpty ? fetchResult.stdout : fetchResult.stderr)
        }

        let worktreeRoot = try resolvedWorktreeRoot(repositoryName: repositoryName, destinationRoot: destinationRoot)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let destination = try uniquePreservingDirectory(in: worktreeRoot, preferredName: branchName)
        let addResult = try await runCommand(
            "git",
            ["--git-dir", bareRepositoryPath.path, "worktree", "add", destination.path, branchName],
            nil,
            [:]
        )
        guard addResult.exitCode == 0 else {
            throw StackriotError.commandFailed(addResult.stderr.isEmpty ? addResult.stdout : addResult.stderr)
        }

        return CreatedWorktreeInfo(branchName: branchName, path: destination)
    }

    func updateCheckedOutPullRequest(
        bareRepositoryPath: URL,
        worktreePath: URL,
        localBranchName: String,
        prNumber: Int
    ) async throws {
        let cleanStatusResult = try await runCommand(
            "git",
            ["-C", worktreePath.path, "status", "--porcelain"],
            nil,
            [:]
        )
        guard cleanStatusResult.exitCode == 0 else {
            throw StackriotError.commandFailed(cleanStatusResult.stderr.isEmpty ? cleanStatusResult.stdout : cleanStatusResult.stderr)
        }
        guard cleanStatusResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StackriotError.commandFailed("The PR worktree has local changes. Commit, stash, or discard them before updating from upstream.")
        }

        let upstreamRef = "refs/stackriot/pull/\(prNumber)"
        let fetchResult = try await runCommand(
            "git",
            [
                "--git-dir", bareRepositoryPath.path,
                "fetch", "--force", "origin",
                "pull/\(prNumber)/head:\(upstreamRef)",
            ],
            nil,
            [:]
        )
        guard fetchResult.exitCode == 0 else {
            throw StackriotError.commandFailed(fetchResult.stderr.isEmpty ? fetchResult.stdout : fetchResult.stderr)
        }

        let checkoutResult = try await runCommand(
            "git",
            ["-C", worktreePath.path, "checkout", localBranchName],
            nil,
            [:]
        )
        guard checkoutResult.exitCode == 0 else {
            throw StackriotError.commandFailed(checkoutResult.stderr.isEmpty ? checkoutResult.stdout : checkoutResult.stderr)
        }

        let mergeResult = try await runCommand(
            "git",
            ["-C", worktreePath.path, "merge", "--ff-only", upstreamRef],
            nil,
            [:]
        )
        guard mergeResult.exitCode == 0 else {
            throw StackriotError.commandFailed(mergeResult.stderr.isEmpty ? mergeResult.stdout : mergeResult.stderr)
        }
    }

    func currentRevision(worktreePath: URL) async throws -> String {
        let result = try await runCommand(
            "git",
            ["-C", worktreePath.path, "rev-parse", "HEAD"],
            nil,
            [:]
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func moveWorktree(
        bareRepositoryPath: URL,
        worktreePath: URL,
        newParentDirectory: URL,
        directoryName: String
    ) async throws -> URL {
        let trimmedDirectoryName = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectoryName.isEmpty else {
            throw StackriotError.branchNameRequired
        }

        try FileManager.default.createDirectory(at: newParentDirectory, withIntermediateDirectories: true)
        let destination = try uniquePreservingDirectory(in: newParentDirectory, preferredName: trimmedDirectoryName)
        let result = try await runCommand(
            "git",
            ["--git-dir", bareRepositoryPath.path, "worktree", "move", worktreePath.path, destination.path],
            nil,
            [:]
        )

        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return destination
    }

    func resetToSourceBranch(worktreePath: URL, sourceBranch: String) async throws {
        let resetResult = try await runCommand(
            "git",
            ["-C", worktreePath.path, "reset", "--hard", sourceBranch],
            nil,
            [:]
        )
        guard resetResult.exitCode == 0 else {
            throw StackriotError.commandFailed(resetResult.stderr.isEmpty ? resetResult.stdout : resetResult.stderr)
        }

        let cleanResult = try await runCommand(
            "git",
            ["-C", worktreePath.path, "clean", "-fd"],
            nil,
            [:]
        )
        guard cleanResult.exitCode == 0 else {
            throw StackriotError.commandFailed(cleanResult.stderr.isEmpty ? cleanResult.stdout : cleanResult.stderr)
        }
    }

    func removeWorktree(bareRepositoryPath: URL, worktreePath: URL) async throws {
        let result = try await runCommand(
            "git",
            ["--git-dir", bareRepositoryPath.path, "worktree", "remove", "--force", worktreePath.path],
            nil,
            [:]
        )

        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
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
        let result = try await runCommand(
            "git",
            ["--git-dir", bareRepositoryPath.path, "worktree", "add", destination.path, defaultBranch],
            nil,
            [:]
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return CreatedWorktreeInfo(branchName: defaultBranch, path: destination)
    }

    func existingWorktreePath(
        bareRepositoryPath: URL,
        branchName: String
    ) async throws -> URL? {
        let result = try await runCommand(
            "git",
            ["--git-dir", bareRepositoryPath.path, "worktree", "list", "--porcelain"],
            nil,
            [:]
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
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

    private static func liveCommand(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]
    ) async throws -> CommandResult {
        try await CommandRunner.runCollected(
            executable: executable,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment
        )
    }

    private func branchExistsInRepository(_ branchName: String, bareRepositoryPath: URL) async throws -> Bool {
        let result = try await runCommand(
            "git",
            ["--git-dir", bareRepositoryPath.path, "show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"],
            nil,
            [:]
        )
        return result.exitCode == 0
    }

    private func resolvedWorktreeRoot(repositoryName: String, destinationRoot: URL?) throws -> URL {
        if let destinationRoot {
            return destinationRoot
        }

        try AppPaths.ensureBaseDirectories()
        return AppPaths.worktreesRoot.appendingPathComponent(
            AppPaths.sanitizedPathComponent(repositoryName),
            isDirectory: true
        )
    }

    private static func normalizedWorktreeSegment(from value: String) -> String {
        let transliterated = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "", with: "ss")
            .folding(options: [.diacriticInsensitive], locale: .current)
        let whitespaceCollapsed = transliterated.replacingOccurrences(
            of: #"\s+"#,
            with: "-",
            options: .regularExpression
        )
        let cleaned = whitespaceCollapsed.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        return cleaned
            .replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    private func uniquePreservingDirectory(in root: URL, preferredName: String) throws -> URL {
        let fileManager = FileManager.default
        let components = sanitizedDirectoryComponents(from: preferredName)
        let parentDirectory = components.dropLast().reduce(root) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: true)
        }
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let baseName = components.last ?? "worktree"
        var candidate = parentDirectory.appendingPathComponent(baseName, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parentDirectory.appendingPathComponent("\(baseName)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    private func sanitizedDirectoryComponents(from value: String) -> [String] {
        let components = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { Self.normalizedWorktreeSegment(from: String($0)) }
            .filter { !$0.isEmpty }
        return components.isEmpty ? ["worktree"] : components
    }
}
