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

    private static func fallbackPath(includeAppManagedPaths: Bool) -> String {
        standardPATHEntries(includeAppManagedPaths: includeAppManagedPaths).joined(separator: ":")
    }

    static func loginShellPath(includeAppManagedPaths: Bool = true) async -> String {
        if let path = await readLoginShellPath(includeAppManagedPaths: includeAppManagedPaths) {
            return path
        }

        let inheritedPath = ProcessInfo.processInfo.environment["PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let inheritedPath, !inheritedPath.isEmpty {
            return mergePATHEntries(
                primary: inheritedPath,
                fallback: fallbackPath(includeAppManagedPaths: includeAppManagedPaths)
            )
        }

        return fallbackPath(includeAppManagedPaths: includeAppManagedPaths)
    }

    static func resolvedEnvironment(
        additional: [String: String] = [:],
        overrides: [String: String] = [:],
        includeAppManagedPaths: Bool = true
    ) async -> [String: String] {
        ProcessInfo.processInfo.environment
            .merging(["PATH": await loginShellPath(includeAppManagedPaths: includeAppManagedPaths)]) { _, new in new }
            .merging(additional) { _, new in new }
            .merging(overrides) { _, new in new }
    }

    private static func readLoginShellPath(includeAppManagedPaths: Bool) async -> String? {
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
            return path.isEmpty
                ? nil
                : mergePATHEntries(
                    primary: path,
                    fallback: fallbackPath(includeAppManagedPaths: includeAppManagedPaths)
                )
        } catch {
            return nil
        }
    }

    static func standardPATHEntries(
        includeAppManagedPaths: Bool = true,
        homeDirectory: String? = ProcessInfo.processInfo.environment["HOME"]?.nonEmpty
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        var entries = fixedStandardPATHEntries

        if let homeDirectory {
            entries.append((homeDirectory as NSString).appendingPathComponent("bin"))
        }

        if includeAppManagedPaths {
            entries.insert(contentsOf: managedPATHEntries(), at: 0)
        }

        return mergePATHEntries(
            primaryEntries: entries,
            fallbackEntries: []
        )
    }

    static func managedPATHEntries() -> [String] {
        [
            AppPaths.localToolsBinDirectory.path,
            AppPaths.localToolsNPMPrefix.appendingPathComponent("bin", isDirectory: true).path,
            AppPaths.localToolsCursorBinDirectory.path,
        ]
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
