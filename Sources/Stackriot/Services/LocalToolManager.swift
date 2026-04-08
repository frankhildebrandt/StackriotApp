import AppKit
import Foundation

@MainActor
final class LocalToolManager {
    private let fileManager: FileManager
    private let ideManager: IDEManager
    private let nodeRuntimeManager: NodeRuntimeManager
    private let shellPathProvider: @Sendable () async -> String

    init(
        fileManager: FileManager = .default,
        ideManager: IDEManager = IDEManager(),
        nodeRuntimeManager: NodeRuntimeManager = NodeRuntimeManager(),
        shellPathProvider: @escaping @Sendable () async -> String = {
            await ShellEnvironment.loginShellPath(includeAppManagedPaths: false)
        }
    ) {
        self.fileManager = fileManager
        self.ideManager = ideManager
        self.nodeRuntimeManager = nodeRuntimeManager
        self.shellPathProvider = shellPathProvider
    }

    func status(for tool: AppManagedTool) async -> AppManagedToolStatus {
        let shellPath = await shellPathProvider()
        if let shellExecutable = resolvedExecutablePath(named: tool.executableName, inPATH: shellPath, fileManager: fileManager) {
            return AppManagedToolStatus(
                tool: tool,
                resolutionSource: .shell,
                resolvedPath: shellExecutable,
                installHint: installHint(for: tool)
            )
        }

        if let appManagedExecutable = appManagedExecutablePath(for: tool) {
            return AppManagedToolStatus(
                tool: tool,
                resolutionSource: .appManaged,
                resolvedPath: appManagedExecutable,
                installHint: installHint(for: tool)
            )
        }

        return AppManagedToolStatus(
            tool: tool,
            resolutionSource: .unavailable,
            resolvedPath: nil,
            installHint: installHint(for: tool)
        )
    }

    func allStatuses() async -> [AppManagedToolStatus] {
        var statuses: [AppManagedToolStatus] = []
        for tool in AppManagedTool.allCases {
            statuses.append(await status(for: tool))
        }
        return statuses
    }

    func availableAgentTools() async -> Set<AIAgentTool> {
        var tools: Set<AIAgentTool> = []
        for tool in AIAgentTool.allCases where tool != .none {
            guard let managedTool = tool.managedTool else {
                if let executable = tool.executableName,
                   resolvedExecutablePath(named: executable, inPATH: await shellPathProvider(), fileManager: fileManager) != nil {
                    tools.insert(tool)
                }
                continue
            }

            if await status(for: managedTool).isAvailable {
                tools.insert(tool)
            }
        }
        return tools
    }

    func install(_ tool: AppManagedTool) async throws -> AppManagedToolStatus {
        try AppPaths.ensureBaseDirectories()

        switch tool {
        case .devcontainer:
            try await installNPMPackage("@devcontainers/cli")
        case .claude:
            try await installNPMPackage("@anthropic-ai/claude-code")
        case .cursorAgent:
            try await installCursorAgent()
        case .codex:
            try await installNPMPackage("@openai/codex")
        case .openCode:
            try await installNPMPackage("opencode-ai")
        case .vscode:
            try installVSCodeShim()
        }

        let updated = await status(for: tool)
        guard updated.isAvailable else {
            throw StackriotError.commandFailed("\(tool.displayName) could not be installed or linked.")
        }
        return updated
    }

    func appManagedExecutablePath(for tool: AppManagedTool) -> String? {
        let linkedExecutable = AppPaths.localToolsBinDirectory.appendingPathComponent(tool.executableName).path
        if fileManager.isExecutableFile(atPath: linkedExecutable) {
            return linkedExecutable
        }

        let npmExecutable = AppPaths.localToolsNPMPrefix.appendingPathComponent("bin/\(tool.executableName)").path
        if fileManager.isExecutableFile(atPath: npmExecutable) {
            return npmExecutable
        }

        let cursorExecutable = AppPaths.localToolsCursorBinDirectory.appendingPathComponent(tool.executableName).path
        if fileManager.isExecutableFile(atPath: cursorExecutable) {
            return cursorExecutable
        }

        return nil
    }

