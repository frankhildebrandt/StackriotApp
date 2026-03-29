import Foundation
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
