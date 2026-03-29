import Foundation
enum ShellEnvironment {
    private static let fallbackPath = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")

    static func loginShellPath() async -> String {
        if let path = await readLoginShellPath() {
            return path
        }

        let inheritedPath = ProcessInfo.processInfo.environment["PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let inheritedPath, !inheritedPath.isEmpty {
            return mergePATHEntries(primary: inheritedPath, fallback: fallbackPath)
        }

        return fallbackPath
    }

    static func resolvedEnvironment(
        additional: [String: String] = [:],
        overrides: [String: String] = [:]
    ) async -> [String: String] {
        ProcessInfo.processInfo.environment
            .merging(["PATH": await loginShellPath()]) { _, new in new }
            .merging(additional) { _, new in new }
            .merging(overrides) { _, new in new }
    }

    private static func readLoginShellPath() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"]?.nonEmpty ?? "/bin/zsh"

        do {
            let result = try await CommandRunner.runCollected(
                executable: shell,
                arguments: ["-ilc", "printf %s \"$PATH\""]
            )
            guard result.exitCode == 0 else {
                return nil
            }

            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : mergePATHEntries(primary: path, fallback: fallbackPath)
        } catch {
            return nil
        }
    }

    private static func mergePATHEntries(primary: String, fallback: String) -> String {
        var seen: Set<String> = []
        var merged: [String] = []

        for entry in (primary.split(separator: ":") + fallback.split(separator: ":")).map(String.init) {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            merged.append(trimmed)
        }

        return merged.joined(separator: ":")
    }
}
