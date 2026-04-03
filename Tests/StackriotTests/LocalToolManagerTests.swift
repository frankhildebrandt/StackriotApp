import Foundation
@testable import Stackriot
import Testing

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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(named name: String, in directory: URL) throws {
        try makeExecutable(at: directory.appendingPathComponent(name))
    }

    private func makeExecutable(at url: URL) throws {
        try AppPaths.ensureBaseDirectories()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