    private func installNPMPackage(_ packageName: String) async throws {
        let descriptor = CommandExecutionDescriptor(
            title: "Install local CLI",
            actionKind: .npmScript,
            executable: "npm",
            arguments: ["install", "--global", "--prefix", AppPaths.localToolsNPMPrefix.path, packageName],
            repositoryID: UUID(),
            runtimeRequirement: NodeRuntimeRequirement(
                packageManager: .npm,
                nodeVersionSpec: AppPreferences.nodeDefaultVersionSpec,
                versionSource: .defaultLTS
            ),
            usesTerminalSession: false
        )

        let prepared = try await nodeRuntimeManager.prepareExecution(for: descriptor)
        let environment = await ShellEnvironment.resolvedEnvironment(overrides: prepared.environment)
        let result = try await CommandRunner.runCollected(
            executable: prepared.executable,
            arguments: prepared.arguments,
            environment: environment
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.nonEmpty ?? result.stdout.nonEmpty ?? "npm install failed.")
        }
    }

    private func installCursorAgent() async throws {
        let environment = await ShellEnvironment.resolvedEnvironment(
            additional: [
                "HOME": AppPaths.localToolsCursorHome.path,
            ]
        )
        let result = try await CommandRunner.runCollected(
            executable: "bash",
            arguments: ["-lc", "curl -fsSL https://cursor.com/install | bash"],
            environment: environment
        )
        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.nonEmpty ?? result.stdout.nonEmpty ?? "Cursor Agent install failed.")
        }

        let installedBinary = AppPaths.localToolsCursorBinDirectory.appendingPathComponent("cursor-agent")
        guard fileManager.isExecutableFile(atPath: installedBinary.path) else {
            throw StackriotError.commandFailed("Cursor Agent install completed without a cursor-agent binary.")
        }

        try installSymlink(
            target: installedBinary,
            at: AppPaths.localToolsBinDirectory.appendingPathComponent("cursor-agent")
        )
    }

    private func installVSCodeShim() throws {
        guard let appURL = ideManager.installationURL(for: .vscode) else {
            throw StackriotError.commandFailed("Visual Studio Code is not installed, so Stackriot cannot manage the code CLI locally.")
        }

        let executableURL = appURL.appendingPathComponent("Contents/Resources/app/bin/code")
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw StackriotError.commandFailed("The Visual Studio Code app bundle does not provide a usable code CLI.")
        }

        try installSymlink(
            target: executableURL,
            at: AppPaths.localToolsBinDirectory.appendingPathComponent("code")
        )
    }

    private func installSymlink(target: URL, at destination: URL) throws {
        try? fileManager.removeItem(at: destination)
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: target)
    }

    private func installHint(for tool: AppManagedTool) -> String? {
        switch tool {
        case .devcontainer:
            "Install via Stackriot or provide devcontainer on your shell PATH."
        case .claude:
            "Install via Stackriot or install @anthropic-ai/claude-code globally."
        case .cursorAgent:
            "Install via Stackriot or run the official Cursor Agent installer."
        case .codex:
            "Install via Stackriot or install @openai/codex globally."
        case .openCode:
            "Install via Stackriot or install opencode-ai globally."
        case .vscode:
            "Install via Stackriot to link the VS Code app bundle as code."
        }
    }
}

