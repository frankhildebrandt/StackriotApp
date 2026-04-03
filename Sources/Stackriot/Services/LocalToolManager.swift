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
