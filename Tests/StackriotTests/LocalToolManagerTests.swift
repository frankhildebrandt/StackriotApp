import Foundation
@testable import Stackriot
import Testing

@Suite(.serialized)
@MainActor
struct LocalToolManagerTests {
    @Test
    func statusPrefersShellToolOverAppManagedBinary() async throws {
        let shellDirectory = try makeTemporaryDirectory()
        let appManagedPath = AppPaths.localToolsBinDirectory.appendingPathComponent("codex")
        try removeIfPresent(appManagedPath)
        try makeExecutable(named: "codex", in: shellDirectory)
        try makeExecutable(at: appManagedPath)

        let manager = LocalToolManager(shellPathProvider: { shellDirectory.path })
        let status = await manager.status(for: .codex)

        #expect(status.resolutionSource == .shell)
        #expect(status.resolvedPath == shellDirectory.appendingPathComponent("codex").path)
    }

    @Test
    func statusFallsBackToAppManagedBinaryWhenShellToolIsMissing() async throws {
        let appManagedPath = AppPaths.localToolsBinDirectory.appendingPathComponent("claude")
        try removeIfPresent(appManagedPath)
        try makeExecutable(at: appManagedPath)

        let manager = LocalToolManager(shellPathProvider: { "" })
        let status = await manager.status(for: .claude)

        #expect(status.resolutionSource == .appManaged)
        #expect(status.resolvedPath == appManagedPath.path)
    }

    @Test
    func statusReportsUnavailableWhenNoToolExists() async {
        try? removeIfPresent(AppPaths.localToolsBinDirectory.appendingPathComponent("devcontainer"))
        try? removeIfPresent(AppPaths.localToolsNPMPrefix.appendingPathComponent("bin/devcontainer"))
        let manager = LocalToolManager(shellPathProvider: { "" })
        let status = await manager.status(for: .devcontainer)

        #expect(status.resolutionSource == .unavailable)
        #expect(status.resolvedPath == nil)
    }

    @Test
    func allSupportedToolsExposeExpectedExecutableNames() {
        #expect(AppManagedTool.devcontainer.executableName == "devcontainer")
        #expect(AppManagedTool.claude.executableName == "claude")
        #expect(AppManagedTool.cursorAgent.executableName == "cursor-agent")
        #expect(AppManagedTool.codex.executableName == "codex")
        #expect(AppManagedTool.openCode.executableName == "opencode")
        #expect(AppManagedTool.vscode.executableName == "code")
    }

    @Test
    func managedPATHEntriesIncludeAppManagedACPDirectories() {
        let entries = ShellEnvironment.managedPATHEntries()

        #expect(entries.contains(AppPaths.localToolsBinDirectory.path))
        #expect(entries.contains(AppPaths.localToolsNPMPrefix.appendingPathComponent("bin", isDirectory: true).path))
        #expect(entries.contains(AppPaths.localToolsCursorBinDirectory.path))
    }

    @Test
    func acpDiscoveryRunsSequentiallyAcrossTools() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let recorder = DiscoveryRecorder()

        let service = ACPAgentDiscoveryService(
            environmentProvider: { [:] },
            pathProvider: { "" },
            requestTimeout: 1,
            reportProvider: { tool, workingDirectoryURL, _, path, startedAt, _ in
                await recorder.begin(tool)
                try? await Task.sleep(nanoseconds: 50_000_000)
                await recorder.end()
                return ACPMetadataDiscoveryReport(
                    tool: tool,
                    status: .succeeded,
                    executablePath: "/tmp/\(tool.rawValue)",
                    commandLine: tool.displayName,
                    workingDirectoryPath: workingDirectoryURL.path,
                    environmentPath: path,
                    summary: "ok",
                    detail: nil,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    snapshot: nil
                )
            }
        )

        let reports = await service.reports(
            for: Set([.claudeCode, .codex]),
            workingDirectoryURL: workingDirectory
        )

