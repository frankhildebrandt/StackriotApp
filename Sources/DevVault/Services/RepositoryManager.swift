import Foundation
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
            throw DevVaultError.commandFailed(cloneResult.stderr.isEmpty ? cloneResult.stdout : cloneResult.stderr)
        }

        if initialRemoteName != "origin" {
            let renameResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["--git-dir", destination.path, "remote", "rename", "origin", initialRemoteName]
            )
            guard renameResult.exitCode == 0 else {
                throw DevVaultError.commandFailed(renameResult.stderr.isEmpty ? renameResult.stdout : renameResult.stderr)
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
                mainDivergence: nil
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
                    arguments: ["--git-dir", bareRepositoryPath.path, "fetch", remote.name, "--prune"],
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
            mainDivergence: syncResult.divergence
        )
    }

    func addRemote(
        name: String,
        url: String,
        bareRepositoryPath: URL
    ) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
            throw DevVaultError.remoteNameRequired
        }

        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "remote", "add", trimmedName, trimmedURL]
        )
        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
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
            throw DevVaultError.remoteNameRequired
        }

        if previousName != trimmedName {
            let renameResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["--git-dir", bareRepositoryPath.path, "remote", "rename", previousName, trimmedName]
            )
            guard renameResult.exitCode == 0 else {
                throw DevVaultError.commandFailed(renameResult.stderr.isEmpty ? renameResult.stdout : renameResult.stderr)
            }
        }

        let urlResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "remote", "set-url", trimmedName, trimmedURL]
        )
        guard urlResult.exitCode == 0 else {
            throw DevVaultError.commandFailed(urlResult.stderr.isEmpty ? urlResult.stdout : urlResult.stderr)
        }
    }

    func removeRemote(name: String, bareRepositoryPath: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "remote", "remove", name]
        )
        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
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
                throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
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
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            throw DevVaultError.noBranchToPublish
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
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return branch
    }

    func hasUpstreamBranch(worktreePath: URL) async throws -> Bool {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath.path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
        )
        return result.exitCode == 0
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

    private func syncDefaultBranch(
        bareRepositoryPath: URL,
        defaultBranch: String,
        defaultRemoteName: String?
    ) async -> (errorMessage: String?, divergence: MainDivergenceRef?) {
        guard let defaultRemoteName, !defaultRemoteName.isEmpty else {
            return (errorMessage: nil, divergence: nil)
        }

        do {
            let remoteRef = "refs/remotes/\(defaultRemoteName)/\(defaultBranch)"
            let localBranchRef = "refs/heads/\(defaultBranch)"
            let remoteRefResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["--git-dir", bareRepositoryPath.path, "rev-parse", "--verify", remoteRef]
            )
            let targetCommit: String
            let targetRefForReset: String
            if remoteRefResult.exitCode == 0 {
                targetCommit = remoteRefResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                targetRefForReset = "\(defaultRemoteName)/\(defaultBranch)"
            } else {
                let localBranchResult = try await CommandRunner.runCollected(
                    executable: "git",
                    arguments: ["--git-dir", bareRepositoryPath.path, "rev-parse", "--verify", localBranchRef]
                )
                guard localBranchResult.exitCode == 0 else {
                    return (errorMessage: "Default-branch sync failed: \(remoteRefResult.stderr.isEmpty ? remoteRefResult.stdout : remoteRefResult.stderr)", divergence: nil)
                }
                targetCommit = localBranchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                targetRefForReset = targetCommit
            }

            let worktreeListResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["--git-dir", bareRepositoryPath.path, "worktree", "list", "--porcelain"]
            )
            guard worktreeListResult.exitCode == 0 else {
                return (errorMessage: "Default-branch sync failed: \(worktreeListResult.stderr.isEmpty ? worktreeListResult.stdout : worktreeListResult.stderr)", divergence: nil)
            }

            if let worktreePath = parseWorktreePath(for: defaultBranch, from: worktreeListResult.stdout) {
                // Check if local branch has commits ahead of the remote target before resetting.
                let aheadResult = try? await CommandRunner.runCollected(
                    executable: "git",
                    arguments: ["--git-dir", bareRepositoryPath.path, "rev-list", "--count", "\(targetCommit)..refs/heads/\(defaultBranch)"]
                )
                let aheadCount = aheadResult.flatMap { Int($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
                if aheadCount > 0 {
                    return (errorMessage: nil, divergence: MainDivergenceRef(worktreePath: worktreePath, aheadCount: aheadCount))
                }

                let resetResult = try await CommandRunner.runCollected(
                    executable: "git",
                    arguments: ["-C", worktreePath, "reset", "--hard", targetRefForReset]
                )
                guard resetResult.exitCode == 0 else {
                    return (errorMessage: "Default-branch sync failed: \(resetResult.stderr.isEmpty ? resetResult.stdout : resetResult.stderr)", divergence: nil)
                }
            } else {
                let updateResult = try await CommandRunner.runCollected(
                    executable: "git",
                    arguments: ["--git-dir", bareRepositoryPath.path, "update-ref", "refs/heads/\(defaultBranch)", targetCommit]
                )
                guard updateResult.exitCode == 0 else {
                    return (errorMessage: "Default-branch sync failed: \(updateResult.stderr.isEmpty ? updateResult.stdout : updateResult.stderr)", divergence: nil)
                }
            }

            return (errorMessage: nil, divergence: nil)
        } catch {
            return (errorMessage: "Default-branch sync failed: \(error.localizedDescription)", divergence: nil)
        }
    }

    private func parseWorktreePath(for branchName: String, from output: String) -> String? {
        // We must buffer attributes until the end of each block (empty line) because the
        // `bare` attribute appears AFTER `branch` in porcelain output. Returning immediately
        // on seeing `branch refs/heads/<name>` would incorrectly match the bare repo itself.
        var currentPath: String?
        var currentBranch: String?
        var currentIsBare = false

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if let value = line.stripPrefix("worktree ") {
                // Start of a new block — evaluate previous block first.
                if let path = currentPath, currentBranch == branchName, !currentIsBare {
                    return path
                }
                currentPath = value
                currentBranch = nil
                currentIsBare = false
            } else if let value = line.stripPrefix("branch refs/heads/") {
                currentBranch = value
            } else if line == "bare" {
                currentIsBare = true
            } else if line.isEmpty {
                if let path = currentPath, currentBranch == branchName, !currentIsBare {
                    return path
                }
                currentPath = nil
                currentBranch = nil
                currentIsBare = false
            }
        }
        // Handle the final block when there is no trailing newline.
        if let path = currentPath, currentBranch == branchName, !currentIsBare {
            return path
        }
        return nil
    }

    private func cleanupTemporaryKeyFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func forceResetDefaultBranch(
        worktreePath: String,
        remoteName: String,
        defaultBranch: String
    ) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath, "reset", "--hard", "\(remoteName)/\(defaultBranch)"]
        )
        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}
