import Foundation
enum AppPaths {
    static var applicationSupportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return url.appendingPathComponent("Stackriot", isDirectory: true)
    }

    static var nodeRuntimeRoot: URL {
        applicationSupportDirectory.appendingPathComponent("NodeRuntime", isDirectory: true)
    }

    static var nodeRuntimeAliasRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stackriot-node-runtime", isDirectory: true)
    }

    static var nvmDirectory: URL {
        nodeRuntimeRoot.appendingPathComponent("nvm", isDirectory: true)
    }

    static var aliasedNVMDirectory: URL {
        nodeRuntimeAliasRoot.appendingPathComponent("nvm", isDirectory: true)
    }

    static var nodeVersionsRoot: URL {
        nvmDirectory.appendingPathComponent("versions/node", isDirectory: true)
    }

    static var runtimeCacheRoot: URL {
        nodeRuntimeRoot.appendingPathComponent("Caches", isDirectory: true)
    }

    static var aliasedRuntimeCacheRoot: URL {
        nodeRuntimeAliasRoot.appendingPathComponent("Caches", isDirectory: true)
    }

    static var npmCacheDirectory: URL {
        runtimeCacheRoot.appendingPathComponent("npm", isDirectory: true)
    }

    static var aliasedNPMCacheDirectory: URL {
        aliasedRuntimeCacheRoot.appendingPathComponent("npm", isDirectory: true)
    }

    static var corepackCacheDirectory: URL {
        runtimeCacheRoot.appendingPathComponent("corepack", isDirectory: true)
    }

    static var aliasedCorepackCacheDirectory: URL {
        aliasedRuntimeCacheRoot.appendingPathComponent("corepack", isDirectory: true)
    }

    static var runtimeTemporaryDirectory: URL {
        nodeRuntimeRoot.appendingPathComponent("tmp", isDirectory: true)
    }

    static var aliasedRuntimeTemporaryDirectory: URL {
        nodeRuntimeAliasRoot.appendingPathComponent("tmp", isDirectory: true)
    }

    static var nodeRuntimeStateFile: URL {
        nodeRuntimeRoot.appendingPathComponent("runtime-state.json", isDirectory: false)
    }

    static var localToolsRoot: URL {
        applicationSupportDirectory.appendingPathComponent("LocalTools", isDirectory: true)
    }

    static var localToolsBinDirectory: URL {
        localToolsRoot.appendingPathComponent("bin", isDirectory: true)
    }

    static var localToolsNPMPrefix: URL {
        localToolsRoot.appendingPathComponent("npm", isDirectory: true)
    }

    static var localToolsCursorHome: URL {
        localToolsRoot.appendingPathComponent("cursor-home", isDirectory: true)
    }

    static var localToolsCursorBinDirectory: URL {
        localToolsCursorHome.appendingPathComponent(".local/bin", isDirectory: true)
    }

    static var localToolsShimsDirectory: URL {
        localToolsRoot.appendingPathComponent("shims", isDirectory: true)
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

    static var rawLogsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("RawLogs", isDirectory: true)
    }

    static var diagnosticsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    static var performanceDebugArtifactFile: URL {
        diagnosticsDirectory.appendingPathComponent("performance-debug.jsonl", isDirectory: false)
    }

    static var codexPlanArtifactsDirectory: URL {
        agentPlanArtifactsDirectory(for: .codex)
    }

    /// Legacy single-file plan before Intent vs. implementation split; migration copies into `intentFile`.
    static func planFile(for worktreeID: UUID) -> URL {
        plansDirectory.appendingPathComponent("\(worktreeID.uuidString).md", isDirectory: false)
    }

    static func intentFile(for worktreeID: UUID) -> URL {
        plansDirectory.appendingPathComponent("\(worktreeID.uuidString).intent.md", isDirectory: false)
    }

    static func implementationPlanFile(for worktreeID: UUID) -> URL {
        plansDirectory.appendingPathComponent("\(worktreeID.uuidString).plan.md", isDirectory: false)
    }

    static func agentPlanArtifactsDirectory(for tool: AIAgentTool) -> URL {
        let directoryName: String
        switch tool {
        case .codex:
            directoryName = "Codex"
        case .cursorCLI:
            directoryName = "Cursor"
        default:
            directoryName = tool.rawValue
        }
        return plansDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func codexPlanArtifactsDirectory(for worktreeID: UUID) -> URL {
        agentPlanArtifactsDirectory(for: .codex, worktreeID: worktreeID)
    }

    static func agentPlanArtifactsDirectory(for tool: AIAgentTool, worktreeID: UUID) -> URL {
        agentPlanArtifactsDirectory(for: tool).appendingPathComponent(worktreeID.uuidString, isDirectory: true)
    }

    static func ensureBaseDirectories() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nodeRuntimeRoot, withIntermediateDirectories: true)
        try ensureNodeRuntimeAlias(fileManager: fileManager)
        try fileManager.createDirectory(at: runtimeCacheRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: npmCacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: corepackCacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeTemporaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localToolsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localToolsBinDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localToolsNPMPrefix, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localToolsCursorHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localToolsCursorBinDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: localToolsShimsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bareRepositoriesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plansDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rawLogsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexPlanArtifactsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: agentPlanArtifactsDirectory(for: .cursorCLI), withIntermediateDirectories: true)
    }

    private static func ensureNodeRuntimeAlias(fileManager: FileManager) throws {
        let aliasRoot = nodeRuntimeAliasRoot
        if fileManager.fileExists(atPath: aliasRoot.path) {
            let values = try aliasRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                return
            }
            try fileManager.removeItem(at: aliasRoot)
        }
        try fileManager.createSymbolicLink(at: aliasRoot, withDestinationURL: nodeRuntimeRoot)
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