actor ACPAgentDiscoveryService {
    func snapshots(for tools: Set<AIAgentTool>, workingDirectoryURL: URL) async -> [AIAgentTool: ACPAgentSnapshot] {
        let reports = await reports(for: tools, workingDirectoryURL: workingDirectoryURL)
        return reports.reduce(into: [:]) { partialResult, entry in
            if let snapshot = entry.value.snapshot {
                partialResult[entry.key] = snapshot
            }
        }
    }

    typealias UpdateHandler = @MainActor @Sendable (ACPMetadataDiscoveryReport) -> Void

    func reports(
        for tools: Set<AIAgentTool>,
        workingDirectoryURL: URL,
        onUpdate: UpdateHandler? = nil
    ) async -> [AIAgentTool: ACPMetadataDiscoveryReport] {
        let environment = await ShellEnvironment.resolvedEnvironment(includeAppManagedPaths: true)
        let path = environment["PATH"] ?? ""
        let discoveryTools = AIAgentTool.allCases.filter { tools.contains($0) && $0.supportsACPDiscovery }

        return await withTaskGroup(of: (AIAgentTool, ACPMetadataDiscoveryReport).self) { group in
            for tool in discoveryTools {
                let startedAt = Date()
                if let onUpdate {
                    await onUpdate(Self.makeRunningReport(
                        tool: tool,
                        workingDirectoryURL: workingDirectoryURL,
                        path: path,
                        startedAt: startedAt
                    ))
                }

                group.addTask { [workingDirectoryURL, environment, path] in
                    let report = await self.report(
                        for: tool,
                        workingDirectoryURL: workingDirectoryURL,
                        environment: environment,
                        path: path,
                        startedAt: startedAt
                    )
                    return (tool, report)
                }
            }

            var reports: [AIAgentTool: ACPMetadataDiscoveryReport] = [:]
            for await (tool, report) in group {
                reports[tool] = report
                if let onUpdate {
                    await onUpdate(report)
                }
            }
            return reports
        }
    }

    func snapshot(for tool: AIAgentTool, workingDirectoryURL: URL) async -> ACPAgentSnapshot? {
        let report = await report(
            for: tool,
            workingDirectoryURL: workingDirectoryURL,
            environment: await ShellEnvironment.resolvedEnvironment(includeAppManagedPaths: true),
            path: await ShellEnvironment.loginShellPath(includeAppManagedPaths: true),
            startedAt: Date()
        )
        return report.snapshot
    }

    private func report(
        for tool: AIAgentTool,
        workingDirectoryURL: URL,
        environment: [String: String],
        path: String,
        startedAt: Date
    ) async -> ACPMetadataDiscoveryReport {
        guard let executable = tool.acpExecutableName,
              let acpArguments = tool.acpLaunchArguments else {
            return ACPMetadataDiscoveryReport(
                tool: tool,
                status: .unavailable,
                executablePath: nil,
                commandLine: tool.displayName,
                workingDirectoryPath: workingDirectoryURL.path,
                environmentPath: path,
                summary: "ACP discovery is not supported for this CLI.",
                detail: Self.makeDetail(
                    commandLine: tool.displayName,
                    executablePath: nil,
                    workingDirectoryPath: workingDirectoryURL.path,
                    environmentPath: path,
                    statusLine: "ACP discovery is not supported for this CLI."
                ),
                startedAt: startedAt,
                finishedAt: Date(),
                snapshot: nil
            )
        }

        let commandLine = Self.commandLine(executable: executable, arguments: acpArguments)
        guard let executablePath = resolvedExecutablePath(
            named: executable,
            inPATH: path,
            fileManager: FileManager.default
        ) else {
            return ACPMetadataDiscoveryReport(
                tool: tool,
                status: .unavailable,
                executablePath: nil,
                commandLine: commandLine,
                workingDirectoryPath: workingDirectoryURL.path,
                environmentPath: path,
                summary: "ACP executable not found on PATH.",
                detail: Self.makeDetail(
                    commandLine: commandLine,
                    executablePath: nil,
                    workingDirectoryPath: workingDirectoryURL.path,
                    environmentPath: path,
                    statusLine: "Expected `\(executable)` in the login-shell PATH or Stackriot-managed CLI directories."
                ),
                startedAt: startedAt,
                finishedAt: Date(),
                snapshot: nil
            )
        }

        do {
            let snapshot = try await Task.detached(priority: .utility) {
                let transport = try ACPJSONRPCTransport(
                    executableURL: URL(fileURLWithPath: executablePath),
                    arguments: acpArguments,
                    currentDirectoryURL: workingDirectoryURL,
                    environment: environment
                )
                defer { transport.terminate() }

                let initializeResponse = try await transport.request(
                    method: "initialize",
                    params: [
                        "protocolVersion": 1,
                        "clientCapabilities": [
                            "fs": [
                                "readTextFile": false,
                                "writeTextFile": false,
                            ],
                            "terminal": false,
                        ],
                        "clientInfo": [
                            "name": "Stackriot",
                            "version": "1.0.21",
                        ],
                    ]
                )
                let sessionResponse = try await transport.request(
                    method: "session/new",
                    params: [
                        "cwd": workingDirectoryURL.path,
                        "mcpServers": [],
                    ]
                )

                return Self.parseSnapshot(
                    tool: tool,
                    initializeResponse: initializeResponse,
                    sessionResponse: sessionResponse
                )
            }.value

            guard let snapshot else {
                return ACPMetadataDiscoveryReport(
                    tool: tool,
                    status: .failed,
                    executablePath: executablePath,
                    commandLine: commandLine,
                    workingDirectoryPath: workingDirectoryURL.path,
                    environmentPath: path,
                    summary: "ACP responses could not be parsed.",
                    detail: Self.makeDetail(
                        commandLine: commandLine,
                        executablePath: executablePath,
                        workingDirectoryPath: workingDirectoryURL.path,
                        environmentPath: path,
                        statusLine: "The CLI answered, but it did not return the expected initialize/session payloads."
                    ),
                    startedAt: startedAt,
                    finishedAt: Date(),
                    snapshot: nil
                )
            }

            let parts = [
                snapshot.models.isEmpty ? nil : "\(snapshot.models.count) models",
                snapshot.modes.isEmpty ? nil : "\(snapshot.modes.count) modes",
                snapshot.authMethods.isEmpty ? nil : "\(snapshot.authMethods.count) auth method\(snapshot.authMethods.count == 1 ? "" : "s")",
            ].compactMap { $0 }

            return ACPMetadataDiscoveryReport(
                tool: tool,
                status: .succeeded,
                executablePath: executablePath,
                commandLine: commandLine,
                workingDirectoryPath: workingDirectoryURL.path,
                environmentPath: path,
                summary: parts.isEmpty ? "ACP metadata loaded." : parts.joined(separator: " · "),
                detail: Self.makeDetail(
                    commandLine: commandLine,
                    executablePath: executablePath,
                    workingDirectoryPath: workingDirectoryURL.path,
                    environmentPath: path,
                    statusLine: [
                        snapshot.agentInfo?.version.map { "CLI version \($0)." },
                        "Loaded \(snapshot.models.count) model(s), \(snapshot.modes.count) mode(s), and \(snapshot.configOptions.count) config option(s)."
                    ].compactMap { $0 }.joined(separator: " ")
                ),
                startedAt: startedAt,
                finishedAt: Date(),
                snapshot: snapshot
            )
        } catch {
            return ACPMetadataDiscoveryReport(
                tool: tool,
                status: .failed,
                executablePath: executablePath,
                commandLine: commandLine,
                workingDirectoryPath: workingDirectoryURL.path,
                environmentPath: path,
                summary: "ACP discovery failed.",
                detail: Self.makeDetail(
                    commandLine: commandLine,
                    executablePath: executablePath,
                    workingDirectoryPath: workingDirectoryURL.path,
                    environmentPath: path,
                    statusLine: error.localizedDescription
                ),
                startedAt: startedAt,
                finishedAt: Date(),
                snapshot: nil
            )
        }
    }

    private static func makeRunningReport(
        tool: AIAgentTool,
        workingDirectoryURL: URL,
        path: String,
        startedAt: Date
    ) -> ACPMetadataDiscoveryReport {
        let executable = tool.acpExecutableName ?? tool.displayName
        let arguments = tool.acpLaunchArguments ?? []
        let commandLine = commandLine(executable: executable, arguments: arguments)
        let executablePath = resolvedExecutablePath(named: executable, inPATH: path, fileManager: .default)
        return ACPMetadataDiscoveryReport(
            tool: tool,
            status: .running,
            executablePath: executablePath,
            commandLine: commandLine,
            workingDirectoryPath: workingDirectoryURL.path,
            environmentPath: path,
            summary: "Launching ACP discovery...",
            detail: makeDetail(
                commandLine: commandLine,
                executablePath: executablePath,
                workingDirectoryPath: workingDirectoryURL.path,
                environmentPath: path,
                statusLine: "Starting ACP initialize/session/new handshake."
            ),
            startedAt: startedAt,
            finishedAt: nil,
            snapshot: nil
        )
    }

    private static func commandLine(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).joined(separator: " ")
    }

    private static func makeDetail(
        commandLine: String,
        executablePath: String?,
        workingDirectoryPath: String,
        environmentPath: String,
        statusLine: String
    ) -> String {
        [
            "Command: \(commandLine)",
            executablePath.map { "Resolved executable: \($0)" } ?? "Resolved executable: unavailable",
            "Working directory: \(workingDirectoryPath)",
            "PATH: \(environmentPath)",
            "",
            statusLine
        ].joined(separator: "\n")
    }

    private static func parseSnapshot(
        tool: AIAgentTool,
        initializeResponse: [String: Any],
        sessionResponse: [String: Any]
    ) -> ACPAgentSnapshot? {
        guard let initializeResult = initializeResponse["result"] as? [String: Any],
              let protocolVersion = initializeResult["protocolVersion"] as? Int,
              let sessionResult = sessionResponse["result"] as? [String: Any] else {
            return nil
        }

        let agentCapabilities = initializeResult["agentCapabilities"] as? [String: Any] ?? [:]
        let promptCapabilities = agentCapabilities["promptCapabilities"] as? [String: Any] ?? [:]
        let sessionCapabilities = agentCapabilities["sessionCapabilities"] as? [String: Any] ?? [:]
        let mcpCapabilities = agentCapabilities["mcpCapabilities"] as? [String: Any] ?? [:]
        let agentInfo = parseAgentInfo(initializeResult["agentInfo"] as? [String: Any])
        let authMethods = parseAuthMethods(initializeResult["authMethods"] as? [[String: Any]] ?? [])

        let modes = parseModes(from: sessionResult["modes"] as? [String: Any])
        let configOptions = parseConfigOptions(from: sessionResult["configOptions"] as? [[String: Any]] ?? [])
        let modelsPayload = sessionResult["models"] as? [String: Any]
        let models = parseModels(from: modelsPayload)

        return ACPAgentSnapshot(
            tool: tool,
            protocolVersion: protocolVersion,
            agentInfo: agentInfo,
            authMethods: authMethods,
            loadSession: (agentCapabilities["loadSession"] as? Bool) ?? false,
            supportsSessionList: sessionCapabilities["list"] != nil,
            promptSupportsEmbeddedContext: (promptCapabilities["embeddedContext"] as? Bool) ?? false,
            promptSupportsImage: (promptCapabilities["image"] as? Bool) ?? false,
            promptSupportsAudio: (promptCapabilities["audio"] as? Bool) ?? false,
            mcpSupportsHTTP: (mcpCapabilities["http"] as? Bool) ?? false,
            mcpSupportsSSE: (mcpCapabilities["sse"] as? Bool) ?? false,
            currentSessionID: sessionResult["sessionId"] as? String,
            currentModeID: (sessionResult["modes"] as? [String: Any])?["currentModeId"] as? String,
            modes: modes,
            currentModelID: modelsPayload?["currentModelId"] as? String,
            models: models,
            configOptions: configOptions
        )
    }

    private static func parseAgentInfo(_ payload: [String: Any]?) -> ACPAgentInfo? {
        guard let payload, let name = payload["name"] as? String else {
            return nil
        }
        return ACPAgentInfo(
            name: name,
            title: payload["title"] as? String,
            version: payload["version"] as? String
        )
    }

    private static func parseAuthMethods(_ payload: [[String: Any]]) -> [ACPAuthMethod] {
        payload.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let name = entry["name"] as? String else {
                return nil
            }
            return ACPAuthMethod(id: id, name: name, description: entry["description"] as? String)
        }
    }

    private static func parseModes(from payload: [String: Any]?) -> [ACPDiscoveredMode] {
        guard let availableModes = payload?["availableModes"] as? [[String: Any]] else {
            return []
        }
        return availableModes.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let name = entry["name"] as? String else {
                return nil
            }
            return ACPDiscoveredMode(id: id, displayName: name, description: entry["description"] as? String)
        }
    }

    private static func parseModels(from payload: [String: Any]?) -> [ACPDiscoveredModel] {
        guard let availableModels = payload?["availableModels"] as? [[String: Any]] else {
            return []
        }
        return availableModels.compactMap { entry in
            guard let id = entry["modelId"] as? String,
                  let name = entry["name"] as? String else {
                return nil
            }
            return ACPDiscoveredModel(id: id, displayName: name, description: entry["description"] as? String)
        }
    }

    private static func parseConfigOptions(from payload: [[String: Any]]) -> [ACPDiscoveredConfigOption] {
        payload.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let name = entry["name"] as? String,
                  let currentValue = entry["currentValue"] as? String else {
                return nil
            }
            let groups = parseConfigValueGroups(from: entry["options"])
            guard groups.isEmpty == false else { return nil }
            return ACPDiscoveredConfigOption(
                id: id,
                displayName: name,
                description: entry["description"] as? String,
                rawCategory: entry["category"] as? String,
                currentValue: currentValue,
                groups: groups
            )
        }
    }

    private static func parseConfigValueGroups(from payload: Any?) -> [ACPDiscoveredConfigValueGroup] {
        if let options = payload as? [[String: Any]], options.first?["value"] != nil {
            let values = options.compactMap(parseConfigValue(_:))
            return values.isEmpty ? [] : [ACPDiscoveredConfigValueGroup(groupID: nil, displayName: nil, options: values)]
        }

        guard let groups = payload as? [[String: Any]] else {
            return []
        }
        return groups.compactMap { entry in
            guard let options = entry["options"] as? [[String: Any]] else {
                return nil
            }
            let values = options.compactMap(parseConfigValue(_:))
            guard values.isEmpty == false else { return nil }
            return ACPDiscoveredConfigValueGroup(
                groupID: entry["group"] as? String,
                displayName: entry["name"] as? String,
                options: values
            )
        }
    }

    private static func parseConfigValue(_ payload: [String: Any]) -> ACPDiscoveredConfigValue? {
        guard let value = payload["value"] as? String,
              let name = payload["name"] as? String else {
            return nil
        }
        return ACPDiscoveredConfigValue(value: value, displayName: name, description: payload["description"] as? String)
    }
}

