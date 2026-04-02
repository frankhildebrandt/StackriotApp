import Foundation
enum ShellEnvironment {
    private static let fixedStandardPATHEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private static var fallbackPath: String {
        standardPATHEntries().joined(separator: ":")
    }

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

    static func standardPATHEntries(
        homeDirectory: String? = ProcessInfo.processInfo.environment["HOME"]?.nonEmpty
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        var entries = fixedStandardPATHEntries

        if let homeDirectory {
            entries.append((homeDirectory as NSString).appendingPathComponent("bin"))
        }

        return mergePATHEntries(
            primaryEntries: entries,
            fallbackEntries: []
        )
    }

    private static func mergePATHEntries(primary: String, fallback: String) -> String {
        mergePATHEntries(
            primaryEntries: primary.split(separator: ":").map(String.init),
            fallbackEntries: fallback.split(separator: ":").map(String.init)
        ).joined(separator: ":")
    }

    private static func mergePATHEntries(
        primaryEntries: [String],
        fallbackEntries: [String]
    ) -> [String] {
        var seen: Set<String> = []
        var merged: [String] = []

        for entry in primaryEntries + fallbackEntries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            merged.append(trimmed)
        }

        return merged
    }
}
