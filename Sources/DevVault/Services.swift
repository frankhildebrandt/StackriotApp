import Foundation
import Security

enum DevVaultError: LocalizedError {
    case invalidRemoteURL
    case duplicateRepository(String)
    case unsupportedRepositoryPath
    case executableNotFound(String)
    case branchNameRequired
    case worktreeUnavailable
    case remoteNameRequired
    case noBranchToPublish
    case commandFailed(String)
    case keyMaterialInvalid

    var errorDescription: String? {
        switch self {
        case .invalidRemoteURL:
            "The repository URL is invalid."
        case let .duplicateRepository(url):
            "A repository for \(url) already exists."
        case .unsupportedRepositoryPath:
            "The repository path is missing or invalid."
        case let .executableNotFound(name):
            "\(name) is not installed or cannot be launched."
        case .branchNameRequired:
            "A branch name is required."
        case .worktreeUnavailable:
            "A worktree is required for this action."
        case .remoteNameRequired:
            "A remote name and URL are required."
        case .noBranchToPublish:
            "The selected worktree has no active branch to publish."
        case .keyMaterialInvalid:
            "The SSH key could not be read or generated."
        case let .commandFailed(message):
            message
        }
    }
}

enum AppPaths {
    static var applicationSupportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return url.appendingPathComponent("DevVault", isDirectory: true)
    }

    static var nodeRuntimeRoot: URL {
        applicationSupportDirectory.appendingPathComponent("NodeRuntime", isDirectory: true)
    }

    static var nvmDirectory: URL {
        nodeRuntimeRoot.appendingPathComponent("nvm", isDirectory: true)
    }

    static var nodeVersionsRoot: URL {
        nvmDirectory.appendingPathComponent("versions/node", isDirectory: true)
    }

    static var runtimeCacheRoot: URL {
        nodeRuntimeRoot.appendingPathComponent("Caches", isDirectory: true)
    }

    static var npmCacheDirectory: URL {
        runtimeCacheRoot.appendingPathComponent("npm", isDirectory: true)
    }

    static var corepackCacheDirectory: URL {
        runtimeCacheRoot.appendingPathComponent("corepack", isDirectory: true)
    }

    static var runtimeTemporaryDirectory: URL {
        nodeRuntimeRoot.appendingPathComponent("tmp", isDirectory: true)
    }

    static var nodeRuntimeStateFile: URL {
        nodeRuntimeRoot.appendingPathComponent("runtime-state.json", isDirectory: false)
    }

    static var bareRepositoriesRoot: URL {
        applicationSupportDirectory.appendingPathComponent("Repositories", isDirectory: true)
    }

    static var worktreesRoot: URL {
        applicationSupportDirectory.appendingPathComponent("Worktrees", isDirectory: true)
    }

    static func ensureBaseDirectories() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nodeRuntimeRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeCacheRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: npmCacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: corepackCacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeTemporaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bareRepositoriesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
    }

    static func suggestedRepositoryName(from remoteURL: URL) -> String {
        let lastComponent = remoteURL.deletingPathExtension().lastPathComponent
        return lastComponent.isEmpty ? "repository" : lastComponent
    }

    static func sanitizedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let string = String(scalars)
        let normalized = string.replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "item" : normalized.lowercased()
    }

    static func uniqueDirectory(in root: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let base = sanitizedPathComponent(preferredName)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }
}

struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

final class RunningProcess: @unchecked Sendable {
    fileprivate let process: Process
    fileprivate var wasCancelled = false

    init(process: Process) {
        self.process = process
    }

    func cancel() {
        wasCancelled = true
        if process.isRunning {
            process.terminate()
        }
    }
}

