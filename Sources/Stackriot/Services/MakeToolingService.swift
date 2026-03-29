import Foundation

struct MakeToolingService {
    func discoverTargets(in worktreeURL: URL) -> [String] {
        for fileName in ["GNUmakefile", "Makefile", "makefile"] {
            let makefileURL = worktreeURL.appendingPathComponent(fileName)
            if let contents = try? String(contentsOf: makefileURL, encoding: .utf8) {
                return Self.parseTargets(from: contents)
            }
        }
        return []
    }

    static func parseTargets(from contents: String) -> [String] {
        let lines = contents.components(separatedBy: .newlines)
        let targets = lines.compactMap { line -> String? in
            guard
                !line.hasPrefix("\t"),
                !line.hasPrefix("#"),
                !line.contains("="),
                let colonIndex = line.firstIndex(of: ":")
            else {
                return nil
            }

            let target = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !target.contains("%"), !target.contains(" "), !target.hasPrefix(".") else {
                return nil
            }
            return target
        }
        return Array(Set(targets)).sorted()
    }
}

@MainActor
final class RunConfigurationDiscoveryService {
    private struct CachedDiscovery {
        let fingerprint: ProjectFingerprint
        let configurations: [RunConfiguration]
    }

    private let nodeTooling: NodeToolingService
    private var cache: [String: CachedDiscovery] = [:]

    init(nodeTooling: NodeToolingService = NodeToolingService()) {
        self.nodeTooling = nodeTooling
    }

    func discoverRunConfigurations(in worktreeURL: URL) -> [RunConfiguration] {
        let fingerprint = ProjectFingerprint(rootURL: worktreeURL)
        let cacheKey = worktreeURL.path
        if let cached = cache[cacheKey], cached.fingerprint == fingerprint {
            return cached.configurations
        }

        let providers: [any RunConfigurationProvider] = [
            NativeMakeRunConfigurationProvider(),
            NativeNPMScriptRunConfigurationProvider(nodeTooling: nodeTooling),
            VSCodeRunConfigurationProvider(nodeTooling: nodeTooling),
            CursorRunConfigurationProvider(nodeTooling: nodeTooling),
            JetBrainsRunConfigurationProvider(nodeTooling: nodeTooling),
            XcodeRunConfigurationProvider(),
        ]

        let configurations = normalize(providers.flatMap { $0.discover(in: worktreeURL) })
        cache[cacheKey] = CachedDiscovery(fingerprint: fingerprint, configurations: configurations)
        return configurations
    }

    func makeExecutionDescriptor(
        for configuration: RunConfiguration,
        worktree: WorktreeRecord,
        repositoryID: UUID,
        availableTools: Set<SupportedDevTool>
    ) -> CommandExecutionDescriptor? {
        guard configuration.isDirectlyRunnable, let command = configuration.command?.nonEmpty else {
            return nil
        }

        if configuration.executionBehavior == .openInDevTool,
           let preferredDevTool = configuration.preferredDevTool,
           !availableTools.contains(preferredDevTool) {
            return nil
        }

        let actionKind: ActionKind
        switch configuration.kind {
        case .makeTarget:
            actionKind = .makeTarget
        case .npmScript:
            actionKind = .npmScript
        case .shellCommand, .nodeLaunch, .xcodeScheme, .jetbrainsConfiguration:
            actionKind = .runConfiguration
        }

        let worktreeURL = URL(fileURLWithPath: worktree.path)
        let currentDirectoryURL: URL
        if let workingDirectory = configuration.workingDirectory?.nonEmpty {
            if workingDirectory.hasPrefix("/") {
                currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            } else {
                currentDirectoryURL = worktreeURL.appendingPathComponent(workingDirectory)
            }
        } else {
            currentDirectoryURL = worktreeURL
        }

        return CommandExecutionDescriptor(
            title: configuration.name,
            actionKind: actionKind,
            executable: command,
            arguments: configuration.arguments,
            displayCommandLine: configuration.displayCommandLine,
            currentDirectoryURL: currentDirectoryURL,
            repositoryID: repositoryID,
            worktreeID: worktree.id,
            runtimeRequirement: configuration.runtimeRequirement,
            stdinText: nil,
            environment: configuration.environment
        )
    }