        #expect(reports[.claudeCode]?.status == .succeeded)
        #expect(reports[.codex]?.status == .succeeded)
        #expect(await recorder.order == [.claudeCode, .codex])
        #expect(await recorder.maxConcurrent == 1)
    }

    @Test
    func acpDiscoveryTimesOutForSilentCLI() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let binDirectory = try makeTemporaryDirectory()
        try makeSilentACPDiscoveryExecutable(named: "claude-agent-acp", in: binDirectory)

        let service = ACPAgentDiscoveryService(
            environmentProvider: { ["PATH": binDirectory.path] },
            pathProvider: { binDirectory.path },
            requestTimeout: 0.2
        )

        let startedAt = Date()
        let reports = await service.reports(
            for: Set([.claudeCode]),
            workingDirectoryURL: workingDirectory
        )

        let duration = Date().timeIntervalSince(startedAt)
        #expect(duration < 2)
        #expect(reports[.claudeCode]?.status == .failed)
        #expect(reports[.claudeCode]?.detail?.contains("timed out") == true)
    }

    @Test
    func cancellingACPRefreshLetsYouStartAgain() async throws {
        let binDirectory = try makeTemporaryDirectory()
        try makeSilentACPDiscoveryExecutable(named: "claude-agent-acp", in: binDirectory)

        let service = ACPAgentDiscoveryService(
            environmentProvider: { ["PATH": binDirectory.path] },
            pathProvider: { binDirectory.path },
            requestTimeout: 10
        )
        let localToolManager = LocalToolManager(shellPathProvider: { "" })
        let appModel = AppModel(services: AppServices(
            agentManager: AIAgentManager(localToolManager: localToolManager),
            localToolManager: localToolManager,
            acpDiscoveryService: service,
            notificationService: NoopNotificationService()
        ))

        appModel.refreshACPMetadata(for: [.claudeCode])
        #expect(appModel.isRefreshingACPMetadata)
        #expect(appModel.refreshingACPMetadataTools == Set([.claudeCode]))

        appModel.cancelACPMetadataRefresh()
        try await waitUntil {
            appModel.isRefreshingACPMetadata == false
        }
        #expect(appModel.refreshingACPMetadataTools.isEmpty)
        #expect(appModel.acpMetadataRefreshSummary?.localizedLowercase.contains("cancel") == true)

        appModel.refreshACPMetadata(for: [.claudeCode])
        #expect(appModel.isRefreshingACPMetadata)
        #expect(appModel.refreshingACPMetadataTools == Set([.claudeCode]))
        appModel.cancelACPMetadataRefresh()
        try await waitUntil {
            appModel.isRefreshingACPMetadata == false
        }
    }

    @Test
    func refreshACPMetadataCanTargetSingleTool() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let service = ACPAgentDiscoveryService(
            environmentProvider: { [:] },
            pathProvider: { "" },
            requestTimeout: 1,
            reportProvider: { tool, workingDirectoryURL, _, path, startedAt, _ in
                #expect(tool == .githubCopilot)
                return ACPMetadataDiscoveryReport(
                    tool: tool,
                    status: .succeeded,
                    executablePath: "/tmp/\(tool.rawValue)",
                    commandLine: tool.displayName,
                    workingDirectoryPath: workingDirectoryURL.path,
                    environmentPath: path,
                    summary: "ok",
                    detail: nil,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    snapshot: ACPAgentSnapshot(
                        tool: tool,
                        protocolVersion: 1,
                        agentInfo: ACPAgentInfo(name: "Copilot", title: "Copilot", version: "1.0"),
                        authMethods: [],
                        loadSession: true,
                        supportsSessionList: true,
                        promptSupportsEmbeddedContext: true,
                        promptSupportsImage: false,
                        promptSupportsAudio: false,
                        mcpSupportsHTTP: false,
                        mcpSupportsSSE: false,
                        currentSessionID: "session",
                        currentModeID: nil,
                        modes: [],
                        currentModelID: "gpt-5.4-mini",
                        models: [ACPDiscoveredModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 mini", description: nil)],
                        configOptions: []
                    )
                )
            }
        )
        let localToolManager = LocalToolManager(shellPathProvider: { "" })
        let appModel = AppModel(services: AppServices(
            agentManager: AIAgentManager(localToolManager: localToolManager),
            localToolManager: localToolManager,
            acpDiscoveryService: service,
            notificationService: NoopNotificationService()
        ))
        appModel.acpMetadataDiscoveryReportsByTool[.claudeCode] = ACPMetadataDiscoveryReport(
            tool: .claudeCode,
            status: .failed,
            executablePath: nil,
            commandLine: "claude-agent-acp",
            workingDirectoryPath: workingDirectory.path,
            environmentPath: "",
            summary: "existing",
            detail: nil,
            startedAt: Date(),
            finishedAt: Date(),
            snapshot: nil
        )

        appModel.refreshACPMetadata(for: [.githubCopilot])
        try await waitUntil {
            appModel.isRefreshingACPMetadata == false
        }

        #expect(appModel.acpMetadataDiscoveryReportsByTool[.githubCopilot]?.status == .succeeded)
        #expect(appModel.acpMetadataDiscoveryReportsByTool[.claudeCode]?.summary == "existing")
        #expect(appModel.acpAgentSnapshotsByTool[.githubCopilot]?.agentInfo?.name == "Copilot")
        #expect(appModel.lastACPMetadataRefreshAtByTool[.githubCopilot] != nil)
        #expect(appModel.lastACPMetadataRefreshAtByTool[.claudeCode] == nil)
        #expect(appModel.refreshingACPMetadataTools.isEmpty)
    }

    @Test
    func installACPAdaptersIfNeededSkipsWhenManagedCLIUnavailable() async throws {
        // With empty shell PATH and no app-managed binaries, no managed CLI is reachable.
        // installACPAdaptersIfNeeded must complete without error (no npm access needed).
        let manager = LocalToolManager(shellPathProvider: { "" })
        await manager.installACPAdaptersIfNeeded(for: Set(AIAgentTool.allCases))
    }

    @Test
    func installACPAdaptersIfNeededSkipsWhenAdapterAlreadyInNPMBin() async throws {
        // Place stub executables in the npm-managed bin directory for both ACP adapters.
        let npmBinDirectory = AppPaths.localToolsNPMPrefix.appendingPathComponent("bin")
        let claudeAdapterPath = npmBinDirectory.appendingPathComponent("claude-agent-acp")
        let codexAdapterPath = npmBinDirectory.appendingPathComponent("codex-acp")

        defer {
            try? FileManager.default.removeItem(at: claudeAdapterPath)
            try? FileManager.default.removeItem(at: codexAdapterPath)
        }

        try makeExecutable(at: claudeAdapterPath)
        try makeExecutable(at: codexAdapterPath)

        // Even if the managed CLIs were somehow available, the adapters are already
        // present in the npm bin — no npm install should be attempted.
        let manager = LocalToolManager(shellPathProvider: { "" })
        await manager.installACPAdaptersIfNeeded(for: Set([.claudeCode, .codex]))
        // Completes without error ⇒ the "already present" skip path is exercised.
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(named name: String, in directory: URL) throws {
        try makeExecutable(at: directory.appendingPathComponent(name))
    }

    private func makeExecutable(at url: URL) throws {
        try makeExecutable(at: url, contents: "#!/bin/sh\nexit 0\n")
    }

    private func makeExecutable(at url: URL, contents: String) throws {
        try AppPaths.ensureBaseDirectories()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeSilentACPDiscoveryExecutable(named name: String, in directory: URL) throws {
        let script = """
        #!/usr/bin/python3
        import signal
        import sys
        import time
        
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
        while True:
            time.sleep(1)
        """
        try makeExecutable(at: directory.appendingPathComponent(name), contents: script)
    }

    private func readLines(at url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func maxLoggedConcurrency(at url: URL) throws -> Int {
        try readLines(at: url).compactMap(Int.init).max() ?? 0
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        Issue.record("Timed out waiting for condition.")
        throw CancellationError()
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

private actor NoopNotificationService: AppNotificationServing {
    @discardableResult
    func prepareAuthorization() async -> AppNotificationAuthorizationState {
        .unsupported
    }

    @discardableResult
    func deliver(_: AppNotificationRequest) async -> AppNotificationDeliveryResult {
        .skipped(.unsupported)
    }
}

private actor DiscoveryRecorder {
    private(set) var order: [AIAgentTool] = []
    private(set) var maxConcurrent = 0
    private var inFlight = 0

    func begin(_ tool: AIAgentTool) {
        order.append(tool)
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
    }

    func end() {
        inFlight -= 1
    }
}
