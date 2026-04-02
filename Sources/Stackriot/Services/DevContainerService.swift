import Foundation

@MainActor
struct DevContainerService {
    typealias CommandExecutor = @Sendable (_ executable: String, _ arguments: [String], _ currentDirectoryURL: URL?) async throws -> CommandResult
    typealias CommandLocator = (_ command: String) async -> Bool

    private let fileManager: FileManager
    private let commandExecutor: CommandExecutor
    private let commandLocator: CommandLocator

    init(
        fileManager: FileManager = .default,
        commandExecutor: @escaping CommandExecutor = { executable, arguments, currentDirectoryURL in
            try await CommandRunner.runCollected(
                executable: executable,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL
            )
        },
        commandLocator: CommandLocator? = nil
    ) {
        self.fileManager = fileManager
        self.commandExecutor = commandExecutor
        self.commandLocator = commandLocator ?? { command in
            guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else {
                return false
            }

            for entry in pathValue.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent(command)
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return true
                }
            }

            return false
        }
    }

    func configuration(at worktreeURL: URL) -> DevContainerConfiguration? {
        let candidates = [
            worktreeURL.appendingPathComponent(".devcontainer/devcontainer.json"),
            worktreeURL.appendingPathComponent(".devcontainer.json"),
        ]

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path) {
                return DevContainerConfiguration(
                    workspaceFolderURL: worktreeURL,
                    configFileURL: candidate
                )
            }
        }

        return nil
    }

    func toolingStatus(
        strategy: DevContainerCLIStrategy = AppPreferences.devContainerCLIStrategy,
        isFeatureEnabled: Bool = AppPreferences.devContainerEnabled
    ) async -> DevContainerToolingStatus {
        let dockerInstalled = await commandLocator("docker")
        let devcontainerInstalled = await commandLocator("devcontainer")
        let npxInstalled = await commandLocator("npx")

        let resolvedCLI: DevContainerResolvedCLIKind?
        switch strategy {
        case .auto:
            if devcontainerInstalled {
                resolvedCLI = .devcontainerCLI
            } else if npxInstalled {
                resolvedCLI = .npx
            } else {
                resolvedCLI = nil
            }
        case .devcontainerCLI:
            resolvedCLI = devcontainerInstalled ? .devcontainerCLI : nil
        case .npx:
            resolvedCLI = npxInstalled ? .npx : nil
        }

        return DevContainerToolingStatus(
            isFeatureEnabled: isFeatureEnabled,
            cliStrategy: strategy,
            dockerInstalled: dockerInstalled,
            devcontainerInstalled: devcontainerInstalled,
            npxInstalled: npxInstalled,
            resolvedCLI: resolvedCLI
        )
    }

    func status(for worktreeURL: URL) async -> DevContainerWorkspaceSnapshot {
        let configuration = configuration(at: worktreeURL)
        let tooling = await toolingStatus()

        guard tooling.isFeatureEnabled else {
            return DevContainerWorkspaceSnapshot(
                configuration: configuration,
                lastUpdatedAt: .now,
                toolingStatus: tooling,
                diagnosticIssue: .featureDisabled
            )
        }

        guard let configuration else {
            return DevContainerWorkspaceSnapshot(
                configuration: nil,
                lastUpdatedAt: .now,
                toolingStatus: tooling,
                diagnosticIssue: .noConfiguration
            )
        }

        guard tooling.dockerInstalled else {
            return DevContainerWorkspaceSnapshot(
                configuration: configuration,
                detailsErrorMessage: "Docker CLI is required to inspect and run devcontainers.",
                lastUpdatedAt: .now,
                toolingStatus: tooling,
                diagnosticIssue: .dockerMissing
            )
        }

        do {
            let allContainerIDs = try await listContainerIDs(for: configuration, includeStopped: true)
            guard !allContainerIDs.isEmpty else {
                return DevContainerWorkspaceSnapshot(
                    configuration: configuration,
                    runtimeStatus: .stopped,
                    containerCount: 0,
                    lastUpdatedAt: .now,
                    toolingStatus: tooling
                )
            }

            let runningIDs = try await listContainerIDs(for: configuration, includeStopped: false)
            let runtimeStatus: DevContainerRuntimeStatus = runningIDs.isEmpty ? .stopped : .running
            let primaryContainerID = selectPrimaryContainerID(runningIDs: runningIDs, allContainerIDs: allContainerIDs)
            let inspect = try await inspectContainer(id: primaryContainerID)
            let stats = runtimeStatus == .running ? try? await fetchStats(for: primaryContainerID) : nil

            return DevContainerWorkspaceSnapshot(
                configuration: configuration,
                runtimeStatus: runtimeStatus,
                containerID: inspect.id,
                containerName: inspect.displayName,
                imageName: inspect.imageName,
                resourceUsage: stats,
                containerCount: allContainerIDs.count,
                lastUpdatedAt: .now,
                toolingStatus: tooling
            )
        } catch {
            return DevContainerWorkspaceSnapshot(
                configuration: configuration,
                runtimeStatus: .unknown,
                detailsErrorMessage: friendlyErrorMessage(for: error),
                lastUpdatedAt: .now,
                toolingStatus: tooling,
                diagnosticIssue: diagnosticIssue(for: error)
            )
        }
    }

    func start(worktreeURL: URL) async throws -> DevContainerWorkspaceSnapshot {
        let configuration = try requireConfiguration(at: worktreeURL)
        let tooling = try await requireOperationalTooling()
        _ = try await runCLI(
            command: "up",
            workspaceURL: worktreeURL,
            configuration: configuration,
            tooling: tooling,
            extraArguments: [
                "--log-format", "json",
                "--include-configuration",
            ]
        )
        return await status(for: worktreeURL)
    }

    func rebuild(worktreeURL: URL) async throws -> DevContainerWorkspaceSnapshot {
        let configuration = try requireConfiguration(at: worktreeURL)
        let tooling = try await requireOperationalTooling()
        _ = try await runCLI(
            command: "up",
            workspaceURL: worktreeURL,
            configuration: configuration,
            tooling: tooling,
            extraArguments: [
                "--remove-existing-container",
                "--build-no-cache",
                "--log-format", "json",
                "--include-configuration",
            ]
        )
        return await status(for: worktreeURL)
    }

    func stop(worktreeURL: URL) async throws -> DevContainerWorkspaceSnapshot {
        let configuration = try requireConfiguration(at: worktreeURL)
        try await requireDockerInstalled()
        let runningContainerIDs = try await listContainerIDs(for: configuration, includeStopped: false)
        if !runningContainerIDs.isEmpty {
            let result = try await commandExecutor("docker", ["stop"] + runningContainerIDs, nil)
            guard result.exitCode == 0 else {
                throw StackriotError.commandFailed(commandFailureMessage(result, fallback: "The devcontainer could not be stopped."))
            }
        }
        return await status(for: worktreeURL)
    }

    func restart(worktreeURL: URL) async throws -> DevContainerWorkspaceSnapshot {
        _ = try await stop(worktreeURL: worktreeURL)
        return try await start(worktreeURL: worktreeURL)
    }

    func delete(worktreeURL: URL) async throws -> DevContainerWorkspaceSnapshot {
        let configuration = try requireConfiguration(at: worktreeURL)
        try await requireDockerInstalled()
        let containerIDs = try await listContainerIDs(for: configuration, includeStopped: true)
        if !containerIDs.isEmpty {
            let result = try await commandExecutor("docker", ["rm", "-f"] + containerIDs, nil)
            guard result.exitCode == 0 else {
                throw StackriotError.commandFailed(commandFailureMessage(result, fallback: "The devcontainer could not be removed."))
            }
        }
        return await status(for: worktreeURL)
    }

    func logStreamDescriptor(for worktreeURL: URL, tail: Int = 200) async throws -> (String, [String]) {
        let configuration = try requireConfiguration(at: worktreeURL)
        try await requireDockerInstalled()
        let runningContainerIDs = try await listContainerIDs(for: configuration, includeStopped: false)
        guard let containerID = runningContainerIDs.first else {
            throw StackriotError.commandFailed("No running devcontainer was found for this workspace.")
        }

        return ("docker", ["logs", "-f", "--tail", String(tail), containerID])
    }

    func terminalDescriptor(
        for worktreeURL: URL,
        repositoryID: UUID,
        worktreeID: UUID
    ) async throws -> CommandExecutionDescriptor {
        let configuration = try requireConfiguration(at: worktreeURL)
        try await requireDockerInstalled()
        let runningContainerIDs = try await listContainerIDs(for: configuration, includeStopped: false)
        guard !runningContainerIDs.isEmpty else {
            throw StackriotError.commandFailed("No running devcontainer was found for this workspace.")
        }
        let primaryContainerID = selectPrimaryContainerID(runningIDs: runningContainerIDs, allContainerIDs: runningContainerIDs)
        let inspect = try await inspectContainer(id: primaryContainerID)

        return CommandExecutionDescriptor(
            title: "Devcontainer Terminal",
            actionKind: .devContainer,
            executable: "docker",
            arguments: [
                "exec", "-it", primaryContainerID,
                "sh", "-lc",
                "if command -v bash >/dev/null 2>&1; then exec bash -il; elif command -v sh >/dev/null 2>&1; then exec sh; else exec /bin/sh; fi",
            ],
            displayCommandLine: "docker exec -it \(inspect.displayName.nonEmpty ?? primaryContainerID) <shell>",
            currentDirectoryURL: worktreeURL,
            repositoryID: repositoryID,
            worktreeID: worktreeID,
            usesTerminalSession: true
        )
    }

    private func requireConfiguration(at worktreeURL: URL) throws -> DevContainerConfiguration {
        guard let configuration = configuration(at: worktreeURL) else {
            throw StackriotError.commandFailed("This worktree does not contain a devcontainer configuration.")
        }
        return configuration
    }

    private func requireOperationalTooling() async throws -> DevContainerToolingStatus {
        let tooling = await toolingStatus()
        guard tooling.isFeatureEnabled else {
            throw StackriotError.commandFailed("Devcontainer support is disabled in Settings.")
        }
        guard tooling.dockerInstalled else {
            throw StackriotError.executableNotFound("docker")
        }
        guard tooling.isCLIAvailable else {
            throw StackriotError.executableNotFound("devcontainer")
        }
        return tooling
    }

    private func requireDockerInstalled() async throws {
        guard await commandLocator("docker") else {
            throw StackriotError.executableNotFound("docker")
        }
    }

    private func runCLI(
        command: String,
        workspaceURL: URL,
        configuration: DevContainerConfiguration,
        tooling: DevContainerToolingStatus,
        extraArguments: [String] = []
    ) async throws -> CommandResult {
        let resolvedCLI = try resolveCLI(tooling: tooling)
        let arguments = resolvedCLI.argumentsPrefix + [
            command,
            "--workspace-folder", workspaceURL.path,
            "--config", configuration.configFileURL.path,
        ] + extraArguments
        let result = try await commandExecutor(resolvedCLI.executable, arguments, workspaceURL)
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(commandFailureMessage(result, fallback: "The devcontainer command failed."))
        }
        return result
    }

    private func resolveCLI(tooling: DevContainerToolingStatus) throws -> ResolvedCLI {
        switch tooling.resolvedCLI {
        case .devcontainerCLI:
            return ResolvedCLI(executable: "devcontainer", argumentsPrefix: [])
        case .npx:
            return ResolvedCLI(executable: "npx", argumentsPrefix: ["-y", "@devcontainers/cli"])
        case nil:
            throw StackriotError.executableNotFound("devcontainer")
        }
    }

    private func listContainerIDs(
        for configuration: DevContainerConfiguration,
        includeStopped: Bool
    ) async throws -> [String] {
        let primary = try await listContainerIDs(
            workspacePath: configuration.workspaceFolderURL.path,
            configPath: configuration.configFileURL.path,
            includeStopped: includeStopped
        )
        if !primary.isEmpty {
            return primary
        }

        return try await listContainerIDs(
            workspacePath: configuration.workspaceFolderURL.path,
            configPath: nil,
            includeStopped: includeStopped
        )
    }

    private func listContainerIDs(
        workspacePath: String,
        configPath: String?,
        includeStopped: Bool
    ) async throws -> [String] {
        var arguments = ["ps"]
        if includeStopped {
            arguments.append("-a")
        }
        arguments += ["--filter", "label=devcontainer.local_folder=\(workspacePath)"]
        if let configPath {
            arguments += ["--filter", "label=devcontainer.config_file=\(configPath)"]
        }
        arguments += ["--format", "{{.ID}}"]

        let result = try await commandExecutor("docker", arguments, nil)
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(commandFailureMessage(result, fallback: "Docker could not list devcontainer containers."))
        }

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func inspectContainer(id: String) async throws -> DockerInspectContainer {
        let result = try await commandExecutor("docker", ["inspect", id], nil)
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(commandFailureMessage(result, fallback: "Docker could not inspect the devcontainer."))
        }

        let data = Data(result.stdout.utf8)
        let containers = try JSONDecoder().decode([DockerInspectContainer].self, from: data)
        guard let container = containers.first else {
            throw StackriotError.commandFailed("Docker did not return inspect data for the devcontainer.")
        }
        return container
    }

    private func fetchStats(for containerID: String) async throws -> DevContainerResourceUsage? {
        let result = try await commandExecutor(
            "docker",
            ["stats", "--no-stream", "--format", "{{json .}}", containerID],
            nil
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(commandFailureMessage(result, fallback: "Docker could not read devcontainer stats."))
        }

        let line = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.nonEmpty != nil })
        guard let line else { return nil }
        let data = Data(line.utf8)
        let decoded = try JSONDecoder().decode(DockerStatsLine.self, from: data)
        return DevContainerResourceUsage(
            cpuPercent: decoded.cpuPercent?.nonEmpty,
            memoryUsage: decoded.memoryUsage?.nonEmpty,
            memoryPercent: decoded.memoryPercent?.nonEmpty
        )
    }

    private func selectPrimaryContainerID(runningIDs: [String], allContainerIDs: [String]) -> String {
        (runningIDs.first ?? allContainerIDs.first) ?? allContainerIDs[0]
    }

    private func diagnosticIssue(for error: Error) -> DevContainerDiagnosticIssue? {
        let rendered = error.localizedDescription
        if rendered.contains("Cannot connect to the Docker daemon") || rendered.contains("Docker is not reachable") {
            return .dockerUnreachable
        }
        if rendered.localizedCaseInsensitiveContains("inspect the devcontainer") {
            return .containerUnreachable
        }
        return nil
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        if let stackriotError = error as? StackriotError {
            return stackriotError.localizedDescription
        }

        let rendered = error.localizedDescription
        if rendered.contains("Cannot connect to the Docker daemon") {
            return "Docker is not reachable. Start Docker Desktop or another Docker engine and try again."
        }
        return rendered
    }

    private func commandFailureMessage(_ result: CommandResult, fallback: String) -> String {
        let output = result.stderr.nonEmpty ?? result.stdout.nonEmpty
        let message = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
        if message.contains("Cannot connect to the Docker daemon") {
            return "Docker is not reachable. Start Docker Desktop or another Docker engine and try again."
        }
        return message
    }
}

private struct ResolvedCLI: Sendable {
    let executable: String
    let argumentsPrefix: [String]
}

private struct DockerInspectContainer: Decodable, Sendable {
    struct Config: Decodable, Sendable {
        let image: String?

        enum CodingKeys: String, CodingKey {
            case image = "Image"
        }
    }

    let id: String
    let name: String
    let config: Config

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case config = "Config"
    }

    var displayName: String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var imageName: String? {
        config.image?.nonEmpty
    }
}

private struct DockerStatsLine: Decodable, Sendable {
    let cpuPercent: String?
    let memoryUsage: String?
    let memoryPercent: String?

    enum CodingKeys: String, CodingKey {
        case cpuPercent = "CPUPerc"
        case memoryUsage = "MemUsage"
        case memoryPercent = "MemPerc"
    }
}
