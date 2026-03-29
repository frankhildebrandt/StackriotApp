import Foundation
enum AppPaths {
    static var applicationSupportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return url.appendingPathComponent("Stackriot", isDirectory: true)
    }

    static var nodeRuntimeRoot: URL {
        applicationSupportDirectory.appendingPathComponent("NodeRuntime", isDirectory: true)
    }

    static var nvmDirectory: URL {
        nodeRuntimeRoot.appendingPathComponent("nvm", isDirectory: true)
    }

    static var nodeVersionsRoot: URL {
        nvmDirectory.appendingPathComponent("versions/node", isDirectory: true)
    }

    static var runtimeCacheRoot: URL {
        nodeRuntimeRoot.appendingPathComponent("Caches", isDirectory: true)
    }

    static var npmCacheDirectory: URL {
        runtimeCacheRoot.appendingPathComponent("npm", isDirectory: true)
    }

    static var corepackCacheDirectory: URL {
        runtimeCacheRoot.appendingPathComponent("corepack", isDirectory: true)
    }

    static var runtimeTemporaryDirectory: URL {
        nodeRuntimeRoot.appendingPathComponent("tmp", isDirectory: true)
    }

    static var nodeRuntimeStateFile: URL {
        nodeRuntimeRoot.appendingPathComponent("runtime-state.json", isDirectory: false)
    }

    static var bareRepositoriesRoot: URL {
        applicationSupportDirectory.appendingPathComponent("Repositories", isDirectory: true)
    }

    static var worktreesRoot: URL {
        applicationSupportDirectory.appendingPathComponent("Worktrees", isDirectory: true)
    }

    static var plansDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Plans", isDirectory: true)
    }

    static func planFile(for worktreeID: UUID) -> URL {
        plansDirectory.appendingPathComponent("\(worktreeID.uuidString).md", isDirectory: false)
    }

    static func ensureBaseDirectories() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nodeRuntimeRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nvmDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nodeVersionsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeCacheRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: npmCacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: corepackCacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeTemporaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bareRepositoriesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plansDirectory, withIntermediateDirectories: true)
    }

    static func suggestedRepositoryName(from remoteURL: URL) -> String {
        let lastComponent = remoteURL.deletingPathExtension().lastPathComponent
        return lastComponent.isEmpty ? "repository" : lastComponent
    }

    static func sanitizedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let string = String(scalars)
        let normalized = string.replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "item" : normalized.lowercased()
    }

    static func uniqueDirectory(in root: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let base = sanitizedPathComponent(preferredName)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }
}
