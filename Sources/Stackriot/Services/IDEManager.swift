import AppKit
import Foundation

struct IDEManager {
    @MainActor
    static func chooseDirectory(
        title: String,
        message: String,
        prompt: String,
        initialDirectory: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }

    func open(_ tool: SupportedDevTool, worktreeURL: URL) async throws {
        guard installationURL(for: tool) != nil else {
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

    func installationURL(for tool: SupportedDevTool) -> URL? {
        if let bundleIdentifier = tool.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }

        return NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/Applications/\(tool.applicationName).app"))
    }
}

struct ProjectIndicators: Equatable, Sendable {
    let hasXcodeProject: Bool
    let hasGoModule: Bool
    let hasGoFiles: Bool
    let hasComposerManifest: Bool
    let hasPHPFiles: Bool
    let hasPackageManifest: Bool
    let hasWebSources: Bool

    init(rootURL: URL) {
        let fileManager = FileManager.default
        hasGoModule = fileManager.fileExists(atPath: rootURL.appendingPathComponent("go.mod").path)
        hasComposerManifest = fileManager.fileExists(atPath: rootURL.appendingPathComponent("composer.json").path)
        hasPackageManifest = fileManager.fileExists(atPath: rootURL.appendingPathComponent("package.json").path)

        var hasXcodeProject = false
        var hasGoFiles = false
        var hasPHPFiles = false
        var hasWebSources = false

        let rootDepth = rootURL.pathComponents.count
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let next = enumerator?.nextObject() as? URL {
            let depth = next.pathComponents.count - rootDepth
            if depth > 4 {
                enumerator?.skipDescendants()
                continue
            }

            let lowercasedName = next.lastPathComponent.lowercased()
            let ext = next.pathExtension.lowercased()
            if ext == "xcodeproj" || ext == "xcworkspace" {
                hasXcodeProject = true
            }
            if ext == "go" {
                hasGoFiles = true
            }
            if ext == "php" {
                hasPHPFiles = true
            }
            if ["js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte"].contains(ext) {
                hasWebSources = true
            }

            if ["node_modules", ".git", ".build", "build", "dist"].contains(lowercasedName) {
                enumerator?.skipDescendants()
            }
        }

        self.hasXcodeProject = hasXcodeProject
        self.hasGoFiles = hasGoFiles
        self.hasPHPFiles = hasPHPFiles
        self.hasWebSources = hasWebSources
    }

    var hasGoProject: Bool {
        hasGoModule || hasGoFiles
    }

    var hasPHPProject: Bool {
        hasComposerManifest || hasPHPFiles
    }

    var hasWebProject: Bool {
        hasPackageManifest || hasWebSources
    }

    var preferredJetBrainsTool: SupportedDevTool {
        if hasGoProject {
            return .goland
        }
        if hasPHPProject {
            return .phpstorm
        }
        if hasWebProject {
            return .webstorm
        }
        return .intellijIdea
    }
}

@MainActor
final class DevToolDiscoveryService {
    private struct CachedToolSet {
        let indicators: ProjectIndicators
        let tools: [SupportedDevTool]
    }

    private var cache: [String: CachedToolSet] = [:]
    private let ideManager = IDEManager()

    func availableTools(in worktreeURL: URL) -> [SupportedDevTool] {
        let cacheKey = worktreeURL.path
        if let cached = cache[cacheKey] {
            return cached.tools
        }

        let indicators = ProjectIndicators(rootURL: worktreeURL)
        let installedTools = Set(SupportedDevTool.allCases.filter(isInstalled(_:)))
        let tools = relevantTools(from: installedTools, for: worktreeURL, indicators: indicators)
        cache[cacheKey] = CachedToolSet(indicators: indicators, tools: tools)
        return tools
    }

    func invalidateCache(for worktreeURL: URL) {
        cache.removeValue(forKey: worktreeURL.path)
    }

    func relevantTools(from installedTools: Set<SupportedDevTool>, for worktreeURL: URL) -> [SupportedDevTool] {
        relevantTools(from: installedTools, for: worktreeURL, indicators: ProjectIndicators(rootURL: worktreeURL))
    }

    func isInstalled(_ tool: SupportedDevTool) -> Bool {
        ideManager.installationURL(for: tool) != nil
    }

    private func relevantTools(
        from installedTools: Set<SupportedDevTool>,
        for worktreeURL: URL,
        indicators: ProjectIndicators
    ) -> [SupportedDevTool] {
        installedTools
            .filter { tool in
                switch tool {
                case .cursor, .vscode, .zed, .intellijIdea:
                    true
                case .xcode:
                    indicators.hasXcodeProject
                case .goland:
                    indicators.hasGoProject
                case .phpstorm:
                    indicators.hasPHPProject
                case .webstorm:
                    indicators.hasWebProject
                }
            }
            .sorted { lhs, rhs in
                if lhs.sortPriority == rhs.sortPriority {
                    return lhs.displayName < rhs.displayName
                }
                return lhs.sortPriority < rhs.sortPriority
            }
    }
}