    private func normalize(_ configurations: [RunConfiguration]) -> [RunConfiguration] {
        var seen = Set<String>()
        return configurations
            .filter { configuration in
                seen.insert(configuration.id).inserted
            }
            .sorted { lhs, rhs in
                if sourceSortOrder(lhs) == sourceSortOrder(rhs) {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return sourceSortOrder(lhs) < sourceSortOrder(rhs)
            }
    }

    private func sourceSortOrder(_ configuration: RunConfiguration) -> Int {
        switch configuration.source {
        case .native:
            return 0
        case .vscode:
            return 1
        case .cursor:
            return 2
        case .jetbrains:
            return 3 + (configuration.preferredDevTool?.sortPriority ?? 0)
        case .xcode:
            return 20
        }
    }
}

private protocol RunConfigurationProvider {
    func discover(in worktreeURL: URL) -> [RunConfiguration]
}

private struct ProjectFingerprint: Equatable {
    let signatures: [String: TimeInterval]

    init(rootURL: URL) {
        var signatures: [String: TimeInterval] = [:]

        for relativePath in [
            "GNUmakefile",
            "Makefile",
            "makefile",
            "package.json",
            "pnpm-lock.yaml",
            "yarn.lock",
            ".nvmrc",
            ".node-version",
            ".vscode/launch.json",
            ".cursor/launch.json",
        ] {
            let url = rootURL.appendingPathComponent(relativePath)
            if let signature = Self.signature(for: url) {
                signatures[relativePath] = signature
            }
        }

        for url in Self.enumeratedURLs(in: rootURL) {
            if let signature = Self.signature(for: url) {
                signatures[url.path.replacingOccurrences(of: rootURL.path, with: "")] = signature
            }
        }

        self.signatures = signatures
    }

    private static func enumeratedURLs(in rootURL: URL) -> [URL] {
        let fileManager = FileManager.default
        let rootDepth = rootURL.pathComponents.count
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var urls: [URL] = []
        while let next = enumerator?.nextObject() as? URL {
            let depth = next.pathComponents.count - rootDepth
            if depth > 5 {
                enumerator?.skipDescendants()
                continue
            }

            let lowercasedName = next.lastPathComponent.lowercased()
            if lowercasedName == "node_modules" || lowercasedName == ".git" {
                enumerator?.skipDescendants()
                continue
            }

            if next.pathExtension == "xcscheme" || next.pathExtension == "xml" || next.pathExtension == "xcodeproj" || next.pathExtension == "xcworkspace" {
                urls.append(next)
            }
        }
        return urls
    }

    private static func signature(for url: URL) -> TimeInterval? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]) else {
            return nil
        }
        return values.contentModificationDate?.timeIntervalSinceReferenceDate
    }
}

private struct NativeMakeRunConfigurationProvider: RunConfigurationProvider {
    func discover(in worktreeURL: URL) -> [RunConfiguration] {
        let fileManager = FileManager.default
        for fileName in ["GNUmakefile", "Makefile", "makefile"] {
            let makefileURL = worktreeURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: makefileURL.path) else { continue }
            let targets = MakeToolingService().discoverTargets(in: worktreeURL)
            return targets.map { target in
                RunConfiguration(
                    id: "native-make-\(target)",
                    name: target,
                    source: .native,
                    kind: .makeTarget,
                    runnerType: "make",
                    workingDirectory: worktreeURL.path,
                    command: "make",
                    arguments: [target],
                    rawSourcePath: makefileURL.path
                )
            }
        }
        return []
    }
}

private struct NativeNPMScriptRunConfigurationProvider: RunConfigurationProvider {
    let nodeTooling: NodeToolingService

    func discover(in worktreeURL: URL) -> [RunConfiguration] {
        let packageURL = worktreeURL.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return []
        }

        let packageManager = nodeTooling.packageManager(in: worktreeURL)
        let runtimeRequirement = nodeTooling.runtimeRequirement(for: worktreeURL)
        return nodeTooling.discoverScripts(in: worktreeURL).map { script in
            RunConfiguration(
                id: "native-npm-\(script)",
                name: script,
                source: .native,
                kind: .npmScript,
                runnerType: packageManager.rawValue,
                workingDirectory: worktreeURL.path,
                command: packageManager.rawValue,
                arguments: ["run", script],
                rawSourcePath: packageURL.path,
                runtimeRequirement: runtimeRequirement
            )
        }
    }
}