enum CommandRunner {
    @discardableResult
    static func start(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        onOutput: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32, Bool) -> Void
    ) throws -> RunningProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let runningProcess = RunningProcess(process: process)
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let string = String(data: data, encoding: .utf8) else {
                return
            }

            onOutput(string)
        }

        process.terminationHandler = { proc in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let remainder = outputPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainder.isEmpty, let string = String(data: remainder, encoding: .utf8) {
                onOutput(string)
            }

            onTermination(proc.terminationStatus, runningProcess.wasCancelled)
        }

        try process.run()
        return runningProcess
    }

    static func runCollected(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:]
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum KeychainSSHKeyStore {
    static let service = "DevVault.SSHKeys"

    static func store(privateKeyData: Data, reference: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecValueData as String: privateKeyData,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: reference,
            ]
            let attributes: [String: Any] = [kSecValueData as String: privateKeyData]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw DevVaultError.keyMaterialInvalid
            }
            return
        }

        guard status == errSecSuccess else {
            throw DevVaultError.keyMaterialInvalid
        }
    }

    static func load(reference: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw DevVaultError.keyMaterialInvalid
        }
        return data
    }

    static func delete(reference: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct GitSSHEnvironmentBuilder {
    func environment(privateKeyRef: String?) throws -> (environment: [String: String], cleanupURL: URL?) {
        guard let privateKeyRef else {
            return ([:], nil)
        }

        let keyData = try KeychainSSHKeyStore.load(reference: privateKeyRef)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevVault-\(UUID().uuidString)", isDirectory: false)
        try keyData.write(to: tempURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        let command = "/usr/bin/ssh -i '\(tempURL.path.replacingOccurrences(of: "'", with: "'\\''"))' -o IdentitiesOnly=yes -F /dev/null"
        return (["GIT_SSH_COMMAND": command], tempURL)
    }
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
        remotes: [RemoteExecutionContext]
    ) async -> RepositoryRefreshInfo {
        let baseStatus = refreshStatus(for: bareRepositoryPath)
        guard baseStatus == .ready else {
            return RepositoryRefreshInfo(status: baseStatus, defaultBranch: "main", fetchedAt: nil, errorMessage: "Repository missing or invalid.")
        }

        var errors: [String] = []
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
                    errors.append(result.stderr.isEmpty ? result.stdout : result.stderr)
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        let branchResult = try? await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "symbolic-ref", "--short", "HEAD"]
        )
        let defaultBranch = branchResult?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "main"
        let errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n\n")
        let status: RepositoryHealth = errorMessage == nil ? .ready : .broken

        return RepositoryRefreshInfo(
            status: status,
            defaultBranch: defaultBranch,
            fetchedAt: didFetch ? .now : nil,
            errorMessage: errorMessage
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

    private func cleanupTemporaryKeyFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
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

    private func branchExistsInRepository(_ branchName: String, bareRepositoryPath: URL) async throws -> Bool {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", bareRepositoryPath.path, "show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"]
        )
        return result.exitCode == 0
    }
}

struct IDEManager {
    func open(_ ide: SupportedIDE, path: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "open",
            arguments: ["-a", ide.applicationName, path.path]
        )

        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func revealInFinder(path: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "open",
            arguments: ["-R", path.path]
        )

        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}

