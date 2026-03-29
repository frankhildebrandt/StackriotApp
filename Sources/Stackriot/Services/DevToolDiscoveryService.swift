import AppKit
import Foundation

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

    func availableTools(in worktreeURL: URL) -> [SupportedDevTool] {
        let indicators = ProjectIndicators(rootURL: worktreeURL)
        let cacheKey = worktreeURL.path
        if let cached = cache[cacheKey], cached.indicators == indicators {
            return cached.tools
        }

        let installedTools = Set(SupportedDevTool.allCases.filter(isInstalled(_:)))
        let tools = relevantTools(from: installedTools, for: worktreeURL, indicators: indicators)
        cache[cacheKey] = CachedToolSet(indicators: indicators, tools: tools)
        return tools
    }

    func relevantTools(from installedTools: Set<SupportedDevTool>, for worktreeURL: URL) -> [SupportedDevTool] {
        relevantTools(from: installedTools, for: worktreeURL, indicators: ProjectIndicators(rootURL: worktreeURL))
    }

    func isInstalled(_ tool: SupportedDevTool) -> Bool {
        NSWorkspace.shared.fullPath(forApplication: tool.applicationName) != nil
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
