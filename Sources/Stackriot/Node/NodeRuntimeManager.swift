import Foundation

actor NodeRuntimeManager {
    private static let nvmRepositoryURL = "https://github.com/nvm-sh/nvm.git"

    private var cachedStatus: NodeRuntimeStatusSnapshot
    private let versionResolver = NodeVersionSpecResolver()

    init() {
        let runtimeRoot = AppPaths.nodeRuntimeRoot.path
        let npmCache = AppPaths.npmCacheDirectory.path
        cachedStatus = NodeRuntimeStatusSnapshot(
            runtimeRootPath: runtimeRoot,
            npmCachePath: npmCache
        )

        if let data = try? Data(contentsOf: AppPaths.nodeRuntimeStateFile),
           let stored = try? JSONDecoder().decode(NodeRuntimeStatusSnapshot.self, from: data) {
            cachedStatus = stored
        }
    }

    func statusSnapshot() -> NodeRuntimeStatusSnapshot {
        cachedStatus
    }

    func prepareExecution(for descriptor: CommandExecutionDescriptor) async throws -> PreparedCommandExecution {
        guard let requirement = descriptor.runtimeRequirement else {
            return PreparedCommandExecution(
                executable: descriptor.executable,
                arguments: descriptor.arguments,
                environment: descriptor.environment
            )
        }

        let runtime = try await ensureRuntime(for: requirement)
        switch requirement.packageManager {
        case .npm:
            return PreparedCommandExecution(
                executable: runtime.npmBinaryPath,
                arguments: descriptor.arguments,
                environment: runtime.environment.merging(descriptor.environment) { _, new in new }
            )
        case .pnpm, .yarn:
            try await enableCorepack(in: runtime)
            return PreparedCommandExecution(
                executable: runtime.corepackBinaryPath,
                arguments: [requirement.packageManager.rawValue] + descriptor.arguments,
                environment: runtime.environment.merging(descriptor.environment) { _, new in new }
            )
        }
    }

    func refreshDefaultRuntimeIfNeeded(force: Bool = false) async {
        if !force, !AppPreferences.nodeAutoUpdateEnabled {
            return
        }

        if !force,
           let lastUpdatedAt = cachedStatus.lastUpdatedAt,
           Date.now.timeIntervalSince(lastUpdatedAt) < AppPreferences.nodeAutoUpdateInterval {
            return
        }

        do {
            try await bootstrapNVMIfNeeded(allowUpdate: true)
            _ = try await ensureRuntime(
                for: NodeRuntimeRequirement(
                    packageManager: .npm,
                    nodeVersionSpec: AppPreferences.nodeDefaultVersionSpec,
                    versionSource: .defaultLTS
                )
            )
            cachedStatus.bootstrapState = "Ready"
            cachedStatus.lastUpdatedAt = .now
            cachedStatus.lastErrorMessage = nil
            persistStatus()
        } catch {
            cachedStatus.bootstrapState = "Error"
            cachedStatus.lastUpdatedAt = .now
            cachedStatus.lastErrorMessage = error.localizedDescription
            persistStatus()
        }
    }

    func rebuildManagedRuntime() async {
        do {
            if FileManager.default.fileExists(atPath: AppPaths.nodeRuntimeRoot.path) {
                try FileManager.default.removeItem(at: AppPaths.nodeRuntimeRoot)
            }
            try AppPaths.ensureBaseDirectories()
            cachedStatus.bootstrapState = "Rebuilding"
            cachedStatus.lastErrorMessage = nil
            persistStatus()
            await refreshDefaultRuntimeIfNeeded(force: true)
        } catch {
            cachedStatus.bootstrapState = "Error"
            cachedStatus.lastErrorMessage = error.localizedDescription
            cachedStatus.lastUpdatedAt = .now
            persistStatus()
        }
    }

    private func ensureRuntime(for requirement: NodeRuntimeRequirement) async throws -> ResolvedNodeRuntime {
        try AppPaths.ensureBaseDirectories()
        try await bootstrapNVMIfNeeded(allowUpdate: false)
        let installableSpec = try await resolveInstallableSpec(for: requirement.nodeVersionSpec)

        let installResult = try await runNVMCommand("""
        nvm install \(shellQuote(installableSpec)) --latest-npm --no-progress >/dev/null
        nvm which \(shellQuote(installableSpec))
        """)
        guard installResult.exitCode == 0 else {
            throw StackriotError.commandFailed(installResult.stderr.isEmpty ? installResult.stdout : installResult.stderr)
        }

        let nodePath = installResult.stdout
            .components(separatedBy: .newlines)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard nodePath.hasPrefix("/") else {
            throw StackriotError.commandFailed("Unable to resolve the managed Node runtime for \(requirement.nodeVersionSpec).")
        }

        let versionResult = try await runNVMCommand("nvm version \(shellQuote(installableSpec))")
        guard versionResult.exitCode == 0 else {
            throw StackriotError.commandFailed(versionResult.stderr.isEmpty ? versionResult.stdout : versionResult.stderr)
        }

        let resolvedVersion = versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodeURL = URL(fileURLWithPath: nodePath)
        let binURL = nodeURL.deletingLastPathComponent()
        let environment = runtimeEnvironment(binDirectory: binURL.path)
        let runtime = ResolvedNodeRuntime(
            requestedVersionSpec: requirement.nodeVersionSpec,
            resolvedVersion: resolvedVersion,
            versionSource: requirement.versionSource,
            nodeBinaryPath: nodeURL.path,
            npmBinaryPath: binURL.appendingPathComponent("npm").path,
            corepackBinaryPath: binURL.appendingPathComponent("corepack").path,
            binDirectoryPath: binURL.path,
            environment: environment
        )

        cachedStatus.bootstrapState = "Ready"
        cachedStatus.defaultVersionSpec = AppPreferences.nodeDefaultVersionSpec
        if requirement.versionSource == .defaultLTS {
            cachedStatus.resolvedDefaultVersion = resolvedVersion
        }
        cachedStatus.runtimeRootPath = AppPaths.nodeRuntimeRoot.path
        cachedStatus.npmCachePath = AppPaths.npmCacheDirectory.path
        cachedStatus.lastErrorMessage = nil
        persistStatus()

        return runtime
    }

    private func resolveInstallableSpec(for rawSpec: String) async throws -> String {
        let trimmed = rawSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AppPreferences.nodeDefaultVersionSpec
        }

        guard versionResolver.requiresRemoteResolution(trimmed) else {
            return trimmed
        }

        let remoteVersions = try await fetchRemoteNodeVersions()
        if let resolved = versionResolver.resolveInstallableSpec(for: trimmed, availableVersions: remoteVersions) {
            return resolved
        }

        throw StackriotError.commandFailed("No installable Node.js version matches '\(trimmed)'.")
    }

    private func bootstrapNVMIfNeeded(allowUpdate: Bool) async throws {
        try AppPaths.ensureBaseDirectories()
        let nvmScript = AppPaths.nvmDirectory.appendingPathComponent("nvm.sh")

        if !FileManager.default.fileExists(atPath: nvmScript.path) {
            if FileManager.default.fileExists(atPath: AppPaths.nvmDirectory.path) {
                if try await waitForNVMInstallation(timeout: 10) {
                    return
                }
                try? FileManager.default.removeItem(at: AppPaths.nvmDirectory)
            }

            cachedStatus.bootstrapState = "Installing"
            cachedStatus.lastErrorMessage = nil
            persistStatus()

            let cloneResult = try await CommandRunner.runCollected(
                executable: "git",
                arguments: [
                    "clone",
                    "--depth", "1",
                    Self.nvmRepositoryURL,
                    AppPaths.nvmDirectory.path,
                ],
                environment: baseEnvironment()
            )
            if cloneResult.exitCode != 0,
               cloneResult.stderr.contains("already exists"),
               try await waitForNVMInstallation(timeout: 10) {
                return
            }
            guard cloneResult.exitCode == 0 else {
                throw StackriotError.commandFailed(cloneResult.stderr.isEmpty ? cloneResult.stdout : cloneResult.stderr)
            }
            return
        }

        guard allowUpdate else { return }

        let updateResult = try await CommandRunner.runCollected(
            executable: "git",
            arguments: [
                "-C", AppPaths.nvmDirectory.path,
                "pull",
                "--ff-only",
            ],
            environment: baseEnvironment()
        )
        guard updateResult.exitCode == 0 else {
            throw StackriotError.commandFailed(updateResult.stderr.isEmpty ? updateResult.stdout : updateResult.stderr)
        }
    }

    private func enableCorepack(in runtime: ResolvedNodeRuntime) async throws {
        let result = try await CommandRunner.runCollected(
            executable: runtime.corepackBinaryPath,
            arguments: ["enable", "--install-directory", runtime.binDirectoryPath],
            environment: runtime.environment
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func runNVMCommand(_ command: String) async throws -> CommandResult {
        let nvmScript = AppPaths.nvmDirectory.appendingPathComponent("nvm.sh").path
        let script = """
        set -euo pipefail
        export NVM_DIR=\(shellQuote(AppPaths.nvmDirectory.path))
        export NPM_CONFIG_CACHE=\(shellQuote(AppPaths.npmCacheDirectory.path))
        export npm_config_cache=\(shellQuote(AppPaths.npmCacheDirectory.path))
        export XDG_CACHE_HOME=\(shellQuote(AppPaths.runtimeCacheRoot.path))
        export COREPACK_HOME=\(shellQuote(AppPaths.corepackCacheDirectory.path))
        export TMPDIR=\(shellQuote(AppPaths.runtimeTemporaryDirectory.path))
        mkdir -p "$NVM_DIR" "$NVM_DIR/versions/node" "$NPM_CONFIG_CACHE" "$XDG_CACHE_HOME" "$COREPACK_HOME" "$TMPDIR"
        . \(shellQuote(nvmScript))
        \(command)
        """

        return try await CommandRunner.runCollected(
            executable: "bash",
            arguments: ["-lc", script],
            environment: baseEnvironment()
        )
    }

    private func fetchRemoteNodeVersions() async throws -> [String] {
        let result = try await runNVMCommand("nvm ls-remote --no-colors")
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("v") }
    }

    private func baseEnvironment() -> [String: String] {
        [
            "NVM_DIR": AppPaths.nvmDirectory.path,
            "NPM_CONFIG_CACHE": AppPaths.npmCacheDirectory.path,
            "npm_config_cache": AppPaths.npmCacheDirectory.path,
            "XDG_CACHE_HOME": AppPaths.runtimeCacheRoot.path,
            "COREPACK_HOME": AppPaths.corepackCacheDirectory.path,
            "TMPDIR": AppPaths.runtimeTemporaryDirectory.path,
        ]
    }

    private func runtimeEnvironment(binDirectory: String) -> [String: String] {
        var environment = baseEnvironment()
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(binDirectory):\(currentPath)"
        environment["NVM_BIN"] = binDirectory
        return environment
    }

    private func persistStatus() {
        do {
            try AppPaths.ensureBaseDirectories()
            let data = try JSONEncoder().encode(cachedStatus)
            try data.write(to: AppPaths.nodeRuntimeStateFile, options: .atomic)
        } catch {
            // Keep runtime operations going even if status persistence fails.
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func waitForNVMInstallation(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        let scriptPath = AppPaths.nvmDirectory.appendingPathComponent("nvm.sh").path
        while Date.now < deadline {
            if FileManager.default.fileExists(atPath: scriptPath) {
                return true
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return FileManager.default.fileExists(atPath: scriptPath)
    }
}

struct NodeVersionSpecResolver {
    func requiresRemoteResolution(_ spec: String) -> Bool {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return false
        }

        let lowered = trimmed.lowercased()
        if lowered == "node" || lowered == "stable" || lowered == "unstable"
            || lowered.hasPrefix("lts/")
            || lowered.hasPrefix("iojs") {
            return false
        }

        return trimmed.contains("||")
            || trimmed.contains(" ")
            || trimmed.contains(">") || trimmed.contains("<")
            || trimmed.contains("^") || trimmed.contains("~")
            || trimmed.contains("*") || trimmed.contains("x") || trimmed.contains("X")
    }

    func resolveInstallableSpec(for spec: String, availableVersions: [String]) -> String? {
        let versions = availableVersions.compactMap(SemanticVersion.init)
        let predicates = spec
            .split(separator: "|", omittingEmptySubsequences: true)
            .map(String.init)
            .map { $0.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(parseConjunction(_:))

        guard !predicates.isEmpty else { return nil }

        return versions
            .sorted(by: >)
            .first { version in
                predicates.contains { predicate in predicate.allSatisfy { $0(version) } }
            }?
            .description
    }

    private func parseConjunction(_ rawPart: String) -> [VersionPredicate]? {
        let tokens = rawPart
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        let predicates = tokens.compactMap(parseToken(_:))
        return predicates.count == tokens.count ? predicates : nil
    }

    private func parseToken(_ token: String) -> VersionPredicate? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for comparator in [">=", "<=", ">", "<", "=", "^", "~"] {
            if trimmed.hasPrefix(comparator) {
                let rawValue = String(trimmed.dropFirst(comparator.count))
                return predicate(for: comparator, value: rawValue)
            }
        }

        return predicate(for: "", value: trimmed)
    }

    private func predicate(for comparator: String, value rawValue: String) -> VersionPredicate? {
        guard let partial = PartialVersion(rawValue) else {
            return nil
        }

        switch comparator {
        case ">=":
            let minimum = partial.lowerBound
            return { $0 >= minimum }
        case "<=":
            let maximum = partial.lowerBound
            return { $0 <= maximum }
        case ">":
            let minimum = partial.lowerBound
            return { $0 > minimum }
        case "<":
            let maximum = partial.lowerBound
            return { $0 < maximum }
        case "=":
            if let exact = partial.exactVersion {
                return { $0 == exact }
            }
            return { partial.contains($0) }
        case "^":
            guard let upper = partial.caretUpperBound else { return nil }
            return { $0 >= partial.lowerBound && $0 < upper }
        case "~":
            guard let upper = partial.tildeUpperBound else { return nil }
            return { $0 >= partial.lowerBound && $0 < upper }
        case "":
            if let exact = partial.exactVersion {
                return { $0 == exact }
            }
            guard let upper = partial.wildcardUpperBound else { return nil }
            return { $0 >= partial.lowerBound && $0 < upper }
        default:
            return nil
        }
    }
}

private typealias VersionPredicate = (SemanticVersion) -> Bool

private struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.anchored])
        let parts = trimmed.split(separator: ".").map(String.init)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String {
        "v\(major).\(minor).\(patch)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

private struct PartialVersion {
    let major: Int
    let minor: Int?
    let patch: Int?
    let hasWildcard: Bool

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.anchored])
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let major = Int(first) else { return nil }

        self.major = major
        self.minor = Self.parseComponent(parts[safe: 1])
        self.patch = Self.parseComponent(parts[safe: 2])
        self.hasWildcard = parts.contains { Self.isWildcard($0) }
            || parts.count < 3
    }

    var lowerBound: SemanticVersion {
        SemanticVersion("v\(major).\(minor ?? 0).\(patch ?? 0)")!
    }

    var exactVersion: SemanticVersion? {
        guard !hasWildcard, let minor, let patch else { return nil }
        return SemanticVersion("v\(major).\(minor).\(patch)")
    }

    var wildcardUpperBound: SemanticVersion? {
        if exactVersion != nil {
            return nil
        }
        if let minor {
            return SemanticVersion("v\(major).\(minor + 1).0")
        }
        return SemanticVersion("v\(major + 1).0.0")
    }

    var tildeUpperBound: SemanticVersion? {
        if let minor {
            return SemanticVersion("v\(major).\(minor + 1).0")
        }
        return SemanticVersion("v\(major + 1).0.0")
    }

    var caretUpperBound: SemanticVersion? {
        if major > 0 {
            return SemanticVersion("v\(major + 1).0.0")
        }
        if let minor, minor > 0 {
            return SemanticVersion("v0.\(minor + 1).0")
        }
        return SemanticVersion("v0.0.\((patch ?? 0) + 1)")
    }

    func contains(_ version: SemanticVersion) -> Bool {
        guard let upper = wildcardUpperBound else {
            return exactVersion == version
        }
        return version >= lowerBound && version < upper
    }

    private static func parseComponent(_ value: String?) -> Int? {
        guard let value else { return nil }
        if isWildcard(value) { return nil }
        return Int(value)
    }

    private static func isWildcard(_ value: String) -> Bool {
        value == "*" || value == "x" || value == "X"
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
