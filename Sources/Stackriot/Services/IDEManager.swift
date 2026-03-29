import AppKit
import Foundation

struct IDEManager {
    func open(_ tool: SupportedDevTool, worktreeURL: URL) async throws {
        guard NSWorkspace.shared.fullPath(forApplication: tool.applicationName) != nil else {
            throw StackriotError.devToolUnavailable(tool.displayName)
        }

        let targetURL = preferredOpenTarget(for: tool, in: worktreeURL)
        let result = try await CommandRunner.runCollected(
            executable: "open",
            arguments: ["-a", tool.applicationName, targetURL.path]
        )

        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func openTerminal(path: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "open",
            arguments: ["-a", "Terminal", path.path]
        )

        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func revealInFinder(path: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "open",
            arguments: ["-R", path.path]
        )

        guard result.exitCode == 0 else {
            throw StackriotError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func preferredOpenTarget(for tool: SupportedDevTool, in worktreeURL: URL) -> URL {
        guard tool == .xcode else {
            return worktreeURL
        }

        if let workspace = preferredXcodeContainer(in: worktreeURL, pathExtension: "xcworkspace") {
            return workspace
        }
        if let project = preferredXcodeContainer(in: worktreeURL, pathExtension: "xcodeproj") {
            return project
        }
        return worktreeURL
    }

    private func preferredXcodeContainer(in worktreeURL: URL, pathExtension: String) -> URL? {
        let fileManager = FileManager.default
        let rootDepth = worktreeURL.pathComponents.count
        let enumerator = fileManager.enumerator(
            at: worktreeURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let next = enumerator?.nextObject() as? URL {
            let depth = next.pathComponents.count - rootDepth
            if depth > 3 {
                enumerator?.skipDescendants()
                continue
            }
            if next.pathExtension.lowercased() == pathExtension {
                return next
            }
        }

        return nil
    }
}
