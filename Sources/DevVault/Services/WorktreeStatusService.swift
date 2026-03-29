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

            let conflictResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["-C", worktreePath.path, "diff", "--name-only", "--diff-filter=U"]
            )
            if conflictResult.exitCode == 0 {
                status.hasConflicts = conflictResult.stdout.nonEmpty != nil
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

    func integrate(
        sourceBranch: String,
        defaultBranch: String,
        defaultWorktreePath: URL
    ) async throws -> WorktreeIntegrationResult {
        let cleanStatus = await fetchStatus(worktreePath: defaultWorktreePath, defaultBranch: defaultBranch)
        guard !cleanStatus.hasUncommittedChanges, !cleanStatus.hasConflicts else {
            throw DevVaultError.commandFailed("The default workspace has uncommitted changes or unresolved conflicts.")
        }

        let mergeResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: [
                "-C", defaultWorktreePath.path,
                "merge", "--no-ff", "--no-commit", sourceBranch
            ]
        )

        if mergeResult.exitCode != 0 {
            let conflictCheck = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["-C", defaultWorktreePath.path, "diff", "--name-only", "--diff-filter=U"]
            )
            if conflictCheck.exitCode == 0, conflictCheck.stdout.nonEmpty != nil {
                let message = mergeResult.stderr.isEmpty ? mergeResult.stdout : mergeResult.stderr
                return .conflicts(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw DevVaultError.commandFailed(mergeResult.stderr.isEmpty ? mergeResult.stdout : mergeResult.stderr)
        }

        let commitMessage = "Integrate \(sourceBranch) into \(defaultBranch)"
        let commitResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", defaultWorktreePath.path, "commit", "-m", commitMessage]
        )
        guard commitResult.exitCode == 0 else {
            throw DevVaultError.commandFailed(commitResult.stderr.isEmpty ? commitResult.stdout : commitResult.stderr)
        }

        return .committed
    }

    func loadUncommittedDiff(worktreePath: URL) async throws -> WorkspaceDiffSnapshot {
        let statusResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", worktreePath.path, "status", "--porcelain=v1", "--untracked-files=all"]
        )
        guard statusResult.exitCode == 0 else {
            throw DevVaultError.commandFailed(statusResult.stderr.isEmpty ? statusResult.stdout : statusResult.stderr)
        }

        let files = try await withThrowingTaskGroup(of: WorkspaceDiffFile?.self) { group in
            for entry in statusResult.stdout.split(whereSeparator: \.isNewline).map(String.init) {
                guard let parsed = parseDiffStatusLine(entry) else { continue }
                group.addTask {
                    let patch = try await patch(
                        for: parsed.path,
                        status: parsed.status,
                        in: worktreePath
                    )
                    return WorkspaceDiffFile(path: parsed.path, status: parsed.status, patch: patch)
                }
            }

            var files: [WorkspaceDiffFile] = []
            for try await file in group {
                if let file {
                    files.append(file)
                }
            }
            return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        }

        return WorkspaceDiffSnapshot(files: files)
    }

    private func parseDiffStatusLine(_ line: String) -> (path: String, status: WorkspaceDiffFileStatus)? {
        guard line.count >= 4 else { return nil }
        let x = line[line.startIndex]
        let y = line[line.index(after: line.startIndex)]
        let pathStart = line.index(line.startIndex, offsetBy: 3)
        let rawPath = String(line[pathStart...])
        let path = rawPath.components(separatedBy: " -> ").last ?? rawPath

        if x == "?" && y == "?" {
            return (path, .untracked)
        }
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
            return (path, .unmerged)
        }
        if x == "R" || y == "R" {
            return (path, .renamed)
        }
        if x == "C" || y == "C" {
            return (path, .copied)
        }
        if x == "A" || y == "A" {
            return (path, .added)
        }
        if x == "D" || y == "D" {
            return (path, .deleted)
        }
        if x == "M" || y == "M" {
            return (path, .modified)
        }
        return (path, .unknown)
    }

    private func patch(
        for relativePath: String,
        status: WorkspaceDiffFileStatus,
        in worktreePath: URL
    ) async throws -> String {
        switch status {
        case .untracked:
            let absolutePath = worktreePath.appendingPathComponent(relativePath)
            let result = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["-C", worktreePath.path, "diff", "--no-index", "--", "/dev/null", absolutePath.path]
            )
            return normalizedPatchOutput(result.stdout.nonEmpty ?? result.stderr, fallbackPath: relativePath, status: status)
        default:
            let result = try await CommandRunner.runCollected(
                executable: "git",
                arguments: ["-C", worktreePath.path, "diff", "--no-ext-diff", "--find-renames", "HEAD", "--", relativePath]
            )
            let output = result.stdout.nonEmpty ?? result.stderr
            return normalizedPatchOutput(output, fallbackPath: relativePath, status: status)
        }
    }

    private func normalizedPatchOutput(_ output: String, fallbackPath: String, status: WorkspaceDiffFileStatus) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return "\(status.displayName): \(fallbackPath)"
    }
}