private struct VSCodeRunConfigurationProvider: RunConfigurationProvider {
    let nodeTooling: NodeToolingService

    func discover(in worktreeURL: URL) -> [RunConfiguration] {
        launchConfigurations(
            from: worktreeURL.appendingPathComponent(".vscode/launch.json"),
            source: .vscode,
            preferredDevTool: .vscode,
            worktreeURL: worktreeURL,
            nodeTooling: nodeTooling
        )
    }
}

private struct CursorRunConfigurationProvider: RunConfigurationProvider {
    let nodeTooling: NodeToolingService

    func discover(in worktreeURL: URL) -> [RunConfiguration] {
        launchConfigurations(
            from: worktreeURL.appendingPathComponent(".cursor/launch.json"),
            source: .cursor,
            preferredDevTool: .cursor,
            worktreeURL: worktreeURL,
            nodeTooling: nodeTooling
        )
    }
}

private struct JetBrainsRunConfigurationProvider: RunConfigurationProvider {
    let nodeTooling: NodeToolingService

    func discover(in worktreeURL: URL) -> [RunConfiguration] {
        let directoryURL = worktreeURL.appendingPathComponent(".idea/runConfigurations", isDirectory: true)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let preferredDevTool = ProjectIndicators(rootURL: worktreeURL).preferredJetBrainsTool
        let runtimeRequirement = nodeTooling.runtimeRequirement(for: worktreeURL)

        return fileURLs
            .filter { $0.pathExtension.lowercased() == "xml" }
            .flatMap { fileURL in
                guard let parsed = JetBrainsRunConfigurationXMLParser().parse(fileURL: fileURL) else {
                    return [RunConfiguration]()
                }
                return parsed.compactMap { configuration in
                    makeRunConfiguration(
                        from: configuration,
                        fileURL: fileURL,
                        worktreeURL: worktreeURL,
                        preferredDevTool: preferredDevTool,
                        runtimeRequirement: runtimeRequirement,
                        packageManager: nodeTooling.packageManager(in: worktreeURL)
                    )
                }
            }
    }

    private func makeRunConfiguration(
        from configuration: JetBrainsParsedConfiguration,
        fileURL: URL,
        worktreeURL: URL,
        preferredDevTool: SupportedDevTool,
        runtimeRequirement: NodeRuntimeRequirement,
        packageManager: PackageManagerKind
    ) -> RunConfiguration? {
        let type = configuration.type.lowercased()
        let options = configuration.options
        let workingDirectory = resolvedWorkingDirectory(from: options, worktreeURL: worktreeURL)

        if type.contains("sh") || type.contains("bash") {
            if let scriptPath = options.value(for: ["SCRIPT_PATH", "script_path"]), scriptPath.nonEmpty != nil {
                let parameters = shellSplit(options.value(for: ["SCRIPT_OPTIONS", "PARAMETERS", "parameters"]) ?? "")
                return RunConfiguration(
                    id: "jetbrains-\(fileURL.lastPathComponent)-\(configuration.name)",
                    name: configuration.name,
                    source: .jetbrains,
                    kind: .jetbrainsConfiguration,
                    runnerType: configuration.type,
                    workingDirectory: workingDirectory.path,
                    command: resolve(pathLike: scriptPath, relativeTo: workingDirectory),
                    arguments: parameters,
                    rawSourcePath: fileURL.path,
                    preferredDevTool: preferredDevTool
                )
            }

            if let scriptText = options.value(for: ["SCRIPT_TEXT", "script_text"]), scriptText.nonEmpty != nil {
                return RunConfiguration(
                    id: "jetbrains-\(fileURL.lastPathComponent)-\(configuration.name)",
                    name: configuration.name,
                    source: .jetbrains,
                    kind: .jetbrainsConfiguration,
                    runnerType: configuration.type,
                    workingDirectory: workingDirectory.path,
                    command: "/bin/sh",
                    arguments: ["-lc", scriptText],
                    rawSourcePath: fileURL.path,
                    preferredDevTool: preferredDevTool
                )
            }
        }

        if type.contains("npm") {
            if let script = options.value(for: ["scripts", "SCRIPT_NAME", "run-script", "script"]), script.nonEmpty != nil {
                return RunConfiguration(
                    id: "jetbrains-\(fileURL.lastPathComponent)-\(configuration.name)",
                    name: configuration.name,
                    source: .jetbrains,
                    kind: .npmScript,
                    runnerType: configuration.type,
                    workingDirectory: workingDirectory.path,
                    command: packageManager.rawValue,
                    arguments: ["run", script],
                    rawSourcePath: fileURL.path,
                    preferredDevTool: preferredDevTool,
                    runtimeRequirement: runtimeRequirement
                )
            }
        }

        if let javascriptFile = options.value(for: ["JavaScriptFile", "javascript_file"]), javascriptFile.nonEmpty != nil {
            let appParameters = shellSplit(options.value(for: ["application-parameters", "APPLICATION_PARAMETERS"]) ?? "")
            let nodeParameters = shellSplit(options.value(for: ["node-parameters", "NODE_OPTIONS"]) ?? "")
            return RunConfiguration(
                id: "jetbrains-\(fileURL.lastPathComponent)-\(configuration.name)",
                name: configuration.name,
                source: .jetbrains,
                kind: .nodeLaunch,
                runnerType: configuration.type,
                workingDirectory: workingDirectory.path,
                command: "node",
                arguments: nodeParameters + [resolve(pathLike: javascriptFile, relativeTo: workingDirectory)] + appParameters,
                isDebugCapable: true,
                rawSourcePath: fileURL.path,
                preferredDevTool: preferredDevTool,
                runtimeRequirement: runtimeRequirement
            )
        }

        return nil
    }