private final class ACPJSONRPCTransport {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrDrainer: Task<Void, Never>
    private let diagnostics = ACPDiscoveryDiagnostics()
    private var bytesIterator: FileHandle.AsyncBytes.Iterator
    private var bufferedData = Data()
    private var nextRequestID = 1

    init(executableURL: URL, arguments: [String], currentDirectoryURL: URL, environment: [String: String]) throws {
        process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        bytesIterator = stdoutHandle.bytes.makeAsyncIterator()
        let diagnostics = self.diagnostics
        process.terminationHandler = { proc in
            diagnostics.setTerminationStatus(proc.terminationStatus)
        }
        stderrDrainer = Task.detached(priority: .background) {
            var iterator = stderrPipe.fileHandleForReading.bytes.makeAsyncIterator()
            var buffer = Data()
            while let nextByte = (try? await iterator.next()) ?? nil {
                buffer.append(nextByte)
                if nextByte == 0x0A {
                    diagnostics.append(lineData: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if buffer.isEmpty == false {
                diagnostics.append(lineData: buffer)
            }
        }

        try process.run()
    }

    func terminate() {
        stderrDrainer.cancel()
        if process.isRunning {
            process.terminate()
        }
        try? stdinHandle.close()
        try? stdoutHandle.close()
    }

    func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestID = nextRequestID
        nextRequestID += 1

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        stdinHandle.write(data)
        stdinHandle.write(Data("\n".utf8))

        return try await waitForResponse(requestID: requestID)
    }

    private func waitForResponse(requestID: Int) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let message = try await nextJSONMessage() {
                if let id = message["id"] as? Int, id == requestID {
                    return message
                }
            } else if !process.isRunning {
                break
            }
        }
        throw StackriotError.commandFailed(
            diagnostics.failureMessage(fallback: process.isRunning
                ? "ACP discovery timed out."
                : "ACP discovery process exited before returning a response.")
        )
    }