struct SSHKeyManager {
    func importKey(from sourceURL: URL, displayName: String?) async throws -> SSHKeyMaterial {
        let privateKeyData = try Data(contentsOf: sourceURL)
        guard !privateKeyData.isEmpty else {
            throw DevVaultError.keyMaterialInvalid
        }

        let publicKeyURL = sourceURL.appendingPathExtension("pub")
        let publicKey: String
        if FileManager.default.fileExists(atPath: publicKeyURL.path) {
            publicKey = (try String(contentsOf: publicKeyURL)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let result = try await CommandRunner.runCollected(
                executable: "ssh-keygen",
                arguments: ["-y", "-f", sourceURL.path]
            )
            guard result.exitCode == 0 else {
                throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            publicKey = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? sourceURL.lastPathComponent
        return SSHKeyMaterial(displayName: name, kind: .imported, publicKey: publicKey, privateKeyData: privateKeyData)
    }

    func generateKey(displayName: String, comment: String?) async throws -> SSHKeyMaterial {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw DevVaultError.keyMaterialInvalid
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevVaultGeneratedKeys", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let keyURL = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: keyURL)
            try? FileManager.default.removeItem(at: keyURL.appendingPathExtension("pub"))
        }

        let result = try await CommandRunner.runCollected(
            executable: "ssh-keygen",
            arguments: [
                "-t", "ed25519",
                "-N", "",
                "-C", comment?.nonEmpty ?? trimmedName,
                "-f", keyURL.path,
            ]
        )
        guard result.exitCode == 0 else {
            throw DevVaultError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        let privateKeyData = try Data(contentsOf: keyURL)
        let publicKey = try String(contentsOf: keyURL.appendingPathExtension("pub"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SSHKeyMaterial(displayName: trimmedName, kind: .generated, publicKey: publicKey, privateKeyData: privateKeyData)
    }
}

struct NodeToolingService {
    func runtimeRequirement(
        for worktreeURL: URL,
        defaultVersionSpec: String = AppPreferences.nodeDefaultVersionSpec
    ) -> NodeRuntimeRequirement {
        if let package = readPackageManifest(in: worktreeURL),
           let spec = package.engines?.node?.trimmingCharacters(in: .whitespacesAndNewlines),
           !spec.isEmpty {
            return NodeRuntimeRequirement(
                packageManager: packageManager(in: worktreeURL),
                nodeVersionSpec: spec,
                versionSource: .packageEngines
            )
        }

        let nvmrcURL = worktreeURL.appendingPathComponent(".nvmrc")
        if let value = readVersionSpec(from: nvmrcURL) {
            return NodeRuntimeRequirement(
                packageManager: packageManager(in: worktreeURL),
                nodeVersionSpec: value,
                versionSource: .nvmrc
            )
        }

        let nodeVersionURL = worktreeURL.appendingPathComponent(".node-version")
        if let value = readVersionSpec(from: nodeVersionURL) {
            return NodeRuntimeRequirement(
                packageManager: packageManager(in: worktreeURL),
                nodeVersionSpec: value,
                versionSource: .nodeVersionFile
            )
        }

        return NodeRuntimeRequirement(
            packageManager: packageManager(in: worktreeURL),
            nodeVersionSpec: defaultVersionSpec,
            versionSource: .defaultLTS
        )
    }

    func packageManager(in worktreeURL: URL) -> PackageManagerKind {
        if FileManager.default.fileExists(atPath: worktreeURL.appendingPathComponent("pnpm-lock.yaml").path) {
            return .pnpm
        }
        if FileManager.default.fileExists(atPath: worktreeURL.appendingPathComponent("yarn.lock").path) {
            return .yarn
        }
        return .npm
    }

    func discoverScripts(in worktreeURL: URL) -> [String] {
        readPackageManifest(in: worktreeURL)?.scripts.keys.sorted() ?? []
    }

    func installDescriptor(
        for worktree: WorktreeRecord,
        mode: DependencyInstallMode,
        repositoryID: UUID
    ) -> CommandExecutionDescriptor {
        let worktreeURL = URL(fileURLWithPath: worktree.path)
        let packageManager = packageManager(in: worktreeURL)
        let executable: String
        let arguments: [String]

        if packageManager == .pnpm {
            executable = "pnpm"
            arguments = [mode == .install ? "install" : "update"]
        } else if packageManager == .yarn {
            executable = "yarn"
            arguments = [mode == .install ? "install" : "upgrade"]
        } else {
            executable = "npm"
            arguments = [mode == .install ? "install" : "update"]
        }

        return CommandExecutionDescriptor(
            title: "\(mode.displayName) dependencies",
            actionKind: .installDependencies,
            executable: executable,
            arguments: arguments,
            currentDirectoryURL: worktreeURL,
            repositoryID: repositoryID,
            worktreeID: worktree.id,
            runtimeRequirement: runtimeRequirement(for: worktreeURL)
        )
    }

    private func readPackageManifest(in worktreeURL: URL) -> PackageManifest? {
        let packageURL = worktreeURL.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL) else {
            return nil
        }
        return try? JSONDecoder().decode(PackageManifest.self, from: data)
    }

    private func readVersionSpec(from fileURL: URL) -> String? {
        guard let value = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let cleaned = value
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }
}

struct MakeToolingService {
    func discoverTargets(in worktreeURL: URL) -> [String] {
        for fileName in ["GNUmakefile", "Makefile", "makefile"] {
            let makefileURL = worktreeURL.appendingPathComponent(fileName)
            if let contents = try? String(contentsOf: makefileURL) {
                return Self.parseTargets(from: contents)
            }
        }
        return []
    }

    static func parseTargets(from contents: String) -> [String] {
        let lines = contents.components(separatedBy: .newlines)
        let targets = lines.compactMap { line -> String? in
            guard
                !line.hasPrefix("\t"),
                !line.hasPrefix("#"),
                !line.contains("="),
                let colonIndex = line.firstIndex(of: ":")
            else {
                return nil
            }

            let target = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !target.contains("%"), !target.contains(" "), !target.hasPrefix(".") else {
                return nil
            }
            return target
        }
        return Array(Set(targets)).sorted()
    }
}

private struct PackageManifest: Decodable {
    let scripts: [String: String]
    let engines: PackageEngines?

    private enum CodingKeys: String, CodingKey {
        case scripts
        case engines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scripts = try container.decodeIfPresent([String: String].self, forKey: .scripts) ?? [:]
        engines = try container.decodeIfPresent(PackageEngines.self, forKey: .engines)
    }
}

private struct PackageEngines: Decodable {
    let node: String?
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