    private func resolvedWorkingDirectory(from options: [String: String], worktreeURL: URL) -> URL {
        if let path = options.value(for: ["WORKING_DIRECTORY", "working_directory", "working-dir"]),
           let resolved = path.nonEmpty {
            return URL(fileURLWithPath: resolve(pathLike: resolved, relativeTo: worktreeURL))
        }
        return worktreeURL
    }
}

private struct XcodeRunConfigurationProvider: RunConfigurationProvider {
    func discover(in worktreeURL: URL) -> [RunConfiguration] {
        sharedSchemeCandidates(in: worktreeURL).compactMap { candidate in
            guard let parsed = XcodeSchemeParser().parse(fileURL: candidate.schemeURL) else {
                return nil
            }
            guard parsed.hasBuildAction || parsed.hasLaunchAction || parsed.hasTestAction else {
                return nil
            }

            let arguments: [String]
            switch candidate.containerURL.pathExtension.lowercased() {
            case "xcworkspace":
                arguments = ["-workspace", candidate.containerURL.path, "-scheme", parsed.name, "build"]
            default:
                arguments = ["-project", candidate.containerURL.path, "-scheme", parsed.name, "build"]
            }

            return RunConfiguration(
                id: "xcode-\(candidate.containerURL.lastPathComponent)-\(parsed.name)",
                name: parsed.name,
                source: .xcode,
                kind: .xcodeScheme,
                runnerType: "xcodebuild",
                workingDirectory: worktreeURL.path,
                command: "xcodebuild",
                arguments: arguments,
                isDebugCapable: parsed.hasLaunchAction,
                rawSourcePath: candidate.schemeURL.path,
                executionBehavior: .buildOnly,
                preferredDevTool: .xcode
            )
        }
    }

