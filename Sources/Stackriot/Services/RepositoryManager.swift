import Foundation

struct PublishBranchResult: Sendable, Equatable {
    let branch: String
    let didPush: Bool
}

struct RepositoryGitAdminPaths: Sendable, Equatable {
    let config: URL
    let worktrees: URL?
}

struct RepositoryManager {
    private let sshEnvironmentBuilder = GitSSHEnvironmentBuilder()

    static func canonicalRemoteURL(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://"), let components = URLComponents(string: trimmed) {
            let scheme = components.scheme?.lowercased() ?? ""
            let host = components.host?.lowercased() ?? ""
            let user = components.user ?? ""
            let port = components.port.map { ":\($0)" } ?? ""
            let normalizedPath = normalizedGitPath(components.path)
            return "\(scheme)://\(user.isEmpty ? "" : "\(user)@")\(host)\(port)\(normalizedPath)"
        }

        if let range = trimmed.range(of: ":"), trimmed[..<range.lowerBound].contains("@") {
            let prefix = String(trimmed[..<range.lowerBound])
            let path = String(trimmed[range.upperBound...])
            let pieces = prefix.split(separator: "@", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return nil }
            return "\(pieces[0])@\(pieces[1].lowercased()):\(normalizedGitPath(path))"
        }

        let path = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        return normalizedGitPath(path)
    }

    private static func normalizedGitPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let withoutGitSuffix = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        return "/" + withoutGitSuffix
    }

    func cloneBareRepository(
        remoteURL: URL,
        preferredName: String?,
        initialRemoteName: String = "origin"
    ) async throws -> ClonedRepositoryInfo {
        try AppPaths.ensureBaseDirectories()

        let displayName = (preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { name in
            name.isEmpty ? nil : name
        } ?? AppPaths.suggestedRepositoryName(from: remoteURL)

        let destination = AppPaths.uniqueDirectory(in: AppPaths.bareRepositoriesRoot, preferredName: displayName)
        let cloneResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["clone", "--bare", remoteURL.absoluteString, destination.path]
        )

        guard cloneResult.exitCode == 0 else {
            throw StackriotError.commandFailed(cloneResult.stderr.isEmpty ? cloneResult.stdout : cloneResult.stderr)
        }

        if initialRemoteName != "origin" {
            let renameResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["--git-dir", destination.path, "remote", "rename", "origin", initialRemoteName]
            )
            guard renameResult.exitCode == 0 else {
                throw StackriotError.commandFailed(renameResult.stderr.isEmpty ? renameResult.stdout : renameResult.stderr)
            }
        }

        let branchResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", destination.path, "symbolic-ref", "--short", "HEAD"]
        )

        let defaultBranch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranch = defaultBranch.isEmpty ? "main" : defaultBranch

        return ClonedRepositoryInfo(
            displayName: displayName,
            remoteURL: remoteURL,
            bareRepositoryPath: destination,
            defaultBranch: resolvedBranch,
            initialRemoteName: initialRemoteName
        )
    }

    func refreshStatus(for repositoryPath: URL) -> RepositoryHealth {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: repositoryPath.path) else {
            return .missing
        }

        let head = repositoryPath.appendingPathComponent("HEAD")
        return fileManager.fileExists(atPath: head.path) ? .ready : .broken
    }

    func refreshRepository(
        bareRepositoryPath: URL,
        remotes: [RemoteExecutionContext],
        defaultRemoteName: String?
    ) async -> RepositoryRefreshInfo {
        let baseStatus = refreshStatus(for: bareRepositoryPath)
        guard baseStatus == .ready else {
            return RepositoryRefreshInfo(
                status: baseStatus,
                defaultBranch: "main",
                fetchedAt: nil,
                fetchErrorMessage: "Repository missing or invalid.",
                defaultBranchSyncErrorMessage: nil,
                defaultBranchSyncSummary: nil
            )
        }

        var fetchErrors: [String] = []
        var didFetch = false

        for remote in remotes where remote.fetchEnabled {
            do {
                try await configureRemoteIfNeeded(remote, in: bareRepositoryPath)
                let environment = try sshEnvironmentBuilder.environment(privateKeyRef: remote.privateKeyRef)
                defer { cleanupTemporaryKeyFile(at: environment.cleanupURL) }

                let result = try await CommandRunner.runCollected(
                    executable: "git",
                    arguments: [
                        "--git-dir", bareRepositoryPath.path,
                        "fetch", remote.name, "--prune",
                        "+refs/heads/*:refs/remotes/\(remote.name)/*",
                    ],
                    environment: environment.environment
                )
                if result.exitCode == 0 {
                    didFetch = true
                } else {
                    fetchErrors.append(result.stderr.isEmpty ? result.stdout : result.stderr)
                }
            } catch {
                fetchErrors.append(error.localizedDescription)
            }
        }

        let branchResult = try? await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "symbolic-ref", "--short", "HEAD"]
        )
        let defaultBranch = branchResult?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "main"
        let fetchErrorMessage = fetchErrors.isEmpty ? nil : fetchErrors.joined(separator: "\n\n")
        let syncResult = await syncDefaultBranch(
            bareRepositoryPath: bareRepositoryPath,
            defaultBranch: defaultBranch,
            defaultRemoteName: defaultRemoteName
        )
        let status: RepositoryHealth = [fetchErrorMessage, syncResult.errorMessage].allSatisfy { $0 == nil } ? .ready : .broken

        return RepositoryRefreshInfo(
            status: status,
            defaultBranch: defaultBranch,
            fetchedAt: didFetch ? .now : nil,
            fetchErrorMessage: fetchErrorMessage,
            defaultBranchSyncErrorMessage: syncResult.errorMessage,
            defaultBranchSyncSummary: syncResult.summary
        )
    }

    func repositoryGitAdminPaths(for bareRepositoryPath: URL) async throws -> RepositoryGitAdminPaths {
        let configPath = try await gitPath(named: "config", in: bareRepositoryPath)
        let worktreesPath = try await optionalGitPath(named: "worktrees", in: bareRepositoryPath)
        return RepositoryGitAdminPaths(config: configPath, worktrees: worktreesPath)
    }

    func listWorktreeEntries(in bareRepositoryPath: URL) async throws -> [GitWorktreeListEntry] {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "worktree", "list", "--porcelain"]
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return GitWorktreeListParser.entries(fromPorcelain: result.stdout)
    }

    func addRemote(
        name: String,
        url: String,
        bareRepositoryPath: URL
    ) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
            throw StackriotError.remoteNameRequired
        }

        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "remote", "add", trimmedName, trimmedURL]
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func updateRemote(
        previousName: String,
        newName: String,
        url: String,
        bareRepositoryPath: URL
    ) async throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
            throw StackriotError.remoteNameRequired
        }

        if previousName != trimmedName {
            let renameResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["--git-dir", bareRepositoryPath.path, "remote", "rename", previousName, trimmedName]
            )
            guard renameResult.exitCode == 0 else {
                throw StackriotError.commandFailed(renameResult.stderr.isEmpty ? renameResult.stdout : renameResult.stderr)
            }
        }

        let urlResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "remote", "set-url", trimmedName, trimmedURL]
        )
        guard urlResult.exitCode == 0 else {
            throw StackriotError.commandFailed(urlResult.stderr.isEmpty ? urlResult.stdout : urlResult.stderr)
        }
    }

    func removeRemote(name: String, bareRepositoryPath: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "remote", "remove", name]
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func deleteRepository(
        bareRepositoryPath: URL,
        worktreePaths: [URL]
    ) async throws {
        for path in worktreePaths {
            let result = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["--git-dir", bareRepositoryPath.path, "worktree", "remove", "--force", path.path]
            )
            guard result.exitCode == 0 else {
                throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
        }

        try FileManager.default.removeItem(at: bareRepositoryPath)
    }

    func currentBranch(in worktreePath: URL) async throws -> String {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath.path, "branch", "--show-current"]
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            throw StackriotError.noBranchToPublish
        }
        return branch
    }

    func publishCurrentBranch(
        worktreePath: URL,
        remote: RemoteExecutionContext
    ) async throws -> String {
        let branch = try await currentBranch(in: worktreePath)
        let environment = try sshEnvironmentBuilder.environment(privateKeyRef: remote.privateKeyRef)
        defer { cleanupTemporaryKeyFile(at: environment.cleanupURL) }

        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath.path, "push", "--set-upstream", remote.name, branch],
            environment: environment.environment
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return branch
    }

    func publishCurrentBranchIfNeeded(
        worktreePath: URL,
        remote: RemoteExecutionContext
    ) async throws -> PublishBranchResult {
        let branch = try await currentBranch(in: worktreePath)
        if try await hasUpstreamBranch(worktreePath: worktreePath) {
            return PublishBranchResult(branch: branch, didPush: false)
        }
        if try await remoteBranchMatchesHEAD(
            worktreePath: worktreePath,
            remoteName: remote.name,
            branch: branch
        ) {
            return PublishBranchResult(branch: branch, didPush: false)
        }

        let publishedBranch = try await publishCurrentBranch(
            worktreePath: worktreePath,
            remote: remote
        )
        return PublishBranchResult(branch: publishedBranch, didPush: true)
    }

    func hasUpstreamBranch(worktreePath: URL) async throws -> Bool {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath.path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
        )
        return result.exitCode == 0
    }

    private func remoteBranchMatchesHEAD(
        worktreePath: URL,
        remoteName: String,
        branch: String
    ) async throws -> Bool {
        let headResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath.path, "rev-parse", "HEAD"]
        )
        guard headResult.exitCode == 0 else {
            throw StackriotError.commandFailed(headResult.stderr.isEmpty ? headResult.stdout : headResult.stderr)
        }

        let remoteResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath.path, "ls-remote", "--heads", remoteName, branch]
        )
        guard remoteResult.exitCode == 0 else {
            throw StackriotError.commandFailed(remoteResult.stderr.isEmpty ? remoteResult.stdout : remoteResult.stderr)
        }

        let headSHA = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSHA = remoteResult.stdout
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return remoteSHA == headSHA && remoteSHA?.isEmpty == false
    }

    private func configureRemoteIfNeeded(_ remote: RemoteExecutionContext, in bareRepositoryPath: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "remote", "get-url", remote.name]
        )
        if result.exitCode != 0 {
            try await addRemote(name: remote.name, url: remote.url, bareRepositoryPath: bareRepositoryPath)
            return
        }

        let currentURL = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentURL != remote.url {
            try await updateRemote(previousName: remote.name, newName: remote.name, url: remote.url, bareRepositoryPath: bareRepositoryPath)
        }
    }

    private func worktreePathsOnDefaultBranch(
        porcelainOutput: String,
        bareRepositoryPath: URL,
        defaultBranch: String
    ) async -> [String] {
        let fromPorcelain = GitWorktreeListParser.entries(fromPorcelain: porcelainOutput)
            .filter { entry in
                !entry.isBare
                    && (entry.branchShortName == defaultBranch || entry.rawBranchField == "refs/heads/\(defaultBranch)")
            }
            .map(\.path)
        if !fromPorcelain.isEmpty {
            return fromPorcelain
        }
        let humanList = try? await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "worktree", "list"]
        )
        guard let humanList, humanList.exitCode == 0 else { return [] }
        return GitWorktreeListParser.pathsFromHumanReadableWorktreeList(humanList.stdout, defaultBranch: defaultBranch)
    }

    private func gitPath(named name: String, in bareRepositoryPath: URL) async throws -> URL {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "rev-parse", "--git-path", name]
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        let rawPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath).standardizedFileURL
        }

        return URL(fileURLWithPath: rawPath, relativeTo: bareRepositoryPath).standardizedFileURL
    }

    private func optionalGitPath(named name: String, in bareRepositoryPath: URL) async throws -> URL? {
        let path = try await gitPath(named: name, in: bareRepositoryPath)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    private func syncDefaultBranch(
        bareRepositoryPath: URL,
        defaultBranch: String,
        defaultRemoteName: String?
    ) async -> (errorMessage: String?, summary: String?) {
        guard let defaultRemoteName, !defaultRemoteName.isEmpty else {
            return (errorMessage: nil, summary: nil)
        }

        do {
            let remoteRef = "refs/remotes/\(defaultRemoteName)/\(defaultBranch)"
            let remoteRefResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["--git-dir", bareRepositoryPath.path, "rev-parse", "--verify", remoteRef]
            )
            guard remoteRefResult.exitCode == 0 else {
                return (errorMessage: "Default-branch sync failed: \(remoteRefResult.stderr.isEmpty ? remoteRefResult.stdout : remoteRefResult.stderr)", summary: nil)
            }

            let targetCommit = remoteRefResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let syncTargetRef = remoteRef
            let remoteTrackingBranch = "\(defaultRemoteName)/\(defaultBranch)"
            let worktreeListResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["--git-dir", bareRepositoryPath.path, "worktree", "list", "--porcelain"]
            )
            guard worktreeListResult.exitCode == 0 else {
                return (errorMessage: "Default-branch sync failed: \(worktreeListResult.stderr.isEmpty ? worktreeListResult.stdout : worktreeListResult.stderr)", summary: nil)
            }

            let defaultWorktreePaths = await worktreePathsOnDefaultBranch(
                porcelainOutput: worktreeListResult.stdout,
                bareRepositoryPath: bareRepositoryPath,
                defaultBranch: defaultBranch
            )
            if !defaultWorktreePaths.isEmpty {
                var summaries: [String] = []
                for worktreePath in defaultWorktreePaths {
                    _ = try await runGit(
                        ["-C", worktreePath, "reset", "--hard"],
                        errorPrefix: "Default-branch sync failed"
                    )
                    _ = try await runGit(
                        ["-C", worktreePath, "clean", "-fd"],
                        errorPrefix: "Default-branch sync failed"
                    )
                    _ = try await runGit(
                        ["-C", worktreePath, "checkout", defaultBranch],
                        errorPrefix: "Default-branch sync failed"
                    )

                    let ffOnlyResult = try await CommandRunner.runCollected(
                        executable: "git",
                        arguments: ["-C", worktreePath, "merge", "--ff-only", syncTargetRef]
                    )
                    if ffOnlyResult.exitCode == 0 {
                        if let submoduleError = await updateSubmodulesToGitlinks(worktreePath: worktreePath) {
                            return (errorMessage: submoduleError, summary: nil)
                        }
                        let ffSummary = ffOnlyResult.stdout
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .contains("Already up to date")
                            ? "\(defaultBranch) bereits auf Stand von \(remoteTrackingBranch)"
                            : "\(defaultBranch) fast-forward auf \(remoteTrackingBranch)"
                        summaries.append(ffSummary)
                        continue
                    }

                    let mergeResult = try await CommandRunner.runCollected(
                        executable: "git",
                        arguments: ["-C", worktreePath, "merge", syncTargetRef]
                    )
                    if mergeResult.exitCode == 0 {
                        if let submoduleError = await updateSubmodulesToGitlinks(worktreePath: worktreePath) {
                            return (errorMessage: submoduleError, summary: nil)
                        }
                        let mergeSummary = mergeResult.stdout
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .contains("Already up to date")
                            ? "\(defaultBranch) bereits auf Stand von \(remoteTrackingBranch)"
                            : "\(defaultBranch) mit \(remoteTrackingBranch) gemergt"
                        summaries.append(mergeSummary)
                        continue
                    }

                    _ = try? await CommandRunner.runCollected(
                        executable: "git",
                        arguments: ["-C", worktreePath, "merge", "--abort"]
                    )

                    let rebaseResult = try await CommandRunner.runCollected(
                        executable: "git",
                        arguments: ["-C", worktreePath, "rebase", syncTargetRef]
                    )
                    if rebaseResult.exitCode == 0 {
                        if let submoduleError = await updateSubmodulesToGitlinks(worktreePath: worktreePath) {
                            return (errorMessage: submoduleError, summary: nil)
                        }
                        summaries.append("\(defaultBranch) per Rebase auf \(remoteTrackingBranch) synchronisiert")
                        continue
                    }

                    _ = try? await CommandRunner.runCollected(
                        executable: "git",
                        arguments: ["-C", worktreePath, "rebase", "--abort"]
                    )
                    let mergeDetail = mergeResult.stderr.isEmpty ? mergeResult.stdout : mergeResult.stderr
                    let rebaseDetail = rebaseResult.stderr.isEmpty ? rebaseResult.stdout : rebaseResult.stderr
                    return (
                        errorMessage: "Default-branch sync failed: merge against \(remoteTrackingBranch) failed: \(mergeDetail)\n\nRebase fallback failed: \(rebaseDetail)",
                        summary: nil
                    )
                }
                return (errorMessage: nil, summary: summaries.joined(separator: "\n"))
            }

            let updateResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["--git-dir", bareRepositoryPath.path, "update-ref", "refs/heads/\(defaultBranch)", targetCommit]
            )
            guard updateResult.exitCode == 0 else {
                return (errorMessage: "Default-branch sync failed: \(updateResult.stderr.isEmpty ? updateResult.stdout : updateResult.stderr)", summary: nil)
            }

            return (errorMessage: nil, summary: "Kein Default-Worktree vorhanden, Bare-Ref auf \(remoteTrackingBranch) gesetzt")
        } catch {
            return (errorMessage: "Default-branch sync failed: \(error.localizedDescription)", summary: nil)
        }
    }

    /// Align submodule checkouts with the current commit even when `reset --hard` was a no-op for the superproject.
    private func updateSubmodulesToGitlinks(worktreePath: String) async -> String? {
        let updateResult = try? await CommandRunner.runCollected(
            executable: "git",
            arguments: [
                "-c", "protocol.file.allow=always",
                "-C", worktreePath,
                "submodule", "update", "--init", "--recursive", "--force",
            ]
        )
        guard let updateResult else {
            return "Submodule-Update fehlgeschlagen."
        }
        guard updateResult.exitCode == 0 else {
            let detail = updateResult.stderr.isEmpty ? updateResult.stdout : updateResult.stderr
            return "Submodule-Update fehlgeschlagen: \(detail)"
        }
        return await checkoutSubmodulesToRecordedGitlinks(worktreePath: worktreePath)
    }

    /// `submodule update` can leave the wrong commit checked out in some worktree setups; force each path to `HEAD:<path>`.
    private func checkoutSubmodulesToRecordedGitlinks(worktreePath: String) async -> String? {
        let configResult = try? await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath, "config", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.path$"]
        )
        guard let configResult, configResult.exitCode == 0 else {
            return nil
        }
        let lines = configResult.stdout.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let worktreeURL = URL(fileURLWithPath: worktreePath)
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2 else { continue }
            let relativePath = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relativePath.isEmpty else { continue }

            let shaResult = try? await CommandRunner.runCollected(
                executable: "git",
                arguments: ["-C", worktreePath, "rev-parse", "HEAD:\(relativePath)"]
            )
            guard let shaResult, shaResult.exitCode == 0 else { continue }
            let sha = shaResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sha.count == 40, sha.allSatisfy({ $0.isHexDigit }) else { continue }

            let submoduleURL = worktreeURL.appendingPathComponent(relativePath, isDirectory: true)
            let checkoutResult = try? await CommandRunner.runCollected(
                executable: "git",
                arguments: [
                    "-c", "protocol.file.allow=always",
                    "-C", submoduleURL.path,
                    "checkout", "-q", "-f", sha,
                ]
            )
            guard let checkoutResult, checkoutResult.exitCode == 0 else {
                let detail = checkoutResult.map { $0.stderr.isEmpty ? $0.stdout : $0.stderr } ?? ""
                return "Submodule-Checkout fehlgeschlagen (\(relativePath)): \(detail)"
            }
        }
        return nil
    }

    private func cleanupTemporaryKeyFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func runGit(
        _ arguments: [String],
        errorPrefix: String
    ) async throws -> CommandResult {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: arguments
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed("\(errorPrefix): \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
        return result
    }
}