    private func nextJSONMessage() async throws -> [String: Any]? {
        while true {
            if let newlineRange = bufferedData.firstRange(of: Data([0x0A])) {
                let lineData = bufferedData[..<newlineRange.lowerBound]
                bufferedData.removeSubrange(..<newlineRange.upperBound)
                guard !lineData.isEmpty else { continue }
                guard let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }
                return json
            }

            guard let nextByte = try await waitForNextByte() else {
                return nil
            }
            bufferedData.append(nextByte)
        }
    }

    private func waitForNextByte() async throws -> UInt8? {
        try await bytesIterator.next()
    }
}

private final class ACPDiscoveryDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var stderrLines: [String] = []
    private var terminationStatus: Int32?

    func append(lineData: Data) {
        guard let line = String(data: lineData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        else {
            return
        }
        lock.lock()
        stderrLines.append(line)
        lock.unlock()
    }

    func setTerminationStatus(_ status: Int32) {
        lock.lock()
        terminationStatus = status
        lock.unlock()
    }

    func failureMessage(fallback: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let lastLine = stderrLines.last {
            return lastLine
        }
        if let terminationStatus, terminationStatus != 0 {
            return "\(fallback) Exit code \(terminationStatus)."
        }
        return fallback
    }
}

private func resolvedExecutablePath(
    named executable: String,
    inPATH path: String,
    fileManager: FileManager
) -> String? {
    let entries = path.split(separator: ":").map(String.init)
    for entry in entries {
        let candidate = URL(fileURLWithPath: entry).appendingPathComponent(executable).path
        if fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}