    private func sharedSchemeCandidates(in worktreeURL: URL) -> [(containerURL: URL, schemeURL: URL)] {
        let fileManager = FileManager.default
        let rootDepth = worktreeURL.pathComponents.count
        let enumerator = fileManager.enumerator(
            at: worktreeURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var candidates: [(URL, URL)] = []
        while let next = enumerator?.nextObject() as? URL {
            let depth = next.pathComponents.count - rootDepth
            if depth > 4 {
                enumerator?.skipDescendants()
                continue
            }

            let ext = next.pathExtension.lowercased()
            guard ext == "xcodeproj" || ext == "xcworkspace" else { continue }

            let schemesDirectory = next
                .appendingPathComponent("xcshareddata", isDirectory: true)
                .appendingPathComponent("xcschemes", isDirectory: true)
            let schemes = (try? fileManager.contentsOfDirectory(at: schemesDirectory, includingPropertiesForKeys: nil)) ?? []
            candidates.append(contentsOf: schemes
                .filter { $0.pathExtension.lowercased() == "xcscheme" }
                .map { (next, $0) })
            enumerator?.skipDescendants()
        }
        return candidates
    }
}

private func launchConfigurations(
    from launchFileURL: URL,
    source: RunConfigurationSource,
    preferredDevTool: SupportedDevTool,
    worktreeURL: URL,
    nodeTooling: NodeToolingService
) -> [RunConfiguration] {
    guard let rawContents = try? String(contentsOf: launchFileURL, encoding: .utf8) else {
        return []
    }

    let sanitized = removeTrailingCommas(from: stripJSONComments(from: rawContents))
    guard
        let data = sanitized.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let configurations = object["configurations"] as? [[String: Any]]
    else {
        return []
    }

    let runtimeRequirement = nodeTooling.runtimeRequirement(for: worktreeURL)
    return configurations.compactMap { configuration in
        guard (configuration["request"] as? String)?.lowercased() == "launch" else {
            return nil
        }
        guard let name = (configuration["name"] as? String)?.nonEmpty else {
            return nil
        }

        let type = ((configuration["type"] as? String) ?? "process").lowercased()
        let cwd = substituteWorkspaceTokens(in: configuration["cwd"] as? String, worktreeURL: worktreeURL) ?? worktreeURL.path
        let env = (configuration["env"] as? [String: String] ?? [:])
            .reduce(into: [:]) { partialResult, item in
                partialResult[item.key] = substituteWorkspaceTokens(in: item.value, worktreeURL: worktreeURL) ?? item.value
            }
        let args = flattenedArguments(from: configuration["args"])
        let runtimeArgs = flattenedArguments(from: configuration["runtimeArgs"])
        let program = substituteWorkspaceTokens(in: configuration["program"] as? String, worktreeURL: worktreeURL)
        let runtimeExecutable = substituteWorkspaceTokens(in: configuration["runtimeExecutable"] as? String, worktreeURL: worktreeURL)

        let command: String?
        let finalArguments: [String]
        let kind: RunConfigurationKind
        let runtime: NodeRuntimeRequirement?

        if let runtimeExecutable, runtimeExecutable.contains("${") == false {
            command = runtimeExecutable
            finalArguments = runtimeArgs + (program.map { [$0] } ?? []) + args
            kind = type.contains("node") ? .nodeLaunch : .shellCommand
            runtime = type.contains("node") || runtimeExecutable == "node" ? runtimeRequirement : nil
        } else if ["node", "pwa-node", "node-terminal"].contains(type), let program, program.contains("${") == false {
            command = "node"
            finalArguments = runtimeArgs + [program] + args
            kind = .nodeLaunch
            runtime = runtimeRequirement
        } else {
            return nil
        }

        guard let command, command.contains("${") == false else {
            return nil
        }

        return RunConfiguration(
            id: "\(source.rawValue)-\(name)-\(launchFileURL.path)",
            name: name,
            source: source,
            kind: kind,
            runnerType: type,
            workingDirectory: cwd,
            command: command,
            arguments: finalArguments,
            environment: env,
            isDebugCapable: true,
            rawSourcePath: launchFileURL.path,
            preferredDevTool: preferredDevTool,
            runtimeRequirement: runtime
        )
    }
}

private struct JetBrainsParsedConfiguration {
    let name: String
    let type: String
    let options: [String: String]
}

private final class JetBrainsRunConfigurationXMLParser: NSObject, XMLParserDelegate {
    private var parsedConfigurations: [JetBrainsParsedConfiguration] = []
    private var currentName: String?
    private var currentType: String?
    private var currentOptions: [String: String] = [:]

