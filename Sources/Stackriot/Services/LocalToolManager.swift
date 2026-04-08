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
        if let shellExecutable = executablePath(named: tool.executableName, inPATH: shellPath) {
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
                   executablePath(named: executable, inPATH: await shellPathProvider()) != nil {
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

    private func executablePath(named executable: String, inPATH path: String) -> String? {
        let entries = path.split(separator: ":").map(String.init)
        for entry in entries {
            let candidate = URL(fileURLWithPath: entry).appendingPathComponent(executable).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
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
        await withTaskGroup(of: (AIAgentTool, ACPAgentSnapshot?).self) { group in
            for tool in tools where tool.supportsACPDiscovery {
                group.addTask { [workingDirectoryURL] in
                    let snapshot = await self.snapshot(for: tool, workingDirectoryURL: workingDirectoryURL)
                    return (tool, snapshot)
                }
            }

            var snapshots: [AIAgentTool: ACPAgentSnapshot] = [:]
            for await (tool, snapshot) in group {
                if let snapshot {
                    snapshots[tool] = snapshot
                }
            }
            return snapshots
        }
    }

    func snapshot(for tool: AIAgentTool, workingDirectoryURL: URL) async -> ACPAgentSnapshot? {
        guard let executable = tool.executableName,
              let acpArguments = tool.acpLaunchArguments else {
            return nil
        }

        return try? await Task.detached(priority: .utility) {
            let transport = try ACPJSONRPCTransport(
                executable: executable,
                arguments: acpArguments,
                currentDirectoryURL: workingDirectoryURL
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
    private var bytesIterator: FileHandle.AsyncBytes.Iterator
    private var bufferedData = Data()
    private var nextRequestID = 1

    init(executable: String, arguments: [String], currentDirectoryURL: URL) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        bytesIterator = stdoutHandle.bytes.makeAsyncIterator()
        stderrDrainer = Task.detached(priority: .background) {
            var iterator = stderrPipe.fileHandleForReading.bytes.makeAsyncIterator()
            while (try? await iterator.next()) != nil {}
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
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let message = try await nextJSONMessage() {
                if let id = message["id"] as? Int, id == requestID {
                    return message
                }
            } else if !process.isRunning {
                break
            }
        }
        throw StackriotError.commandFailed("ACP discovery timed out.")
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