    func parse(fileURL: URL) -> [JetBrainsParsedConfiguration]? {
        guard let parser = XMLParser(contentsOf: fileURL) else {
            return nil
        }
        parsedConfigurations = []
        currentName = nil
        currentType = nil
        currentOptions = [:]
        parser.delegate = self
        return parser.parse() ? parsedConfigurations : nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "configuration":
            currentName = attributeDict["name"]
            currentType = attributeDict["type"]
            currentOptions = [:]
        case "option":
            guard let name = attributeDict["name"], let value = attributeDict["value"] else {
                return
            }
            currentOptions[name] = value
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "configuration",
              let currentName,
              let currentType
        else {
            return
        }
        parsedConfigurations.append(
            JetBrainsParsedConfiguration(name: currentName, type: currentType, options: currentOptions)
        )
        self.currentName = nil
        self.currentType = nil
        currentOptions = [:]
    }
}

private struct XcodeParsedScheme {
    let name: String
    let hasBuildAction: Bool
    let hasLaunchAction: Bool
    let hasTestAction: Bool
}

private final class XcodeSchemeParser: NSObject, XMLParserDelegate {
    private var hasBuildAction = false
    private var hasLaunchAction = false
    private var hasTestAction = false
    private var schemeName = ""

    func parse(fileURL: URL) -> XcodeParsedScheme? {
        guard let parser = XMLParser(contentsOf: fileURL) else {
            return nil
        }
        hasBuildAction = false
        hasLaunchAction = false
        hasTestAction = false
        schemeName = fileURL.deletingPathExtension().lastPathComponent
        parser.delegate = self
        guard parser.parse() else {
            return nil
        }
        return XcodeParsedScheme(
            name: schemeName,
            hasBuildAction: hasBuildAction,
            hasLaunchAction: hasLaunchAction,
            hasTestAction: hasTestAction
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "BuildAction":
            hasBuildAction = true
        case "LaunchAction":
            hasLaunchAction = true
        case "TestAction":
            hasTestAction = true
        default:
            break
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    func value(for candidateKeys: [String]) -> String? {
        for key in candidateKeys {
            if let value = self[key] {
                return value
            }
            if let value = first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                return value
            }
        }
        return nil
    }
}

private func resolve(pathLike value: String, relativeTo directoryURL: URL) -> String {
    let substituted = substituteWorkspaceTokens(in: value, worktreeURL: directoryURL) ?? value
    if substituted.hasPrefix("/") {
        return substituted
    }
    return directoryURL.appendingPathComponent(substituted).path
}

private func substituteWorkspaceTokens(in value: String?, worktreeURL: URL) -> String? {
    guard let value else { return nil }
    return value
        .replacingOccurrences(of: "${workspaceFolder}", with: worktreeURL.path)
        .replacingOccurrences(of: "${workspaceRoot}", with: worktreeURL.path)
        .replacingOccurrences(of: "${workspaceFolderBasename}", with: worktreeURL.lastPathComponent)
        .replacingOccurrences(of: "${PROJECT_DIR}", with: worktreeURL.path)
}

private func flattenedArguments(from value: Any?) -> [String] {
    switch value {
    case let items as [String]:
        return items
    case let item as String:
        return [item]
    default:
        return []
    }
}

private func stripJSONComments(from contents: String) -> String {
    var result = ""
    var iterator = contents.makeIterator()
    var inString = false
    var isEscaped = false

    while let character = iterator.next() {
        if inString {
            result.append(character)
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                inString = false
            }
            continue
        }

        if character == "\"" {
            inString = true
            result.append(character)
            continue
        }

        if character == "/", let next = iterator.next() {
            if next == "/" {
                while let tail = iterator.next(), tail != "\n" {}
                result.append("\n")
                continue
            }
            if next == "*" {
                var previous: Character?
                while let tail = iterator.next() {
                    if previous == "*" && tail == "/" {
                        break
                    }
                    previous = tail
                }
                continue
            }
            result.append(character)
            result.append(next)
            continue
        }

        result.append(character)
    }

    return result
}

private func removeTrailingCommas(from contents: String) -> String {
    contents.replacingOccurrences(
        of: #",\s*([}\]])"#,
        with: "$1",
        options: .regularExpression
    )
}

private func shellSplit(_ command: String) -> [String] {
    var results: [String] = []
    var current = ""
    var quote: Character?

    for character in command {
        if let activeQuote = quote {
            if character == activeQuote {
                quote = nil
            } else {
                current.append(character)
            }
            continue
        }

        switch character {
        case "\"", "'":
            quote = character
        case " ", "\t", "\n":
            selfAppend(&results, current: &current)
        default:
            current.append(character)
        }
    }

    selfAppend(&results, current: &current)
    return results
}

private func selfAppend(_ results: inout [String], current: inout String) {
    if let value = current.nonEmpty {
        results.append(value)
        current = ""
    }
}
