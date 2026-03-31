import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Stackriot

struct StackriotTests {
    @Test
    func gitWorktreeListParserExtractsBranchesAndSkipsBare() {
        let sample = """
        worktree /path/bare.git
        bare

        worktree /path/default-branch
        HEAD abcdef1234567890abcdef1234567890abcdef12
        branch refs/heads/main

        """
        let entries = GitWorktreeListParser.entries(fromPorcelain: sample)
        #expect(entries.count == 2)
        #expect(entries[0].isBare)
        #expect(entries[0].branchShortName == nil)
        #expect(entries[0].path == "/path/bare.git")
        #expect(!entries[1].isBare)
        #expect(entries[1].branchShortName == "main")
        #expect(entries[1].path == "/path/default-branch")
    }

    @Test
    func gitWorktreeHumanReadableListFindsBranchPaths() {
        let sample = """
        /repos/sample.git               (bare)
        /Users/dev/Worktrees/sample/default-branch    abcd1234 [main]
        """
        let paths = GitWorktreeListParser.pathsFromHumanReadableWorktreeList(sample, defaultBranch: "main")
        #expect(paths == ["/Users/dev/Worktrees/sample/default-branch"])
        #expect(GitWorktreeListParser.pathsFromHumanReadableWorktreeList(sample, defaultBranch: "develop").isEmpty)
    }

    @Test
    func sanitizedPathComponentNormalizesNames() {
        #expect(AppPaths.sanitizedPathComponent("Feature/ABC 123") == "feature-abc-123")
    }

    @Test
    func canonicalRemoteURLNormalizesGitLocations() {
        #expect(RepositoryManager.canonicalRemoteURL(from: "https://GitHub.com/OpenAI/example.git") == "https://github.com/OpenAI/example")
        #expect(RepositoryManager.canonicalRemoteURL(from: "git@GitHub.com:OpenAI/example.git") == "git@github.com:/OpenAI/example")
    }

    @Test
    func makeTargetParserExtractsConcreteTargets() {
        let contents = """
        .PHONY: build test
        build:
        \t@swift build
        test:
        \t@swift test
        SOME_VAR := value
        %.generated:
        """

        let targets = MakeToolingService.parseTargets(from: contents)
        #expect(targets == ["build", "test"])
    }

    @Test
    func nodeScriptsAreDiscoveredFromPackageManifest() throws {
        let root = try temporaryDirectory(named: "node-scripts")
        let package = root.appendingPathComponent("package.json")
        try """
        {
          "scripts": {
            "dev": "vite",
            "test": "vitest"
          }
        }
        """.write(to: package, atomically: true, encoding: .utf8)

        let scripts = NodeToolingService().discoverScripts(in: root)
        #expect(scripts == ["dev", "test"])
    }

    @Test
    func appManagedNodePathsStayInsideApplicationSupport() {
        let supportRoot = AppPaths.applicationSupportDirectory.path
        #expect(AppPaths.nodeRuntimeRoot.path.hasPrefix(supportRoot))
        #expect(AppPaths.nvmDirectory.path.hasPrefix(supportRoot))
        #expect(AppPaths.nodeVersionsRoot.path.hasPrefix(supportRoot))
        #expect(AppPaths.npmCacheDirectory.path.hasPrefix(supportRoot))
        #expect(AppPaths.corepackCacheDirectory.path.hasPrefix(supportRoot))
        #expect(AppPaths.runtimeTemporaryDirectory.path.hasPrefix(supportRoot))
        #expect(AppPaths.rawLogsDirectory.path.hasPrefix(supportRoot))
    }

    @Test
    func nodeVersionRequirementPrefersPackageEngines() throws {
        let root = try temporaryDirectory(named: "node-engines")
        try """
        {
          "engines": {
            "node": "20"
          }
        }
        """.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "18\n".write(to: root.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)

        let requirement = NodeToolingService().runtimeRequirement(for: root, defaultVersionSpec: "lts/*")
        #expect(requirement.nodeVersionSpec == "20")
        #expect(requirement.versionSource == .packageEngines)
    }

    @Test
    func nodeVersionRequirementFallsBackToNvmrc() throws {
        let root = try temporaryDirectory(named: "node-nvmrc")
        try "18.19.0\n".write(to: root.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)

        let requirement = NodeToolingService().runtimeRequirement(for: root, defaultVersionSpec: "lts/*")
        #expect(requirement.nodeVersionSpec == "18.19.0")
        #expect(requirement.versionSource == .nvmrc)
    }

    @Test
    func nodeVersionRequirementFallsBackToDefaultLTS() throws {
        let root = try temporaryDirectory(named: "node-default")

        let requirement = NodeToolingService().runtimeRequirement(for: root, defaultVersionSpec: "lts/*")
        #expect(requirement.nodeVersionSpec == "lts/*")
        #expect(requirement.versionSource == .defaultLTS)
    }

    @Test
    func packageManagerSelectionUsesKnownLockfiles() throws {
        let tooling = NodeToolingService()

        let pnpmRoot = try temporaryDirectory(named: "pnpm")
        FileManager.default.createFile(atPath: pnpmRoot.appendingPathComponent("pnpm-lock.yaml").path, contents: Data())
        #expect(tooling.packageManager(in: pnpmRoot) == .pnpm)

        let yarnRoot = try temporaryDirectory(named: "yarn")
        FileManager.default.createFile(atPath: yarnRoot.appendingPathComponent("yarn.lock").path, contents: Data())
        #expect(tooling.packageManager(in: yarnRoot) == .yarn)

        let npmRoot = try temporaryDirectory(named: "npm")
        #expect(tooling.packageManager(in: npmRoot) == .npm)
    }

    @Test
    func aiAgentPromptCommandsUseDocumentedAutomationModes() {
        let path = "/tmp/example repo"
        let prompt = "Fix failing tests"

        let claude = AIAgentTool.claudeCode.launchCommandWithPrompt(prompt, in: path)
        #expect(claude.contains("claude -p --dangerously-skip-permissions --output-format stream-json"))
        #expect(claude.contains(prompt.shellEscaped))

        let codex = AIAgentTool.codex.launchCommandWithPrompt(prompt, in: path)
        #expect(codex.contains("codex exec --full-auto --json --color never"))
        #expect(codex.contains(prompt.shellEscaped))

        let copilot = AIAgentTool.githubCopilot.launchCommandWithPrompt(prompt, in: path)
        #expect(copilot.contains("copilot -p"))
        #expect(copilot.contains("--allow-all-tools --output-format json"))
        #expect(copilot.contains(prompt.shellEscaped))
        #expect(!copilot.contains("--model"))

        let copilotExplicitModel = AIAgentTool.githubCopilot.launchCommandWithPrompt(
            prompt,
            in: path,
            options: AgentLaunchOptions(copilotModelOverride: "gpt-5.4")
        )
        #expect(copilotExplicitModel.contains("--model"))
        #expect(copilotExplicitModel.contains("'gpt-5.4'"))

        let cursor = AIAgentTool.cursorCLI.launchCommandWithPrompt(prompt, in: path)
        #expect(cursor.contains("cursor-agent --print --output-format stream-json --stream-partial-output --trust --force"))
        #expect(cursor.contains(prompt.shellEscaped))
    }

    @Test
    func shellEnvironmentUsesLoginPathUnlessOverridden() async {
        let loginPath = await ShellEnvironment.loginShellPath()

        let inherited = await ShellEnvironment.resolvedEnvironment()
        #expect(inherited["PATH"] == loginPath)

        let overridden = await ShellEnvironment.resolvedEnvironment(
            additional: ["TERM_PROGRAM": "Stackriot"],
            overrides: ["PATH": "/custom/bin", "TERM": "xterm-256color"]
        )
        #expect(overridden["PATH"] == "/custom/bin")
        #expect(overridden["TERM_PROGRAM"] == "Stackriot")
        #expect(overridden["TERM"] == "xterm-256color")
    }

    @Test
    func generatedCommitMessageUsesFeatureSubjectAndBulletBody() {
        let message = GeneratedCommitMessage(
            summaryTitle: "Add commit action to AI agent summary",
            summaryText: """
            Added a commit button directly to the AI summary view.
            Displayed the current diff alongside the summary for quick review.
            """
        )

        #expect(message?.subject == "Feature: Add commit action to AI agent summary")
        #expect(message?.bodyItems == [
            "Added a commit button directly to the AI summary view",
            "Displayed the current diff alongside the summary for quick review"
        ])
    }

    @Test
    func generatedCommitMessageDropsGenericRunMetadataAndDetectsFixes() {
        let message = GeneratedCommitMessage(
            summaryTitle: "Agentlauf abgeschlossen",
            summaryText: """
            Der Run `Codex` wurde mit Exit-Code 0 beendet.
            Fixed the summary card so changelog rendering no longer disappears after reload.
            Relevante Auszuege: Fixed the summary card so changelog rendering no longer disappears after reload.
            """
        )

        #expect(message?.subject == "Fix: Fixed the summary card so changelog rendering no longer disappears")
        #expect(message?.bodyItems == [])
    }

    @Test
    func embeddedBrowserUsesModernSafariUserAgentForSupportedSystems() {
        let sonomaUserAgent = EmbeddedBrowserSessionStore.preferredSafariUserAgent(operatingSystemMajorVersion: 14)
        #expect(sonomaUserAgent.contains("Version/17.6"))
        #expect(sonomaUserAgent.contains("Safari/605.1.15"))
        #expect(!sonomaUserAgent.contains("Stackriot"))

        let sequoiaUserAgent = EmbeddedBrowserSessionStore.preferredSafariUserAgent(operatingSystemMajorVersion: 15)
        #expect(sequoiaUserAgent.contains("Version/18.4"))
        #expect(sequoiaUserAgent.contains("Safari/605.1.15"))
    }

    @Test
    func nodeVersionResolverSupportsMinimumComparatorRanges() {
        let resolver = NodeVersionSpecResolver()
        let resolved = resolver.resolveInstallableSpec(
            for: ">=22.12.0",
            availableVersions: ["v22.11.0", "v22.12.0", "v22.13.1", "v23.0.0"]
        )
        #expect(resolved == "v23.0.0")
    }

    @Test
    func nodeVersionResolverSupportsCompoundRanges() {
        let resolver = NodeVersionSpecResolver()
        let resolved = resolver.resolveInstallableSpec(
            for: ">=22.12.0 <23",
            availableVersions: ["v22.11.0", "v22.12.0", "v22.13.1", "v23.0.0"]
        )
        #expect(resolved == "v22.13.1")
    }

    @Test
    func managedNodeRuntimePreparesEnvironmentInsideAppPaths() async throws {
        let manager = NodeRuntimeManager()
        let root = try temporaryDirectory(named: "managed-runtime")
        let descriptor = CommandExecutionDescriptor(
            title: "npm install",
            actionKind: .installDependencies,
            executable: "npm",
            arguments: ["--version"],
            displayCommandLine: nil,
            currentDirectoryURL: root,
            repositoryID: UUID(),
            worktreeID: nil,
            runtimeRequirement: NodeRuntimeRequirement(
                packageManager: .npm,
                nodeVersionSpec: AppPreferences.nodeDefaultVersionSpec,
                versionSource: .defaultLTS
            ),
            stdinText: nil
        )

        let prepared = try await manager.prepareExecution(for: descriptor)
        #expect(prepared.environment["NVM_DIR"] == AppPaths.nvmDirectory.path)
        #expect(prepared.environment["NPM_CONFIG_CACHE"] == AppPaths.npmCacheDirectory.path)
        #expect(prepared.environment["npm_config_cache"] == AppPaths.npmCacheDirectory.path)
        #expect(prepared.executable.hasPrefix(AppPaths.applicationSupportDirectory.path))

        let nodePath = URL(fileURLWithPath: prepared.environment["NVM_BIN"] ?? "")
            .appendingPathComponent("node")
            .path
        let result = try await CommandRunner.runCollected(
            executable: nodePath,
            arguments: ["--version"],
            environment: prepared.environment
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).hasPrefix("v"))
    }

    @Test
    func managedNodeRuntimeSerializesParallelPreparation() async throws {
        let manager = NodeRuntimeManager()
        let root = try temporaryDirectory(named: "parallel-runtime")
        let descriptor = CommandExecutionDescriptor(
            title: "npm install",
            actionKind: .installDependencies,
            executable: "npm",
            arguments: ["install"],
            displayCommandLine: nil,
            currentDirectoryURL: root,
            repositoryID: UUID(),
            worktreeID: nil,
            runtimeRequirement: NodeRuntimeRequirement(
                packageManager: .npm,
                nodeVersionSpec: AppPreferences.nodeDefaultVersionSpec,
                versionSource: .defaultLTS
            ),
            stdinText: nil
        )

        let results = try await withThrowingTaskGroup(of: PreparedCommandExecution.self) { group in
            group.addTask { try await manager.prepareExecution(for: descriptor) }
            group.addTask { try await manager.prepareExecution(for: descriptor) }

            var prepared: [PreparedCommandExecution] = []
            for try await value in group {
                prepared.append(value)
            }
            return prepared
        }

        #expect(results.count == 2)
        #expect(Set(results.map { $0.executable }).count == 1)
        #expect(Set(results.compactMap { $0.environment["NVM_BIN"] }).count == 1)
    }

    @Test
    func terminalTabBookkeepingTracksVisibilityPerWorktree() {
        let worktreeOne = UUID()
        let worktreeTwo = UUID()
        let runOne = UUID()
        let runTwo = UUID()
        let runThree = UUID()
        var tabs = TerminalTabBookkeeping()

        tabs.activate(runID: runOne, worktreeID: worktreeOne, viewedAt: Date(timeIntervalSince1970: 10))
        tabs.activate(runID: runTwo, worktreeID: worktreeOne, viewedAt: Date(timeIntervalSince1970: 20))
        tabs.activate(runID: runThree, worktreeID: worktreeTwo, viewedAt: Date(timeIntervalSince1970: 30))

        #expect(tabs.visibleRunIDs(for: worktreeOne) == [runTwo, runOne])
        #expect(tabs.visibleRunIDs(for: worktreeTwo) == [runThree])
        #expect(tabs.selectedVisibleRunID(for: worktreeOne) == runTwo)

        tabs.hide(runID: runTwo)

        #expect(tabs.visibleRunIDs(for: worktreeOne) == [runOne])
        #expect(tabs.selectedVisibleRunID(for: worktreeOne) == runOne)
    }

    @Test
    func terminalTabBookkeepingRestoresClosedTabWhenReactivated() {
        let worktreeID = UUID()
        let olderRun = UUID()
        let newerRun = UUID()
        var tabs = TerminalTabBookkeeping()

        tabs.activate(runID: olderRun, worktreeID: worktreeID, viewedAt: Date(timeIntervalSince1970: 10))
        tabs.activate(runID: newerRun, worktreeID: worktreeID, viewedAt: Date(timeIntervalSince1970: 20))
        tabs.hide(runID: newerRun)
        tabs.activate(runID: newerRun, worktreeID: worktreeID, viewedAt: Date(timeIntervalSince1970: 30))

        #expect(tabs.visibleRunIDs(for: worktreeID) == [newerRun, olderRun])
        #expect(tabs.selectedVisibleRunID(for: worktreeID) == newerRun)
    }

    @Test
    func terminalTabBookkeepingKeepsVisibleOrderWhenSelectingExistingTab() {
        let worktreeID = UUID()
        let firstRun = UUID()
        let secondRun = UUID()
        var tabs = TerminalTabBookkeeping()

        tabs.activate(runID: firstRun, worktreeID: worktreeID, viewedAt: Date(timeIntervalSince1970: 10))
        tabs.activate(runID: secondRun, worktreeID: worktreeID, viewedAt: Date(timeIntervalSince1970: 20))
        tabs.activate(runID: firstRun, worktreeID: worktreeID, viewedAt: Date(timeIntervalSince1970: 30))

        #expect(tabs.visibleRunIDs(for: worktreeID) == [secondRun, firstRun])
        #expect(tabs.selectedVisibleRunID(for: worktreeID) == firstRun)
    }

    @Test
    @MainActor
    func ensureSelectedWorktreeActivatesSpecialTabForInitialSelection() {
        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        let repository = ManagedRepository(
            displayName: "Stackriot",
            bareRepositoryPath: "/tmp/repo.git",
            defaultBranch: "main"
        )
        let defaultWorktree = WorktreeRecord(
            branchName: "main",
            isDefaultBranchWorkspace: true,
            path: "/tmp/main",
            repository: repository
        )
        let featureWorktree = WorktreeRecord(
            branchName: "feature/plan-default",
            path: "/tmp/feature",
            repository: repository
        )
        repository.worktrees = [featureWorktree, defaultWorktree]

        appModel.ensureSelectedWorktree(in: repository)

        #expect(appModel.selectedWorktreeID(for: repository) == defaultWorktree.id)
        #expect(appModel.isPlanTabSelected(for: defaultWorktree))
    }

    @Test
    @MainActor
    func selectWorktreeActivatesSpecialTabForNonDefaultWorktree() {
        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        let repository = ManagedRepository(
            displayName: "Stackriot",
            bareRepositoryPath: "/tmp/repo.git",
            defaultBranch: "main"
        )
        let defaultWorktree = WorktreeRecord(
            branchName: "main",
            isDefaultBranchWorkspace: true,
            path: "/tmp/main",
            repository: repository
        )
        let featureWorktree = WorktreeRecord(
            branchName: "feature/plan-default",
            path: "/tmp/feature",
            repository: repository
        )
        repository.worktrees = [defaultWorktree, featureWorktree]

        appModel.selectWorktree(featureWorktree, in: repository)

        #expect(appModel.selectedWorktreeID(for: repository) == featureWorktree.id)
        #expect(appModel.isPlanTabSelected(for: featureWorktree))
        #expect(!appModel.isPlanTabSelected(for: defaultWorktree))
    }

    @Test
    @MainActor
    func worktreeOrderingPlacesIdeaTreesBetweenPinnedAndRegular() {
        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        let repository = ManagedRepository(
            displayName: "Stackriot",
            bareRepositoryPath: "/tmp/repo.git",
            defaultBranch: "main"
        )
        let defaultWorktree = WorktreeRecord(
            branchName: "main",
            isDefaultBranchWorkspace: true,
            path: "/tmp/main",
            createdAt: Date(timeIntervalSince1970: 10),
            repository: repository
        )
        let pinnedWorktree = WorktreeRecord(
            branchName: "feature/pinned",
            isPinned: true,
            path: "/tmp/pinned",
            createdAt: Date(timeIntervalSince1970: 20),
            repository: repository
        )
        let ideaTree = WorktreeRecord(
            branchName: "feature/idea",
            kind: .idea,
            sourceBranch: "main",
            createdAt: Date(timeIntervalSince1970: 25),
            repository: repository
        )
        let regularWorktree = WorktreeRecord(
            branchName: "feature/newer",
            path: "/tmp/regular",
            createdAt: Date(timeIntervalSince1970: 30),
            repository: repository
        )
        repository.worktrees = [regularWorktree, ideaTree, pinnedWorktree, defaultWorktree]

        let sorted = appModel.worktrees(for: repository)
        let sortedIDs = sorted.map(\.id)
        let expectedIDs = [defaultWorktree.id, pinnedWorktree.id, ideaTree.id, regularWorktree.id]

        #expect(sortedIDs == expectedIDs)
    }

    @Test
    func worktreeRecordDefaultsAndStoresPinAndCardColor() {
        let worktree = WorktreeRecord(
            branchName: "feature/colors",
            path: "/tmp/worktree-colors"
        )

        #expect(!worktree.isPinned)
        #expect(worktree.cardColor == .none)
        #expect(worktree.isPinnedRaw == nil)
        #expect(worktree.cardColorRaw == nil)

        worktree.isPinned = true
        worktree.cardColor = .purple

        #expect(worktree.isPinned)
        #expect(worktree.isPinnedRaw == true)
        #expect(worktree.cardColor == .purple)
        #expect(worktree.cardColorRaw == WorktreeCardColor.purple.rawValue)

        worktree.cardColor = .none
        #expect(worktree.cardColorRaw == nil)
    }

    @Test
    func worktreeLifecycleAllowsSyncForActiveAndMergedBranches() {
        let worktree = WorktreeRecord(
            branchName: "feature/sync-lifecycle",
            path: "/tmp/worktree-sync-lifecycle"
        )

        #expect(worktree.allowsSyncFromDefaultBranch)

        worktree.lifecycleState = .merged
        #expect(worktree.allowsSyncFromDefaultBranch)

        worktree.lifecycleState = .integrating
        #expect(!worktree.allowsSyncFromDefaultBranch)
    }

    @Test
    func backgroundNodeRefreshUpdatesStatus() async {
        let manager = NodeRuntimeManager()
        await manager.refreshDefaultRuntimeIfNeeded(force: true)
        let status = await manager.statusSnapshot()

        #expect(status.lastUpdatedAt != nil)
        #expect(!status.runtimeRootPath.isEmpty)
        #expect(!status.npmCachePath.isEmpty)
        #expect(status.bootstrapState == "Ready" || status.bootstrapState == "Error")
    }

    @Test
    func makeTargetsAreDiscoveredFromCommonMakefileNames() throws {
        let root = try temporaryDirectory(named: "make-targets")
        let makefile = root.appendingPathComponent("GNUmakefile")
        try """
        build:
        \t@swift build
        """.write(to: makefile, atomically: true, encoding: .utf8)

        let targets = MakeToolingService().discoverTargets(in: root)
        #expect(targets == ["build"])
    }

    @Test
    func repositoryCloneRefreshPublishAndDeleteWorkLocally() async throws {
        let remoteOne = try await createSeededRemote(named: "origin")
        let remoteTwo = try await createSeededRemote(named: "upstream")

        let cloneInfo = try await RepositoryManager().cloneBareRepository(remoteURL: remoteOne.remote, preferredName: "Sample")
        #expect(FileManager.default.fileExists(atPath: cloneInfo.bareRepositoryPath.path))
        #expect(cloneInfo.defaultBranch == "main")

        try await RepositoryManager().addRemote(
            name: "upstream",
            url: remoteTwo.remote.path,
            bareRepositoryPath: cloneInfo.bareRepositoryPath
        )

        let refresh = await RepositoryManager().refreshRepository(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            remotes: [
                RemoteExecutionContext(name: "origin", url: remoteOne.remote.path, fetchEnabled: true, privateKeyRef: nil),
                RemoteExecutionContext(name: "upstream", url: remoteTwo.remote.path, fetchEnabled: true, privateKeyRef: nil),
            ],
            defaultRemoteName: "origin"
        )
        #expect(refresh.status == .ready)
        #expect(refresh.fetchedAt != nil)

        let disabledRefresh = await RepositoryManager().refreshRepository(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            remotes: [
                RemoteExecutionContext(name: "origin", url: remoteOne.remote.path, fetchEnabled: true, privateKeyRef: nil),
                RemoteExecutionContext(name: "broken", url: "/definitely/missing.git", fetchEnabled: false, privateKeyRef: nil),
            ],
            defaultRemoteName: "origin"
        )
        #expect(disabledRefresh.status == .ready)

        let worktreeInfo = try await WorktreeManager().createWorktree(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            branchName: "feature/tests",
            sourceBranch: cloneInfo.defaultBranch
        )

        #expect(FileManager.default.fileExists(atPath: worktreeInfo.path.path))
        try "more".write(to: worktreeInfo.path.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        try await runGit(["-C", worktreeInfo.path.path, "add", "."], currentDirectoryURL: worktreeInfo.path)
        try await runGit(["-C", worktreeInfo.path.path, "config", "user.email", "tests@example.com"], currentDirectoryURL: worktreeInfo.path)
        try await runGit(["-C", worktreeInfo.path.path, "config", "user.name", "Stackriot Tests"], currentDirectoryURL: worktreeInfo.path)
        try await runGit(["-C", worktreeInfo.path.path, "config", "commit.gpgsign", "false"], currentDirectoryURL: worktreeInfo.path)
        try await runGit(["-C", worktreeInfo.path.path, "commit", "-m", "Publish"], currentDirectoryURL: worktreeInfo.path)

        let publishedBranch = try await RepositoryManager().publishCurrentBranch(
            worktreePath: worktreeInfo.path,
            remote: RemoteExecutionContext(name: "origin", url: remoteOne.remote.path, fetchEnabled: true, privateKeyRef: nil)
        )
        #expect(publishedBranch == "feature/tests")

        let branchCheck = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", remoteOne.remote.path, "show-ref", "--verify", "--quiet", "refs/heads/feature/tests"]
        )
        #expect(branchCheck.exitCode == 0)

        try await RepositoryManager().deleteRepository(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            worktreePaths: [worktreeInfo.path]
        )
        #expect(!FileManager.default.fileExists(atPath: cloneInfo.bareRepositoryPath.path))
        #expect(!FileManager.default.fileExists(atPath: worktreeInfo.path.path))
    }

    @Test
    func defaultBranchWorkspaceCanBeEnsuredAndReused() async throws {
        let remote = try await createSeededRemote(named: "default-workspace")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Sample-Default-Workspace-\(UUID().uuidString)"
        )

        let first = try await WorktreeManager().ensureDefaultBranchWorkspace(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            defaultBranch: cloneInfo.defaultBranch
        )
        let second = try await WorktreeManager().ensureDefaultBranchWorkspace(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            defaultBranch: cloneInfo.defaultBranch
        )

        #expect(first.path == second.path)
        #expect(FileManager.default.fileExists(atPath: first.path.path))

        let branch = try await RepositoryManager().currentBranch(in: first.path)
        #expect(branch == cloneInfo.defaultBranch)
    }

    @Test
    func integrateIntoDefaultBranchCreatesCommit() async throws {
        let remote = try await createSeededRemote(named: "integrate")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Sample-Integrate-\(UUID().uuidString)"
        )

        let defaultWorkspace = try await WorktreeManager().ensureDefaultBranchWorkspace(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            defaultBranch: cloneInfo.defaultBranch
        )
        let featureWorkspace = try await WorktreeManager().createWorktree(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            branchName: "feature/integration",
            sourceBranch: cloneInfo.defaultBranch
        )
        try await configureGitIdentity(in: defaultWorkspace.path)
        try await configureGitIdentity(in: featureWorkspace.path)

        try "hello\nfeature\n".write(
            to: featureWorkspace.path.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await runGit(["-C", featureWorkspace.path.path, "add", "."], currentDirectoryURL: featureWorkspace.path)
        try await runGit(["-C", featureWorkspace.path.path, "commit", "-m", "Feature"], currentDirectoryURL: featureWorkspace.path)

        let result = try await WorktreeStatusService().integrate(
            sourceBranch: "feature/integration",
            defaultBranch: cloneInfo.defaultBranch,
            defaultWorktreePath: defaultWorkspace.path
        )

        guard case .committed = result else {
            Issue.record("Expected successful integration")
            return
        }

        let log = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", defaultWorkspace.path.path, "log", "-1", "--pretty=%s"]
        )
        #expect(log.exitCode == 0)
        #expect(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "Integrate feature/integration into main")
    }

    @Test
    func integrateIntoDefaultBranchReturnsConflictsWhenMergeFails() async throws {
        let remote = try await createSeededRemote(named: "conflicts")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Sample-Conflicts-\(UUID().uuidString)"
        )

        let defaultWorkspace = try await WorktreeManager().ensureDefaultBranchWorkspace(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            defaultBranch: cloneInfo.defaultBranch
        )
        let featureWorkspace = try await WorktreeManager().createWorktree(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            branchName: "feature/conflict",
            sourceBranch: cloneInfo.defaultBranch
        )
        try await configureGitIdentity(in: defaultWorkspace.path)
        try await configureGitIdentity(in: featureWorkspace.path)

        try "main\n".write(
            to: defaultWorkspace.path.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await runGit(["-C", defaultWorkspace.path.path, "add", "."], currentDirectoryURL: defaultWorkspace.path)
        try await runGit(["-C", defaultWorkspace.path.path, "commit", "-m", "Main change"], currentDirectoryURL: defaultWorkspace.path)

        try "feature\n".write(
            to: featureWorkspace.path.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await runGit(["-C", featureWorkspace.path.path, "add", "."], currentDirectoryURL: featureWorkspace.path)
        try await runGit(["-C", featureWorkspace.path.path, "commit", "-m", "Feature change"], currentDirectoryURL: featureWorkspace.path)

        let result = try await WorktreeStatusService().integrate(
            sourceBranch: "feature/conflict",
            defaultBranch: cloneInfo.defaultBranch,
            defaultWorktreePath: defaultWorkspace.path
        )

        switch result {
        case .committed:
            Issue.record("Expected merge conflicts")
        case let .conflicts(message):
            #expect(!message.isEmpty)
        }

        let conflictFiles = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", defaultWorkspace.path.path, "diff", "--name-only", "--diff-filter=U"]
        )
        #expect(conflictFiles.exitCode == 0)
        #expect(conflictFiles.stdout.contains("README.md"))
    }

    @Test
    func loadUncommittedDiffReturnsTrackedAndUntrackedFiles() async throws {
        let remote = try await createSeededRemote(named: "diff")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Sample-Diff-\(UUID().uuidString)"
        )

        let defaultWorkspace = try await WorktreeManager().ensureDefaultBranchWorkspace(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            defaultBranch: cloneInfo.defaultBranch
        )

        try "hello\nupdated\n".write(
            to: defaultWorkspace.path.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "new\nfile\n".write(
            to: defaultWorkspace.path.appendingPathComponent("NOTES.md"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try await WorktreeStatusService().loadUncommittedDiff(worktreePath: defaultWorkspace.path)

        #expect(snapshot.files.count == 2)
        #expect(snapshot.files.contains(where: { $0.path == "README.md" && $0.status == .modified }))
        #expect(snapshot.files.contains(where: { $0.path == "NOTES.md" && $0.status == .untracked }))
    }

    @Test
    func sshKeyGenerationProducesReusableMaterial() async throws {
        let material = try await SSHKeyManager().generateKey(displayName: "Test Key", comment: "tests@example.com")
        #expect(!material.publicKey.isEmpty)
        #expect(!material.privateKeyData.isEmpty)
    }

    @MainActor
    @Test
    func migrationPrefersOriginAsDefaultRemote() throws {
        let modelContext = try makeInMemoryModelContext()
        let repository = makeRepository(name: "Legacy")
        let origin = RepositoryRemote(name: "origin", url: "https://example.com/origin.git", canonicalURL: "https://example.com/origin", repository: repository)
        let upstream = RepositoryRemote(name: "upstream", url: "https://example.com/upstream.git", canonicalURL: "https://example.com/upstream", repository: repository)
        repository.remotes = [upstream, origin]

        modelContext.insert(repository)
        modelContext.insert(origin)
        modelContext.insert(upstream)
        try modelContext.save()

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext
        appModel.migrateLegacyRepositoriesIfNeeded(in: modelContext)

        #expect(repository.defaultRemoteName == "origin")
        #expect(repository.defaultRemote?.name == "origin")
    }

    @Test
    func refreshSyncsDefaultBranchFromConfiguredDefaultRemote() async throws {
        let origin = try await createSeededRemote(named: "refresh-origin")
        let upstreamRoot = try temporaryDirectory(named: "refresh-upstream")
        let upstreamBare = upstreamRoot.appendingPathComponent("upstream.git")
        try await runGit(["clone", "--bare", origin.remote.path, upstreamBare.path], currentDirectoryURL: upstreamRoot)

        let upstreamCheckout = upstreamRoot.appendingPathComponent("checkout")
        try await runGit(["clone", upstreamBare.path, upstreamCheckout.path], currentDirectoryURL: upstreamRoot)
        try await configureGitIdentity(in: upstreamCheckout)
        try "from upstream\n".write(
            to: upstreamCheckout.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await runGit(["-C", upstreamCheckout.path, "add", "."], currentDirectoryURL: upstreamRoot)
        try await runGit(["-C", upstreamCheckout.path, "commit", "-m", "Upstream update"], currentDirectoryURL: upstreamRoot)
        try await runGit(["-C", upstreamCheckout.path, "push", "origin", "HEAD:main"], currentDirectoryURL: upstreamRoot)

        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: origin.remote,
            preferredName: "Refresh-Sync-\(UUID().uuidString)"
        )
        try await RepositoryManager().addRemote(
            name: "upstream",
            url: upstreamBare.path,
            bareRepositoryPath: cloneInfo.bareRepositoryPath
        )

        let defaultWorkspace = try await WorktreeManager().ensureDefaultBranchWorkspace(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            defaultBranch: cloneInfo.defaultBranch
        )
        try await configureGitIdentity(in: defaultWorkspace.path)

        let refresh = await RepositoryManager().refreshRepository(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            remotes: [
                RemoteExecutionContext(name: "origin", url: origin.remote.path, fetchEnabled: true, privateKeyRef: nil),
                RemoteExecutionContext(name: "upstream", url: upstreamBare.path, fetchEnabled: true, privateKeyRef: nil),
            ],
            defaultRemoteName: "upstream"
        )

        #expect(refresh.status == .ready)
        #expect(refresh.defaultBranchSyncErrorMessage == nil)
        #expect(refresh.defaultBranchSyncSummary?.contains("upstream/main") == true)

        let head = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", defaultWorkspace.path.path, "rev-parse", "HEAD"]
        )
        let upstreamHead = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", cloneInfo.bareRepositoryPath.path, "rev-parse", "refs/remotes/upstream/main"]
        )
        #expect(head.exitCode == 0)
        #expect(upstreamHead.exitCode == 0)
        #expect(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == upstreamHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test
    func refreshDiscardChangesInDefaultWorktreeAndSyncsRemote() async throws {
        let origin = try await createSeededRemote(named: "dirty-default")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: origin.remote,
            preferredName: "Dirty-Default-\(UUID().uuidString)"
        )

        let defaultWorkspace = try await WorktreeManager().ensureDefaultBranchWorkspace(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            defaultBranch: cloneInfo.defaultBranch
        )
        try await configureGitIdentity(in: defaultWorkspace.path)

        let remoteCheckout = try await cloneRemoteForEditing(origin.remote, name: "dirty-default-remote")
        try "remote change\n".write(
            to: remoteCheckout.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await commitAll(in: remoteCheckout, message: "Remote update")
        try await runGit(["-C", remoteCheckout.path, "push", "origin", "HEAD:main"], currentDirectoryURL: remoteCheckout)

        try "local dirty change\n".write(
            to: defaultWorkspace.path.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "temporary\n".write(
            to: defaultWorkspace.path.appendingPathComponent("TEMP.txt"),
            atomically: true,
            encoding: .utf8
        )

        let refresh = await RepositoryManager().refreshRepository(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            remotes: [
                RemoteExecutionContext(name: "origin", url: origin.remote.path, fetchEnabled: true, privateKeyRef: nil),
            ],
            defaultRemoteName: "origin"
        )

        #expect(refresh.status == .ready)
        #expect(refresh.defaultBranchSyncErrorMessage == nil)
        #expect(refresh.defaultBranchSyncSummary?.contains("origin/main") == true)
        #expect(!FileManager.default.fileExists(atPath: defaultWorkspace.path.appendingPathComponent("TEMP.txt").path))
        let readme = try String(contentsOf: defaultWorkspace.path.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme == "remote change\n")
    }

    @Test
    func refreshMergesLocalDefaultBranchCommitsWithRemote() async throws {
        let origin = try await createSeededRemote(named: "merge-default")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: origin.remote,
            preferredName: "Merge-Default-\(UUID().uuidString)"
        )

        let defaultWorkspace = try await WorktreeManager().ensureDefaultBranchWorkspace(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            defaultBranch: cloneInfo.defaultBranch
        )
        try await configureGitIdentity(in: defaultWorkspace.path)

        try "hello\nlocal change\n".write(
            to: defaultWorkspace.path.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await commitAll(in: defaultWorkspace.path, message: "Local update")

        let remoteCheckout = try await cloneRemoteForEditing(origin.remote, name: "merge-default-remote")
        try "hello\nremote change\n".write(
            to: remoteCheckout.appendingPathComponent("NOTES.md"),
            atomically: true,
            encoding: .utf8
        )
        try await commitAll(in: remoteCheckout, message: "Remote update")
        try await runGit(["-C", remoteCheckout.path, "push", "origin", "HEAD:main"], currentDirectoryURL: remoteCheckout)

        let refresh = await RepositoryManager().refreshRepository(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            remotes: [
                RemoteExecutionContext(name: "origin", url: origin.remote.path, fetchEnabled: true, privateKeyRef: nil),
            ],
            defaultRemoteName: "origin"
        )

        #expect(refresh.status == .ready)
        #expect(refresh.defaultBranchSyncErrorMessage == nil)
        #expect(refresh.defaultBranchSyncSummary == "main mit origin/main gemergt")

        let parents = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", defaultWorkspace.path.path, "rev-list", "--parents", "-n", "1", "HEAD"]
        )
        let parts = parents.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        #expect(parts.count == 3)
    }

    @Test
    func worktreeStatusPollingPreferencesDefaultsAndIntervalFallback() {
        let defaults = UserDefaults.standard
        let previousEnabled = defaults.object(forKey: AppPreferences.worktreeStatusPollingEnabledKey)
        let previousInterval = defaults.object(forKey: AppPreferences.worktreeStatusPollingIntervalKey)
        defer {
            if let previousEnabled {
                defaults.set(previousEnabled, forKey: AppPreferences.worktreeStatusPollingEnabledKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.worktreeStatusPollingEnabledKey)
            }
            if let previousInterval {
                defaults.set(previousInterval, forKey: AppPreferences.worktreeStatusPollingIntervalKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.worktreeStatusPollingIntervalKey)
            }
        }

        defaults.removeObject(forKey: AppPreferences.worktreeStatusPollingEnabledKey)
        defaults.removeObject(forKey: AppPreferences.worktreeStatusPollingIntervalKey)
        #expect(AppPreferences.worktreeStatusPollingEnabled == AppPreferences.defaultWorktreeStatusPollingEnabled)
        #expect(AppPreferences.worktreeStatusPollingInterval == AppPreferences.defaultWorktreeStatusPollingInterval)

        defaults.set(0.0, forKey: AppPreferences.worktreeStatusPollingIntervalKey)
        #expect(AppPreferences.worktreeStatusPollingInterval == AppPreferences.defaultWorktreeStatusPollingInterval)
    }

    @MainActor
    @Test
    func refreshAllRepositoriesUsesDefaultBranchSyncPath() async throws {
        let previous = UserDefaults.standard.object(forKey: AppPreferences.autoRefreshEnabledKey)
        UserDefaults.standard.set(true, forKey: AppPreferences.autoRefreshEnabledKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppPreferences.autoRefreshEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppPreferences.autoRefreshEnabledKey)
            }
        }

        let origin = try await createSeededRemote(named: "auto-refresh-default")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: origin.remote,
            preferredName: "Auto-Refresh-\(UUID().uuidString)"
        )
        let defaultWorkspace = try await WorktreeManager().ensureDefaultBranchWorkspace(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            defaultBranch: cloneInfo.defaultBranch
        )

        let remoteCheckout = try await cloneRemoteForEditing(origin.remote, name: "auto-refresh-remote")
        try "auto refresh\n".write(
            to: remoteCheckout.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await commitAll(in: remoteCheckout, message: "Auto refresh update")
        try await runGit(["-C", remoteCheckout.path, "push", "origin", "HEAD:main"], currentDirectoryURL: remoteCheckout)

        let modelContext = try makeInMemoryModelContext()
        let repository = ManagedRepository(
            displayName: cloneInfo.displayName,
            remoteURL: origin.remote.path,
            bareRepositoryPath: cloneInfo.bareRepositoryPath.path,
            defaultBranch: cloneInfo.defaultBranch,
            defaultRemoteName: "origin"
        )
        let remote = RepositoryRemote(
            name: "origin",
            url: origin.remote.path,
            canonicalURL: RepositoryManager.canonicalRemoteURL(from: origin.remote.path)!,
            repository: repository
        )
        let worktree = WorktreeRecord(
            branchName: cloneInfo.defaultBranch,
            isDefaultBranchWorkspace: true,
            path: defaultWorkspace.path.path,
            repository: repository
        )
        repository.remotes = [remote]
        repository.worktrees = [worktree]
        modelContext.insert(repository)
        modelContext.insert(remote)
        modelContext.insert(worktree)
        try modelContext.save()

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext

        await appModel.refreshAllRepositories(force: false)

        #expect(repository.lastFetchedAt != nil)
        #expect(appModel.syncLogs[repository.id]?.contains("Fetch von origin abgeschlossen") == true)
        #expect(appModel.syncLogs[repository.id]?.contains("Sync:") == true)

        let localHead = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["-C", defaultWorkspace.path.path, "rev-parse", "HEAD"]
        )
        let remoteHead = try await CommandRunner.runCollected(
            executable: "git",
            arguments: ["--git-dir", cloneInfo.bareRepositoryPath.path, "rev-parse", "--verify", "refs/remotes/origin/main"]
        )
        #expect(localHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == remoteHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor
    @Test
    func namespaceMigrationCreatesDefaultNamespaceAndAssignsLegacyRepositories() throws {
        let modelContext = try makeInMemoryModelContext()
        let repository = makeRepository(name: "Legacy")
        modelContext.insert(repository)
        try modelContext.save()

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext

        appModel.migrateLegacyRepositoriesIfNeeded(in: modelContext)

        let namespaces = appModel.namespaces(in: modelContext)
        #expect(namespaces.count == 1)
        #expect(namespaces.first?.isDefault == true)
        #expect(namespaces.first?.name == AppModel.defaultNamespaceName)
        #expect(repository.namespace?.id == namespaces.first?.id)
        #expect(appModel.selectedNamespaceID == namespaces.first?.id)
    }

    @MainActor
    @Test
    func restoresLastSelectedNamespaceFromUserDefaults() throws {
        let modelContext = try makeInMemoryModelContext()
        let defaults = try makeUserDefaultsSuite()
        let defaultNamespace = RepositoryNamespace(name: AppModel.defaultNamespaceName, isDefault: true, sortOrder: 0)
        let workspaceNamespace = RepositoryNamespace(name: "Workspace", sortOrder: 1)
        modelContext.insert(defaultNamespace)
        modelContext.insert(workspaceNamespace)
        try modelContext.save()

        defaults.set(workspaceNamespace.id.uuidString, forKey: AppPreferences.selectedNamespaceIDKey)

        let appModel = AppModel(userDefaults: defaults)
        appModel.selectInitialNamespace(from: appModel.namespaces(in: modelContext))

        #expect(appModel.selectedNamespaceID == workspaceNamespace.id)
    }

    @MainActor
    @Test
    func missingPersistedNamespaceFallsBackToDefaultNamespace() throws {
        let modelContext = try makeInMemoryModelContext()
        let defaults = try makeUserDefaultsSuite()
        let defaultNamespace = RepositoryNamespace(name: AppModel.defaultNamespaceName, isDefault: true, sortOrder: 0)
        let workspaceNamespace = RepositoryNamespace(name: "Workspace", sortOrder: 1)
        modelContext.insert(defaultNamespace)
        modelContext.insert(workspaceNamespace)
        try modelContext.save()

        defaults.set(UUID().uuidString, forKey: AppPreferences.selectedNamespaceIDKey)

        let appModel = AppModel(userDefaults: defaults)
        appModel.selectInitialNamespace(from: appModel.namespaces(in: modelContext))

        #expect(appModel.selectedNamespaceID == defaultNamespace.id)
        #expect(defaults.string(forKey: AppPreferences.selectedNamespaceIDKey) == defaultNamespace.id.uuidString)
    }

    @MainActor
    @Test
    func assignRepositoryKeepsNamespaceAndProjectConsistent() throws {
        let modelContext = try makeInMemoryModelContext()
        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext

        let defaultNamespace = appModel.defaultNamespace(in: modelContext)
        let workspaceNamespace = RepositoryNamespace(name: "Workspace", sortOrder: 1)
        let project = RepositoryProject(name: "Inbox", namespace: workspaceNamespace)
        let repository = makeRepository(name: "Sample", namespace: defaultNamespace)

        modelContext.insert(workspaceNamespace)
        modelContext.insert(project)
        modelContext.insert(repository)
        try modelContext.save()

        appModel.assignRepository(repository, to: workspaceNamespace, project: project, in: modelContext)

        #expect(repository.namespace?.id == workspaceNamespace.id)
        #expect(repository.project?.id == project.id)
        #expect(repository.project?.namespace?.id == workspaceNamespace.id)
    }

    @MainActor
    @Test
    func movingProjectUpdatesContainedRepositoriesToTargetNamespace() throws {
        let modelContext = try makeInMemoryModelContext()
        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext

        let sourceNamespace = RepositoryNamespace(name: "Source", sortOrder: 1)
        let targetNamespace = RepositoryNamespace(name: "Target", sortOrder: 2)
        let project = RepositoryProject(name: "Backend", namespace: sourceNamespace)
        let repository = makeRepository(name: "API", namespace: sourceNamespace, project: project)

        modelContext.insert(sourceNamespace)
        modelContext.insert(targetNamespace)
        modelContext.insert(project)
        modelContext.insert(repository)
        try modelContext.save()

        appModel.moveProject(project, to: targetNamespace, in: modelContext)

        #expect(project.namespace?.id == targetNamespace.id)
        #expect(repository.namespace?.id == targetNamespace.id)
        #expect(repository.project?.id == project.id)
    }

    @MainActor
    @Test
    func deletingProjectMovesRepositoriesIntoDefaultNamespace() throws {
        let modelContext = try makeInMemoryModelContext()
        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext

        let defaultNamespace = appModel.defaultNamespace(in: modelContext)
        let workspaceNamespace = RepositoryNamespace(name: "Workspace", sortOrder: 1)
        let project = RepositoryProject(name: "Client", namespace: workspaceNamespace)
        let repository = makeRepository(name: "App", namespace: workspaceNamespace, project: project)

        modelContext.insert(workspaceNamespace)
        modelContext.insert(project)
        modelContext.insert(repository)
        try modelContext.save()

        appModel.deleteProject(project, in: modelContext)

        #expect(repository.namespace?.id == defaultNamespace.id)
        #expect(repository.project == nil)
        let projects = try modelContext.fetch(FetchDescriptor<RepositoryProject>())
        #expect(!projects.contains(where: { $0.id == project.id }))
    }

    @MainActor
    @Test
    func deletingNamespaceMovesDirectAndProjectRepositoriesToDefaultNamespace() throws {
        let modelContext = try makeInMemoryModelContext()
        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext

        let defaultNamespace = appModel.defaultNamespace(in: modelContext)
        let workspaceNamespace = RepositoryNamespace(name: "Workspace", sortOrder: 1)
        let project = RepositoryProject(name: "Services", namespace: workspaceNamespace)
        let directRepository = makeRepository(name: "Direct", namespace: workspaceNamespace)
        let groupedRepository = makeRepository(name: "Grouped", namespace: workspaceNamespace, project: project)

        modelContext.insert(workspaceNamespace)
        modelContext.insert(project)
        modelContext.insert(directRepository)
        modelContext.insert(groupedRepository)
        try modelContext.save()

        appModel.deleteNamespace(workspaceNamespace, in: modelContext)

        #expect(directRepository.namespace?.id == defaultNamespace.id)
        #expect(directRepository.project == nil)
        #expect(groupedRepository.namespace?.id == defaultNamespace.id)
        #expect(groupedRepository.project == nil)
        let namespaces = try modelContext.fetch(FetchDescriptor<RepositoryNamespace>())
        let projects = try modelContext.fetch(FetchDescriptor<RepositoryProject>())
        #expect(!namespaces.contains(where: { $0.id == workspaceNamespace.id }))
        #expect(!projects.contains(where: { $0.id == project.id }))
    }


    @MainActor
    @Test
    func vscodeLaunchConfigurationsAreParsedFromJSONC() throws {
        let root = try temporaryDirectory(named: "vscode-launch")
        let vscodeDirectory = root.appendingPathComponent(".vscode", isDirectory: true)
        try FileManager.default.createDirectory(at: vscodeDirectory, withIntermediateDirectories: true)
        try """
        {
          // Stackriot should tolerate JSONC comments and trailing commas
          "configurations": [
            {
              "name": "API",
              "type": "node",
              "request": "launch",
              "program": "${workspaceFolder}/server.js",
              "cwd": "${workspaceFolder}/packages/api",
              "args": ["--watch"],
              "env": { "PORT": "3000", },
            },
          ],
        }
        """.write(
            to: vscodeDirectory.appendingPathComponent("launch.json"),
            atomically: true,
            encoding: .utf8
        )

        let configurations = RunConfigurationDiscoveryService().discoverRunConfigurations(in: root)
        let configuration = try #require(configurations.first(where: { $0.source == .vscode && $0.name == "API" }))

        #expect(configuration.command == "node")
        #expect(configuration.arguments == [root.appendingPathComponent("server.js").path, "--watch"])
        #expect(configuration.workingDirectory == root.appendingPathComponent("packages/api").path)
        #expect(configuration.environment["PORT"] == "3000")
        #expect(configuration.runtimeRequirement != nil)
    }

    @MainActor
    @Test
    func jetbrainsShellConfigurationsAreParsed() throws {
        let root = try temporaryDirectory(named: "jetbrains-shell")
        let ideaDirectory = root.appendingPathComponent(".idea/runConfigurations", isDirectory: true)
        try FileManager.default.createDirectory(at: ideaDirectory, withIntermediateDirectories: true)
        let scriptURL = root.appendingPathComponent("scripts/test.sh")
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho ok\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try """
        <component name="ProjectRunConfigurationManager">
          <configuration name="Smoke" type="ShConfigurationType">
            <option name="SCRIPT_PATH" value="scripts/test.sh" />
            <option name="SCRIPT_OPTIONS" value="--smoke --ci" />
            <option name="WORKING_DIRECTORY" value="${PROJECT_DIR}" />
          </configuration>
        </component>
        """.write(
            to: ideaDirectory.appendingPathComponent("Smoke.xml"),
            atomically: true,
            encoding: .utf8
        )

        let configurations = RunConfigurationDiscoveryService().discoverRunConfigurations(in: root)
        let configuration = try #require(configurations.first(where: { $0.name == "Smoke" }))

        #expect(configuration.source == .jetbrains)
        #expect(configuration.command == scriptURL.path)
        #expect(configuration.arguments == ["--smoke", "--ci"])
        #expect(configuration.preferredDevTool == .webstorm)
    }

    @MainActor
    @Test
    func xcodeSharedSchemesBecomeBuildableRunConfigurations() throws {
        let root = try temporaryDirectory(named: "xcode-schemes")
        let schemeDirectory = root
            .appendingPathComponent("Sample.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: schemeDirectory, withIntermediateDirectories: true)
        try """
        <Scheme LastUpgradeVersion="1600" version="1.7">
          <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES" />
          <LaunchAction buildConfiguration="Debug" />
        </Scheme>
        """.write(
            to: schemeDirectory.appendingPathComponent("Sample.xcscheme"),
            atomically: true,
            encoding: .utf8
        )

        let configurations = RunConfigurationDiscoveryService().discoverRunConfigurations(in: root)
        let configuration = try #require(configurations.first(where: { $0.source == .xcode && $0.name == "Sample" }))

        #expect(configuration.command == "xcodebuild")
        #expect(configuration.arguments.contains("-project"))
        #expect(configuration.arguments.contains("Sample"))
        #expect(configuration.arguments.last == "build")
        #expect(configuration.executionBehavior == .buildOnly)
    }

    @MainActor
    @Test
    func devToolContextFilteringMatchesRepositorySignals() throws {
        let root = try temporaryDirectory(named: "dev-tool-context")
        try "module demo\n".write(to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("composer.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Client.xcodeproj"), withIntermediateDirectories: true)

        let service = DevToolDiscoveryService()
        let relevantTools = service.relevantTools(
            from: [.cursor, .vscode, .zed, .xcode, .goland, .phpstorm, .webstorm, .intellijIdea],
            for: root
        )

        #expect(relevantTools.contains(.cursor))
        #expect(relevantTools.contains(.vscode))
        #expect(relevantTools.contains(.zed))
        #expect(relevantTools.contains(.xcode))
        #expect(relevantTools.contains(.goland))
        #expect(relevantTools.contains(.phpstorm))
        #expect(relevantTools.contains(.webstorm))
        #expect(relevantTools.contains(.intellijIdea))
    }

    @Test
    func worktreeNameNormalizationReplacesWhitespaceWithHyphen() {
        #expect(WorktreeManager.normalizedWorktreeName(from: "Feature A") == "Feature-A")
        #expect(WorktreeManager.normalizedWorktreeName(from: "  Feature   A  ") == "Feature-A")
        #expect(WorktreeManager.normalizedWorktreeName(from: "bug / 3 großes fenster kaputt") == "bug/3-grosses-fenster-kaputt")
        #expect(WorktreeManager.normalizedWorktreeName(from: "   ").isEmpty)
    }

    @Test
    func aiWorktreeSuggestionFallsBackToTypedSlashBranchName() async throws {
        let service = AIProviderService(
            configurationProvider: {
                AIProviderConfiguration(
                    provider: .openAI,
                    apiKey: nil,
                    model: "gpt-5.4-mini",
                    baseURL: "https://api.openai.com/v1"
                )
            }
        )
        let issue = GitHubIssueDetails(
            number: 3,
            title: "BUG: Großes Fenster kaputt",
            body: "Das Fenster ist defekt und laesst sich nicht korrekt rendern.",
            url: "https://example.com/issues/3",
            labels: ["bug"],
            comments: []
        )

        let suggestion = try await service.suggestWorktreeName(for: issue)
        #expect(suggestion.kind == .bug)
        #expect(suggestion.branchName == "bug/3-grosses-fenster-kaputt")
    }

    @Test
    func aiWorktreeSuggestionFallsBackToJiraKeyBranchName() async throws {
        let service = AIProviderService(
            configurationProvider: {
                AIProviderConfiguration(
                    provider: .openAI,
                    apiKey: nil,
                    model: "gpt-5.4-mini",
                    baseURL: "https://api.openai.com/v1"
                )
            }
        )
        let ticket = TicketDetails(
            reference: TicketReference(provider: .jira, id: "ABC-123", displayID: "ABC-123"),
            title: "Bug: Jira issue import kaputt",
            body: "Jira Tickets sollen im Worktree-Flow erscheinen.",
            url: "https://example.atlassian.net/browse/ABC-123",
            labels: ["bug"],
            comments: []
        )

        let suggestion = try await service.suggestWorktreeName(for: ticket)
        #expect(suggestion.kind == .bug)
        #expect(suggestion.branchName == "bug/abc-123-jira-import-kaputt")
        #expect(suggestion.ticketIdentifier == "ABC-123")
    }

    @MainActor
    @Test
    func confirmedTicketCanPopulateSuggestedWorktreeNameFromAIService() async throws {
        let services = AppServices(
            repositoryManager: RepositoryManager(),
            worktreeManager: WorktreeManager(),
            gitHubCLIService: GitHubCLIService(),
            aiProviderService: AIProviderService(
                configurationProvider: {
                    AIProviderConfiguration(
                        provider: .openAI,
                        apiKey: "test-key",
                        model: "gpt-5.4-mini",
                        baseURL: "https://api.openai.com/v1"
                    )
                },
                worktreeNameGenerator: { issue, _ in
                    AIWorktreeNameSuggestion(
                        kind: .bug,
                        ticketNumber: issue.number,
                        shortSummary: "grosses fenster kaputt",
                        branchName: "bug/\(issue.number)-grosses-fenster-kaputt"
                    )
                }
            ),
            ideManager: IDEManager(),
            sshKeyManager: SSHKeyManager(),
            agentManager: AIAgentManager(),
            nodeTooling: NodeToolingService(),
            nodeRuntimeManager: NodeRuntimeManager(),
            makeTooling: MakeToolingService(),
            worktreeStatusService: WorktreeStatusService(),
            devToolDiscovery: DevToolDiscoveryService(),
            runConfigurationDiscovery: RunConfigurationDiscoveryService()
        )
        let appModel = AppModel(services: services)
        let issue = GitHubIssueDetails(
            number: 3,
            title: "Großes Fenster kaputt",
            body: "Bitte reparieren.",
            url: "https://example.com/issues/3",
            labels: ["bug"],
            comments: []
        )

        await appModel.populateSuggestedWorktreeName(from: issue)

        #expect(appModel.worktreeDraft.branchName == "bug/3-grosses-fenster-kaputt")
        #expect(!appModel.worktreeDraft.isGeneratingSuggestedName)
    }

    @Test
    func createWorktreeSupportsSlashSeparatedDirectoryNames() async throws {
        let remote = try await createSeededRemote(named: "slash-worktree")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Slash-Worktree-\(UUID().uuidString)"
        )

        let worktreeInfo = try await WorktreeManager().createWorktree(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            branchName: "bug/3-grosses-fenster-kaputt",
            sourceBranch: cloneInfo.defaultBranch,
            directoryName: "bug/3-grosses-fenster-kaputt"
        )

        #expect(FileManager.default.fileExists(atPath: worktreeInfo.path.path))
        #expect(worktreeInfo.branchName == "bug/3-grosses-fenster-kaputt")
        #expect(worktreeInfo.path.lastPathComponent == "3-grosses-fenster-kaputt")
        #expect(worktreeInfo.path.deletingLastPathComponent().lastPathComponent == "bug")

        try? FileManager.default.removeItem(at: worktreeInfo.path)
        try? FileManager.default.removeItem(at: cloneInfo.bareRepositoryPath)
    }

    @Test
    func createWorktreeUsesCustomDestinationRootWhenProvided() async throws {
        let remote = try await createSeededRemote(named: "custom-destination-worktree")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Custom-Destination-\(UUID().uuidString)"
        )
        let destinationRoot = try temporaryDirectory(named: "custom-worktree-root")

        let worktreeInfo = try await WorktreeManager().createWorktree(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            branchName: "feature/custom-path",
            sourceBranch: cloneInfo.defaultBranch,
            directoryName: "feature/custom-path",
            destinationRoot: destinationRoot
        )

        #expect(worktreeInfo.path.path.hasPrefix(destinationRoot.path + "/"))
        #expect(worktreeInfo.path.lastPathComponent == "custom-path")
        #expect(worktreeInfo.path.deletingLastPathComponent().lastPathComponent == "feature")

        try? FileManager.default.removeItem(at: destinationRoot)
        try? FileManager.default.removeItem(at: cloneInfo.bareRepositoryPath)
    }

    @Test
    func createWorktreeAddsUniqueSuffixInsideCustomDestinationRoot() async throws {
        let remote = try await createSeededRemote(named: "duplicate-destination-worktree")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Duplicate-Destination-\(UUID().uuidString)"
        )
        let destinationRoot = try temporaryDirectory(named: "duplicate-worktree-root")
        let occupied = destinationRoot.appendingPathComponent("feature/custom-path", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)

        let worktreeInfo = try await WorktreeManager().createWorktree(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            branchName: "feature/custom-path",
            sourceBranch: cloneInfo.defaultBranch,
            directoryName: "feature/custom-path",
            destinationRoot: destinationRoot
        )

        #expect(worktreeInfo.path.lastPathComponent == "custom-path-2")
        #expect(worktreeInfo.path.deletingLastPathComponent().lastPathComponent == "feature")

        try? FileManager.default.removeItem(at: destinationRoot)
        try? FileManager.default.removeItem(at: cloneInfo.bareRepositoryPath)
    }

    @Test
    func moveWorktreeMovesFeatureWorkspaceToNewRoot() async throws {
        let remote = try await createSeededRemote(named: "move-worktree")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Move-Worktree-\(UUID().uuidString)"
        )
        let worktreeInfo = try await WorktreeManager().createWorktree(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            branchName: "feature/move-me",
            sourceBranch: cloneInfo.defaultBranch,
            directoryName: "feature/move-me"
        )
        let destinationRoot = try temporaryDirectory(named: "move-worktree-root")

        let movedPath = try await WorktreeManager().moveWorktree(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            worktreePath: worktreeInfo.path,
            newParentDirectory: destinationRoot,
            directoryName: "feature/move-me"
        )

        #expect(!FileManager.default.fileExists(atPath: worktreeInfo.path.path))
        #expect(FileManager.default.fileExists(atPath: movedPath.path))
        #expect(movedPath.path.hasPrefix(destinationRoot.path + "/"))

        try? FileManager.default.removeItem(at: destinationRoot)
        try? FileManager.default.removeItem(at: cloneInfo.bareRepositoryPath)
    }

    @MainActor
    @Test
    func agentRunsReceiveAISummaryInsteadOfOnlyRawOutput() async throws {
        let modelContext = try makeInMemoryModelContext()
        let repository = makeRepository(name: "AgentSummary")
        let worktree = WorktreeRecord(branchName: "bug/3-window", path: "/tmp/agent-summary", repository: repository)
        let run = RunRecord(
            actionKind: .aiAgent,
            title: "GitHub Copilot",
            commandLine: "copilot -p",
            outputText: "$ copilot -p\nUpdated files\n",
            status: .running,
            worktreeID: worktree.id,
            repository: repository,
            worktree: worktree
        )
        repository.worktrees = [worktree]
        repository.runs = [run]
        modelContext.insert(repository)
        modelContext.insert(worktree)
        modelContext.insert(run)
        try modelContext.save()

        let services = AppServices(
            repositoryManager: RepositoryManager(),
            worktreeManager: WorktreeManager(),
            gitHubCLIService: GitHubCLIService(),
            aiProviderService: AIProviderService(
                configurationProvider: {
                    AIProviderConfiguration(
                        provider: .openAI,
                        apiKey: "test-key",
                        model: "gpt-5.4-mini",
                        baseURL: "https://api.openai.com/v1"
                    )
                },
                runSummaryGenerator: { title, _, _, exitCode, _ in
                    AIRunSummary(
                        title: "\(title) fertig",
                        summary: "Der Agentlauf endete mit Exit-Code \(exitCode ?? -1) und hat die wichtigsten Aenderungen zusammengefasst."
                    )
                }
            ),
            ideManager: IDEManager(),
            sshKeyManager: SSHKeyManager(),
            agentManager: AIAgentManager(),
            nodeTooling: NodeToolingService(),
            nodeRuntimeManager: NodeRuntimeManager(),
            makeTooling: MakeToolingService(),
            worktreeStatusService: WorktreeStatusService(),
            devToolDiscovery: DevToolDiscoveryService(),
            runConfigurationDiscovery: RunConfigurationDiscoveryService()
        )
        let appModel = AppModel(services: services)
        appModel.storedModelContext = modelContext

        appModel.handleRunTermination(runID: run.id, exitCode: 0, wasCancelled: false)
        for _ in 0..<20 where run.aiSummaryTitle == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(run.aiSummaryTitle == "GitHub Copilot fertig")
        #expect(run.aiSummaryText?.contains("Exit-Code 0") == true)
        #expect(appModel.shouldShowAISummary(for: run))
        appModel.dismissAISummary(for: run)
        #expect(!appModel.shouldShowAISummary(for: run))
    }

    @MainActor
    @Test
    func completedAgentRunsDoNotAutoHideTerminalTabs() async throws {
        let modelContext = try makeInMemoryModelContext()
        let repository = makeRepository(name: "AgentRetention")
        let worktree = WorktreeRecord(branchName: "bug/7-retention", path: "/tmp/agent-retention", repository: repository)
        let run = RunRecord(
            actionKind: .aiAgent,
            title: "Codex",
            commandLine: "codex exec",
            outputText: "$ codex exec\nDone\n",
            status: .running,
            worktreeID: worktree.id,
            repository: repository,
            worktree: worktree
        )
        repository.worktrees = [worktree]
        repository.runs = [run]
        modelContext.insert(repository)
        modelContext.insert(worktree)
        modelContext.insert(run)
        try modelContext.save()

        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: AppPreferences.terminalTabRetentionModeKey)
        defaults.set(TerminalTabRetentionMode.runningOnly.rawValue, forKey: AppPreferences.terminalTabRetentionModeKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: AppPreferences.terminalTabRetentionModeKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.terminalTabRetentionModeKey)
            }
        }

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext
        appModel.handleRunTermination(runID: run.id, exitCode: 0, wasCancelled: false)

        #expect(!appModel.shouldAutoHideCompletedRun(run, retentionMode: .runningOnly))
    }

    @MainActor
    @Test
    func failedFixableRunsStayVisibleEvenInRunningOnlyMode() async throws {
        let modelContext = try makeInMemoryModelContext()
        let repository = makeRepository(name: "FixableFailure")
        let worktree = WorktreeRecord(branchName: "bug/keep-visible", path: "/tmp/fixable-failure", repository: repository)
        let run = RunRecord(
            actionKind: .runConfiguration,
            title: "App Build",
            commandLine: "xcodebuild -scheme App build",
            outputText: "$ xcodebuild -scheme App build\nCompile failed\n",
            status: .running,
            worktreeID: worktree.id,
            runConfigurationID: "xcode-App",
            repository: repository,
            worktree: worktree
        )
        repository.worktrees = [worktree]
        repository.runs = [run]
        modelContext.insert(repository)
        modelContext.insert(worktree)
        modelContext.insert(run)
        try modelContext.save()

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext
        appModel.handleRunTermination(runID: run.id, exitCode: 1, wasCancelled: false)

        #expect(run.isFixableBuildFailure)
        #expect(!appModel.shouldAutoHideCompletedRun(run, retentionMode: .runningOnly))
    }

    @MainActor
    @Test
    func failedNonFixableRunsStillAutoHideInRunningOnlyMode() async throws {
        let modelContext = try makeInMemoryModelContext()
        let repository = makeRepository(name: "NonFixableFailure")
        let worktree = WorktreeRecord(branchName: "bug/hide-me", path: "/tmp/non-fixable-failure", repository: repository)
        let run = RunRecord(
            actionKind: .makeTarget,
            title: "make test",
            commandLine: "make test",
            outputText: "$ make test\nfail\n",
            status: .running,
            worktreeID: worktree.id,
            repository: repository,
            worktree: worktree
        )
        repository.worktrees = [worktree]
        repository.runs = [run]
        modelContext.insert(repository)
        modelContext.insert(worktree)
        modelContext.insert(run)
        try modelContext.save()

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext
        appModel.handleRunTermination(runID: run.id, exitCode: 2, wasCancelled: false)

        #expect(appModel.shouldAutoHideCompletedRun(run, retentionMode: .runningOnly))
    }

    @Test
    func appNotificationServiceRequestsAuthorizationBeforeDelivery() async {
        let center = TestUserNotificationCenter(
            authorizationStatus: .notDetermined,
            authorizationGrantResult: true
        )
        let service = AppNotificationService(center: center)

        let result = await service.deliver(
            AppNotificationRequest(
                identifier: "run-finished",
                title: "Codex",
                subtitle: "AI Agent",
                body: "Completed successfully.",
                kind: .success
            )
        )

        #expect(result == .delivered)
        #expect(await center.requestAuthorizationCallCount == 1)
        let requests = await center.deliveredRequestSnapshots()
        #expect(requests.count == 1)
        #expect(requests[0].title == "Codex")
        #expect(requests[0].subtitle == "AI Agent")
        #expect(requests[0].body == "Completed successfully.")
    }

    @Test
    func appNotificationServiceSkipsDeliveryWhenPermissionIsDenied() async {
        let center = TestUserNotificationCenter(authorizationStatus: .denied)
        let service = AppNotificationService(center: center)

        let result = await service.deliver(
            AppNotificationRequest(
                identifier: "run-failed",
                title: "Build",
                subtitle: "Run Configuration",
                body: "Failed with exit code 65.",
                kind: .failure
            )
        )

        #expect(result == .skipped(.denied))
        #expect(await center.requestAuthorizationCallCount == 0)
        #expect(await center.deliveredRequestSnapshots().isEmpty)
    }

    @MainActor
    @Test
    func completedRunsTriggerDesktopNotifications() async throws {
        let modelContext = try makeInMemoryModelContext()
        let recorder = RecordingNotificationService()
        let appModel = AppModel(services: AppServices(notificationService: recorder))
        appModel.storedModelContext = modelContext

        let repository = makeRepository(name: "Notifications")
        let worktree = WorktreeRecord(branchName: "feature/desktop-alerts", path: "/tmp/desktop-alerts", repository: repository)
        let run = RunRecord(
            actionKind: .makeTarget,
            title: "make test",
            commandLine: "make test",
            outputText: "$ make test\nok\n",
            status: .running,
            worktreeID: worktree.id,
            repository: repository,
            worktree: worktree
        )
        repository.worktrees = [worktree]
        repository.runs = [run]
        modelContext.insert(repository)
        modelContext.insert(worktree)
        modelContext.insert(run)
        try modelContext.save()

        appModel.handleRunTermination(runID: run.id, exitCode: 0, wasCancelled: false)
        try? await Task.sleep(for: .milliseconds(50))

        let notifications = await recorder.deliveredRequests
        #expect(notifications.count == 1)
        #expect(notifications[0].title == "make test")
        #expect(notifications[0].subtitle == "Make Target")
        #expect(notifications[0].body.contains("Notifications / feature/desktop-alerts"))
        #expect(notifications[0].kind == .success)
    }

    @MainActor
    @Test
    func cancelledRunsDoNotTriggerDesktopNotifications() async throws {
        let modelContext = try makeInMemoryModelContext()
        let recorder = RecordingNotificationService()
        let appModel = AppModel(services: AppServices(notificationService: recorder))
        appModel.storedModelContext = modelContext

        let repository = makeRepository(name: "CancelledNotifications")
        let worktree = WorktreeRecord(branchName: "feature/cancelled", path: "/tmp/cancelled", repository: repository)
        let run = RunRecord(
            actionKind: .npmScript,
            title: "npm test",
            commandLine: "npm test",
            outputText: "$ npm test\n",
            status: .running,
            worktreeID: worktree.id,
            repository: repository,
            worktree: worktree
        )
        repository.worktrees = [worktree]
        repository.runs = [run]
        modelContext.insert(repository)
        modelContext.insert(worktree)
        modelContext.insert(run)
        try modelContext.save()

        appModel.handleRunTermination(runID: run.id, exitCode: 0, wasCancelled: true)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await recorder.deliveredRequests.isEmpty)
    }

    @Test
    func fixWithAIPromptIncludesErrorContext() {
        let run = RunRecord(
            actionKind: .runConfiguration,
            title: "App Build",
            commandLine: "xcodebuild -scheme App build",
            exitCode: 65,
            outputText: "$ xcodebuild -scheme App build\nCompile failed\n",
            status: .failed,
            worktreeID: UUID(),
            runConfigurationID: "xcode-App"
        )

        let prompt = AppModel.fixWithAIPrompt(for: run)

        #expect(prompt.contains("# Fehler beim Build"))
        #expect(prompt.contains("Benutztes CMD: xcodebuild -scheme App build"))
        #expect(prompt.contains("Fehlercode: 65"))
        #expect(prompt.contains("<ShellLog>"))
        #expect(prompt.contains("Compile failed"))
    }

    @Test
    func fixWithAIPromptFallsBackWhenExitCodeAndLogAreMissing() {
        let run = RunRecord(
            actionKind: .runConfiguration,
            title: "App Build",
            commandLine: "",
            outputText: "",
            status: .failed,
            worktreeID: UUID(),
            runConfigurationID: "xcode-App"
        )

        let prompt = AppModel.fixWithAIPrompt(for: run)

        #expect(prompt.contains("Benutztes CMD: App Build"))
        #expect(prompt.contains("Fehlercode: unbekannt"))
        #expect(prompt.contains("Keine Shell-Ausgabe verfuegbar."))
    }

    @MainActor
    @Test
    func successfulFixAgentRetriesOriginalRunConfiguration() async throws {
        let root = try temporaryDirectory(named: "run-fix-retry")
        try """
        build:
        \t@true
        """.write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)

        let modelContext = try makeInMemoryModelContext()
        let repository = makeRepository(name: "RetryBuild")
        let worktree = WorktreeRecord(branchName: "bug/retry-build", path: root.path, repository: repository)
        let failedRun = RunRecord(
            actionKind: .makeTarget,
            title: "build",
            commandLine: "make build",
            exitCode: 2,
            outputText: "$ make build\nfail\n",
            status: .failed,
            worktreeID: worktree.id,
            runConfigurationID: "native-make-build",
            repository: repository,
            worktree: worktree
        )
        repository.worktrees = [worktree]
        repository.runs = [failedRun]
        modelContext.insert(repository)
        modelContext.insert(worktree)
        modelContext.insert(failedRun)
        try modelContext.save()

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext
        appModel.pendingRunFixesByAgentRunID[UUID()] = RunFixRequest(
            tool: .codex,
            sourceRunID: failedRun.id,
            runConfigurationID: "native-make-build",
            worktreeID: worktree.id,
            runTitle: failedRun.title
        )

        let agentRunID = try #require(appModel.pendingRunFixesByAgentRunID.keys.first)
        appModel.completePendingRunFixIfNeeded(afterAgentRunID: agentRunID, succeeded: true)

        #expect(repository.runs.count == 2)
        let retriedRun = try #require(repository.runs.first(where: { $0.id != failedRun.id }))
        #expect(retriedRun.runConfigurationID == "native-make-build")
        #expect(retriedRun.commandLine == "make build")

        #expect(appModel.activeRunIDs.contains(retriedRun.id) || retriedRun.status == .succeeded)
    }

    @MainActor
    @Test
    func nonAgentRunsDoNotProduceAISummary() async throws {
        let modelContext = try makeInMemoryModelContext()
        let repository = makeRepository(name: "BuildSummary")
        let worktree = WorktreeRecord(branchName: "main", path: "/tmp/build-summary", repository: repository)
        let run = RunRecord(
            actionKind: .makeTarget,
            title: "make test",
            commandLine: "make test",
            outputText: "$ make test\nok\n",
            status: .running,
            worktreeID: worktree.id,
            repository: repository,
            worktree: worktree
        )
        repository.worktrees = [worktree]
        repository.runs = [run]
        modelContext.insert(repository)
        modelContext.insert(worktree)
        modelContext.insert(run)
        try modelContext.save()

        let services = AppServices(
            repositoryManager: RepositoryManager(),
            worktreeManager: WorktreeManager(),
            gitHubCLIService: GitHubCLIService(),
            aiProviderService: AIProviderService(
                configurationProvider: {
                    AIProviderConfiguration(
                        provider: .openAI,
                        apiKey: "test-key",
                        model: "gpt-5.4-mini",
                        baseURL: "https://api.openai.com/v1"
                    )
                },
                runSummaryGenerator: { title, _, _, exitCode, _ in
                    AIRunSummary(
                        title: "\(title) fertig",
                        summary: "Exit-Code \(exitCode ?? -1)"
                    )
                }
            ),
            ideManager: IDEManager(),
            sshKeyManager: SSHKeyManager(),
            agentManager: AIAgentManager(),
            nodeTooling: NodeToolingService(),
            nodeRuntimeManager: NodeRuntimeManager(),
            makeTooling: MakeToolingService(),
            worktreeStatusService: WorktreeStatusService(),
            devToolDiscovery: DevToolDiscoveryService(),
            runConfigurationDiscovery: RunConfigurationDiscoveryService()
        )
        let appModel = AppModel(services: services)
        appModel.storedModelContext = modelContext

        appModel.handleRunTermination(runID: run.id, exitCode: 0, wasCancelled: false)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(run.aiSummaryTitle == nil)
        #expect(run.aiSummaryText == nil)
        #expect(!appModel.shouldShowAISummary(for: run))
    }

    @MainActor
    @Test
    func aiAgentRunsCreateAppendAndFinalizeArchivedRawLogs() async throws {
        let modelContext = try makeInMemoryModelContext()
        let archiveRoot = try temporaryDirectory(named: "raw-log-archive")
        let services = AppServices(
            aiProviderService: AIProviderService(
                configurationProvider: {
                    AIProviderConfiguration(
                        provider: .openAI,
                        apiKey: "test-key",
                        model: "gpt-5.4-mini",
                        baseURL: "https://api.openai.com/v1"
                    )
                },
                runSummaryGenerator: { title, _, _, exitCode, _ in
                    AIRunSummary(title: title, summary: "Exit-Code \(exitCode ?? -1)")
                }
            ),
            rawLogArchive: AgentRawLogArchiveService(rootDirectoryProvider: { archiveRoot })
        )
        let appModel = AppModel(services: services)
        appModel.storedModelContext = modelContext

        let project = RepositoryProject(name: "Archive")
        let repository = makeRepository(name: "RawLogs", project: project)
        let worktree = WorktreeRecord(branchName: "feature/raw-logs", path: archiveRoot.path, repository: repository)
        repository.worktrees = [worktree]
        modelContext.insert(project)
        modelContext.insert(repository)
        modelContext.insert(worktree)
        try modelContext.save()

        let descriptor = CommandExecutionDescriptor(
            title: "Codex",
            actionKind: .aiAgent,
            showsAgentIndicator: true,
            executable: "codex",
            arguments: ["exec", "--full-auto", "Investigate failing tests"],
            displayCommandLine: "codex exec --full-auto Investigate failing tests",
            currentDirectoryURL: URL(fileURLWithPath: worktree.path),
            repositoryID: repository.id,
            worktreeID: worktree.id,
            usesTerminalSession: false,
            outputInterpreter: .codexExecJSONL,
            agentTool: .codex,
            initialPrompt: "Investigate failing tests"
        )

        let run = try #require(appModel.startRun(descriptor, repository: repository, worktree: worktree, modelContext: modelContext))
        appModel.handleRunOutput(runID: run.id, chunk: "{\"event\":\"delta\"}\n")
        appModel.handleRunOutput(runID: run.id, chunk: "{\"event\":\"done\"}\n")
        appModel.handleRunTermination(runID: run.id, exitCode: 0, wasCancelled: false)

        let records = try modelContext.fetch(FetchDescriptor<AgentRawLogRecord>())
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.runID == run.id)
        #expect(record.projectName == "Archive")
        #expect(record.repositoryName == "RawLogs")
        #expect(record.worktreeBranchName == "feature/raw-logs")
        #expect(record.promptText == "Investigate failing tests")
        #expect(record.status == .succeeded)
        #expect(record.endedAt != nil)
        #expect((record.durationSeconds ?? -1) >= 0)
        #expect(record.fileSize > 0)

        let archivedText = try String(contentsOf: record.logFileURL, encoding: .utf8)
        #expect(archivedText.contains("$ codex exec --full-auto Investigate failing tests"))
        #expect(archivedText.contains("{\"event\":\"delta\"}"))
        #expect(archivedText.contains("{\"event\":\"done\"}"))
    }

    @MainActor
    @Test
    func deletingArchivedRawLogsRemovesMetadataAndFile() throws {
        let modelContext = try makeInMemoryModelContext()
        let archiveRoot = try temporaryDirectory(named: "raw-log-delete")
        let services = AppServices(rawLogArchive: AgentRawLogArchiveService(rootDirectoryProvider: { archiveRoot }))
        let appModel = AppModel(services: services)
        appModel.storedModelContext = modelContext

        let repository = makeRepository(name: "DeleteLogs")
        modelContext.insert(repository)
        let logDirectory = archiveRoot.appendingPathComponent("entry", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent("raw.log")
        try "hello".write(to: logURL, atomically: true, encoding: .utf8)

        let record = AgentRawLogRecord(
            runID: UUID(),
            repositoryID: repository.id,
            repositoryName: repository.displayName,
            agentTool: .githubCopilot,
            title: "Copilot",
            promptText: "Summarize",
            startedAt: .now,
            endedAt: .now,
            durationSeconds: 1,
            logFilePath: logURL.path,
            fileSize: 5,
            status: .failed
        )
        modelContext.insert(record)
        try modelContext.save()

        appModel.deleteRawLog(record, in: modelContext)

        #expect(!FileManager.default.fileExists(atPath: logURL.path))
        #expect(!FileManager.default.fileExists(atPath: logDirectory.path))
        let records = try modelContext.fetch(FetchDescriptor<AgentRawLogRecord>())
        #expect(records.isEmpty)
    }

    @Test
    func archivedRawLogsRenderMissingProjectAndWorktreeMetadataSafely() {
        let record = AgentRawLogRecord(
            agentTool: .claudeCode,
            title: "Claude Code",
            promptText: nil,
            startedAt: .now,
            logFilePath: "/tmp/raw.log"
        )

        #expect(record.displayProjectName == "Ohne Projekt")
        #expect(record.displayRepositoryName == "Ohne Repository")
        #expect(record.displayWorktreeName == "Ohne Worktree")
    }

    @MainActor
    @Test
    func gitHubIssueReadinessTracksMissingRemoteCliAndAuth() async {
        let repository = makeRepository(name: "GitHub")
        let origin = RepositoryRemote(
            name: "origin",
            url: "https://github.com/octo/example.git",
            canonicalURL: "https://github.com/octo/example",
            repository: repository
        )
        repository.remotes = [origin]

        let missingCLI = GitHubCLIService(
            runCommand: { executable, arguments, _, _ in
                if executable == "which", arguments == ["gh"] {
                    return CommandResult(stdout: "", stderr: "", exitCode: 1)
                }
                Issue.record("Unexpected command: \(executable) \(arguments.joined(separator: " "))")
                return CommandResult(stdout: "", stderr: "", exitCode: 1)
            },
            environmentProvider: { ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"] }
        )
        let missingCLIStatus = await missingCLI.issueReadiness(for: repository)
        #expect(!missingCLIStatus.isAvailable)
        #expect(missingCLIStatus.message.contains("gh"))

        actor EnvironmentRecorder {
            private var values: [[String: String]] = []

            func append(_ value: [String: String]) {
                values.append(value)
            }

            func snapshot() -> [[String: String]] {
                values
            }
        }

        let recorder = EnvironmentRecorder()
        let expectedPATH = "/opt/homebrew/bin:/usr/bin:/bin"
        let missingAuth = GitHubCLIService(
            runCommand: { executable, arguments, _, environment in
                await recorder.append(environment)
                if executable == "which", arguments == ["gh"] {
                    return CommandResult(stdout: "/usr/local/bin/gh\n", stderr: "", exitCode: 0)
                }
                if executable == "gh", arguments == ["auth", "status"] {
                    return CommandResult(stdout: "", stderr: "not logged in", exitCode: 1)
                }
                Issue.record("Unexpected command: \(executable) \(arguments.joined(separator: " "))")
                return CommandResult(stdout: "", stderr: "", exitCode: 1)
            },
            environmentProvider: { ["PATH": expectedPATH] }
        )
        let missingAuthStatus = await missingAuth.issueReadiness(for: repository)
        #expect(!missingAuthStatus.isAvailable)
        #expect(missingAuthStatus.message.contains("auth"))
        let recordedEnvironments = await recorder.snapshot()
        #expect(recordedEnvironments.count == 2)
        #expect(recordedEnvironments.allSatisfy { $0["PATH"] == expectedPATH })

        let localRepository = makeRepository(name: "Local")
        let upstream = RepositoryRemote(
            name: "upstream",
            url: "https://gitlab.com/acme/example.git",
            canonicalURL: "https://gitlab.com/acme/example",
            repository: localRepository
        )
        localRepository.remotes = [upstream]

        let missingRemoteStatus = await missingAuth.issueReadiness(for: localRepository)
        #expect(!missingRemoteStatus.isAvailable)
        #expect(missingRemoteStatus.message.contains("GitHub-Remote"))
    }

    @Test
    func gitHubIssueSearchResultsDecodeFromCLIJSON() throws {
        let service = GitHubCLIService()
        let data = Data(
            """
            [
              {"number": 123, "title": "Feature A", "url": "https://github.com/octo/example/issues/123", "state": "OPEN"}
            ]
            """.utf8
        )

        let results = try service.decodeIssueSearchResults(from: data)

        #expect(results == [
            GitHubIssueSearchResult(
                number: 123,
                title: "Feature A",
                url: "https://github.com/octo/example/issues/123",
                state: "OPEN"
            )
        ])
    }

    @Test
    func gitHubIssueDetailsDecodeFromCLIJSONHandlesLabelsCommentsAndEmptyContent() throws {
        let service = GitHubCLIService()
        let populatedData = Data(
            """
            {
              "number": 123,
              "title": "Ticket backed worktree",
              "body": "Use the selected issue as plan input.",
              "url": "https://github.com/octo/example/issues/123",
              "labels": [
                {"name": "feature"},
                {"name": "ios"}
              ],
              "comments": [
                {
                  "author": {"login": "alice"},
                  "body": "First comment",
                  "createdAt": "2026-03-29T12:00:00Z",
                  "url": "https://github.com/octo/example/issues/123#issuecomment-1"
                }
              ]
            }
            """.utf8
        )
        let populated = try service.decodeIssueDetails(from: populatedData)
        #expect(populated.labels == ["feature", "ios"])
        #expect(populated.comments.count == 1)
        #expect(populated.comments.first?.author == "alice")

        let emptyData = Data(
            """
            {
              "number": 124,
              "title": "Empty issue",
              "body": null,
              "url": "https://github.com/octo/example/issues/124",
              "labels": [],
              "comments": []
            }
            """.utf8
        )
        let empty = try service.decodeIssueDetails(from: emptyData)
        #expect(empty.body.isEmpty)
        #expect(empty.labels.isEmpty)
        #expect(empty.comments.isEmpty)
    }

    @Test
    func gitHubCreatePRUsesSupportedCLIFlowAndParsesCreatedURL() async throws {
        actor CommandRecorder {
            private var commands: [(String, [String], String?, [String: String])] = []

            func append(
                executable: String,
                arguments: [String],
                directory: URL?,
                environment: [String: String]
            ) {
                commands.append((executable, arguments, directory?.path, environment))
            }

            func snapshot() -> [(String, [String], String?, [String: String])] {
                commands
            }
        }

        let recorder = CommandRecorder()
        let worktree = try temporaryDirectory(named: "gh-create-pr")
        let service = GitHubCLIService(
            runCommand: { executable, arguments, currentDirectoryURL, environment in
                await recorder.append(
                    executable: executable,
                    arguments: arguments,
                    directory: currentDirectoryURL,
                    environment: environment
                )
                if executable == "gh",
                   arguments == [
                       "pr", "create",
                       "--title", "Feature title",
                       "--body", "PR body",
                       "--base", "main",
                   ]
                {
                    return CommandResult(
                        stdout: """
                        Creating pull request for feature-branch into main in octo/example

                        https://github.com/octo/example/pull/42
                        """,
                        stderr: "",
                        exitCode: 0
                    )
                }
                if executable == "gh",
                   arguments == ["pr", "view", "https://github.com/octo/example/pull/42", "--json", "number,url"]
                {
                    return CommandResult(
                        stdout: #"{"number":42,"url":"https://github.com/octo/example/pull/42"}"#,
                        stderr: "",
                        exitCode: 0
                    )
                }

                Issue.record("Unexpected command: \(executable) \(arguments.joined(separator: " "))")
                return CommandResult(stdout: "", stderr: "", exitCode: 1)
            },
            environmentProvider: { ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"] }
        )

        let prInfo = try await service.createPR(
            worktreePath: worktree,
            title: "Feature title",
            body: "PR body",
            baseBranch: "main"
        )

        #expect(prInfo.number == 42)
        #expect(prInfo.url == "https://github.com/octo/example/pull/42")

        let commands = await recorder.snapshot()
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.2 == worktree.path })
        #expect(commands.allSatisfy { $0.3["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin" })
    }

    @Test
    func gitHubCreatePRPropagatesCreateFailures() async throws {
        let worktree = try temporaryDirectory(named: "gh-create-pr-error")
        let service = GitHubCLIService(
            runCommand: { executable, arguments, _, _ in
                if executable == "gh",
                   arguments == [
                       "pr", "create",
                       "--title", "Feature title",
                       "--body", " ",
                       "--base", "main",
                   ]
                {
                    return CommandResult(stdout: "", stderr: "unknown flag: --json", exitCode: 1)
                }

                Issue.record("Unexpected command: \(executable) \(arguments.joined(separator: " "))")
                return CommandResult(stdout: "", stderr: "", exitCode: 1)
            },
            environmentProvider: { ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"] }
        )

        do {
            _ = try await service.createPR(
                worktreePath: worktree,
                title: "Feature title",
                body: "",
                baseBranch: "main"
            )
            Issue.record("Expected createPR to throw.")
        } catch let error as StackriotError {
            guard case let .commandFailed(message) = error else {
                Issue.record("Unexpected StackriotError: \(error)")
                return
            }
            #expect(message == "unknown flag: --json")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func gitHubCreatePRFallsBackToNumberFromURLWhenViewOutputCannotBeDecoded() async throws {
        let worktree = try temporaryDirectory(named: "gh-create-pr-fallback")
        let service = GitHubCLIService(
            runCommand: { executable, arguments, _, _ in
                if executable == "gh",
                   arguments == [
                       "pr", "create",
                       "--title", "Feature title",
                       "--body", "PR body",
                       "--base", "main",
                   ]
                {
                    return CommandResult(
                        stdout: """
                        Warning: using default repository
                        https://github.com/octo/example/pull/77
                        """,
                        stderr: "",
                        exitCode: 0
                    )
                }
                if executable == "gh",
                   arguments == ["pr", "view", "https://github.com/octo/example/pull/77", "--json", "number,url"]
                {
                    return CommandResult(stdout: "not-json", stderr: "", exitCode: 0)
                }

                Issue.record("Unexpected command: \(executable) \(arguments.joined(separator: " "))")
                return CommandResult(stdout: "", stderr: "", exitCode: 1)
            },
            environmentProvider: { ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"] }
        )

        let prInfo = try await service.createPR(
            worktreePath: worktree,
            title: "Feature title",
            body: "PR body",
            baseBranch: "main"
        )

        #expect(prInfo.number == 77)
        #expect(prInfo.url == "https://github.com/octo/example/pull/77")
    }

    @MainActor
    @Test
    func jiraReadinessRequiresConfigurationAndReportsAuthFailures() async {
        let repository = makeRepository(name: "Jira")

        let missingConfiguration = JiraCloudService(
            configurationProvider: { JiraConfiguration(baseURL: "", userEmail: "", apiToken: nil) },
            performRequest: { _ in
                Issue.record("Unexpected request")
                return (Data(), URLResponse())
            }
        )
        let missingConfigurationStatus = await missingConfiguration.readiness(for: repository)
        #expect(!missingConfigurationStatus.isAvailable)
        #expect(missingConfigurationStatus.message.contains("Jira Cloud"))

        let failingService = JiraCloudService(
            configurationProvider: {
                JiraConfiguration(
                    baseURL: "https://example.atlassian.net",
                    userEmail: "user@example.com",
                    apiToken: "token"
                )
            },
            performRequest: { request in
                #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
                let response = HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = Data(#"{"errorMessages":["Unauthorized"],"errors":{}}"#.utf8)
                return (data, response)
            }
        )
        let failingStatus = await failingService.readiness(for: repository)
        #expect(!failingStatus.isAvailable)
        #expect(failingStatus.message.contains("Unauthorized") || failingStatus.message.contains("Authentifizierung"))
    }

    @Test
    func jiraSearchResultsAndDetailsDecodeFromJSON() throws {
        let service = JiraCloudService(
            configurationProvider: {
                JiraConfiguration(
                    baseURL: "https://example.atlassian.net",
                    userEmail: "user@example.com",
                    apiToken: "token"
                )
            },
            performRequest: { _ in
                Issue.record("Unexpected request")
                return (Data(), URLResponse())
            }
        )
        let searchData = Data(
            """
            {
              "issues": [
                {
                  "key": "ABC-123",
                  "fields": {
                    "summary": "Import Jira tickets",
                    "status": { "name": "In Progress" }
                  }
                }
              ]
            }
            """.utf8
        )

        let searchResults = try service.decodeSearchResults(from: searchData, baseURL: "https://example.atlassian.net")
        #expect(searchResults == [
            TicketSearchResult(
                reference: TicketReference(provider: .jira, id: "ABC-123", displayID: "ABC-123"),
                title: "Import Jira tickets",
                url: "https://example.atlassian.net/browse/ABC-123",
                status: "In Progress"
            )
        ])

        let detailsData = Data(
            """
            {
              "key": "ABC-123",
              "fields": {
                "summary": "Import Jira tickets",
                "description": {
                  "type": "doc",
                  "content": [
                    {
                      "type": "paragraph",
                      "content": [
                        { "type": "text", "text": "Beschreibung aus Jira." }
                      ]
                    }
                  ]
                },
                "labels": ["ios", "feature"],
                "comment": {
                  "comments": [
                    {
                      "author": { "displayName": "Alice", "accountId": "abc" },
                      "created": "2026-03-30T07:00:00Z",
                      "body": {
                        "type": "doc",
                        "content": [
                          {
                            "type": "paragraph",
                            "content": [
                              { "type": "text", "text": "Bitte in Plan uebernehmen." }
                            ]
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
            """.utf8
        )

        let details = try service.decodeTicketDetails(from: detailsData, baseURL: "https://example.atlassian.net")
        #expect(details.reference.displayID == "ABC-123")
        #expect(details.body == "Beschreibung aus Jira.")
        #expect(details.labels == ["ios", "feature"])
        #expect(details.comments.count == 1)
        #expect(details.comments.first?.author == "Alice")
        #expect(details.comments.first?.body == "Bitte in Plan uebernehmen.")
    }

    @MainActor
    @Test
    func jiraSearchTicketsUsesSearchJQLEndpointAndPreservesDecodedFields() async throws {
        let repository = makeRepository(name: "Jira Search")
        let service = JiraCloudService(
            configurationProvider: {
                JiraConfiguration(
                    baseURL: "https://example.atlassian.net",
                    userEmail: "user@example.com",
                    apiToken: "token"
                )
            },
            performRequest: { request in
                let url = try #require(request.url)
                #expect(request.httpMethod == "GET")
                #expect(url.path == "/rest/api/3/search/jql")
                let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                #expect(queryItems["jql"] == #"summary ~ "Import Jira tickets" ORDER BY updated DESC"#)
                #expect(queryItems["maxResults"] == "20")
                #expect(queryItems["fields"] == "summary,status")
                #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)

                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = Data(
                    """
                    {
                      "issues": [
                        {
                          "key": "ABC-123",
                          "fields": {
                            "summary": "Import Jira tickets",
                            "status": { "name": "In Progress" }
                          }
                        }
                      ]
                    }
                    """.utf8
                )
                return (data, response)
            }
        )

        let results = try await service.searchTickets(query: "Import Jira tickets", in: repository)
        #expect(results == [
            TicketSearchResult(
                reference: TicketReference(provider: .jira, id: "ABC-123", displayID: "ABC-123"),
                title: "Import Jira tickets",
                url: "https://example.atlassian.net/browse/ABC-123",
                status: "In Progress"
            )
        ])
    }

    @MainActor
    @Test
    func jiraSearchTicketsPropagatesAPIErrors() async {
        let repository = makeRepository(name: "Jira Search Error")
        let service = JiraCloudService(
            configurationProvider: {
                JiraConfiguration(
                    baseURL: "https://example.atlassian.net",
                    userEmail: "user@example.com",
                    apiToken: "token"
                )
            },
            performRequest: { request in
                let response = HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = Data(#"{"errorMessages":["JQL is not permitted"],"errors":{}}"#.utf8)
                return (data, response)
            }
        )

        do {
            _ = try await service.searchTickets(query: "ABC-123", in: repository)
            Issue.record("Expected Jira search to fail")
        } catch {
            #expect(error.localizedDescription.contains("JQL is not permitted"))
        }
    }

    @MainActor
    @Test
    func initialPlanIncludesProviderNeutralJiraTicketDetails() {
        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        let ticket = TicketDetails(
            reference: TicketReference(provider: .jira, id: "ABC-123", displayID: "ABC-123"),
            title: "Jira Plan",
            body: "Beschreibung aus Jira.",
            url: "https://example.atlassian.net/browse/ABC-123",
            labels: ["ios"],
            comments: [
                TicketComment(
                    author: "Alice",
                    body: "Kommentar aus Jira.",
                    createdAt: Date(timeIntervalSince1970: 1_743_318_000),
                    url: nil
                )
            ]
        )

        let plan = appModel.initialPlan(from: ticket)
        #expect(plan.contains("- Provider: Jira Cloud"))
        #expect(plan.contains("- Ticket: ABC-123"))
        #expect(plan.contains("Beschreibung aus Jira."))
        #expect(plan.contains("Kommentar aus Jira."))
    }

    @MainActor
    @Test
    func ticketWorktreeCreationNormalizesBranchSetsIssueContextAndWritesPlan() async throws {
        let remote = try await createSeededRemote(named: "ticket-worktree")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Ticket-Worktree-\(UUID().uuidString)"
        )
        let modelContext = try makeInMemoryModelContext()
        let repository = ManagedRepository(
            displayName: cloneInfo.displayName,
            remoteURL: remote.remote.absoluteString,
            bareRepositoryPath: cloneInfo.bareRepositoryPath.path,
            defaultBranch: cloneInfo.defaultBranch
        )
        modelContext.insert(repository)
        try modelContext.save()

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext
        appModel.worktreeDraft = WorktreeDraft(sourceBranch: cloneInfo.defaultBranch)
        appModel.worktreeDraft.branchName = "  Feature A  "
        appModel.worktreeDraft.ticketProvider = .github
        appModel.worktreeDraft.ticketProviderStatus = TicketProviderStatus(provider: .github, isAvailable: true, message: "ready")
        appModel.worktreeDraft.selectedTicket = GitHubIssueSearchResult(
            number: 123,
            title: "Ticket backed worktree",
            url: "https://github.com/octo/example/issues/123",
            state: "OPEN"
        )
        appModel.worktreeDraft.selectedIssueDetails = GitHubIssueDetails(
            number: 123,
            title: "Ticket backed worktree",
            body: "Use the selected issue as plan input.",
            url: "https://github.com/octo/example/issues/123",
            labels: ["feature", "ios"],
            comments: [
                GitHubIssueComment(
                    author: "alice",
                    body: "Please include comments in the initial plan.",
                    createdAt: Date(timeIntervalSince1970: 1_743_249_600),
                    url: "https://github.com/octo/example/issues/123#issuecomment-1"
                )
            ]
        )
        appModel.worktreeDraft.hasConfirmedTicket = true

        await appModel.createWorktreeFromTicket(for: repository, in: modelContext)

        #expect(appModel.pendingErrorMessage == nil)
        #expect(repository.worktrees.count == 1)

        guard let worktree = repository.worktrees.first else {
            Issue.record("Expected created worktree record")
            return
        }

        #expect(worktree.branchName == "Feature-A")
        #expect(worktree.kind == .idea)
        #expect(worktree.sourceBranch == cloneInfo.defaultBranch)
        #expect(worktree.materializedPath == nil)
        #expect(worktree.destinationRootPath == nil)
        #expect(worktree.issueContext == "#123 Ticket backed worktree")
        #expect(worktree.ticketProvider == .github)
        #expect(worktree.ticketIdentifier == "123")
        #expect(worktree.ticketURL == "https://github.com/octo/example/issues/123")
        #expect(!FileManager.default.fileExists(atPath: worktree.projectedMaterializationPath ?? ""))

        let intentURL = AppPaths.intentFile(for: worktree.id)
        let plan = try String(contentsOf: intentURL, encoding: .utf8)
        #expect(plan.contains("# Ticket backed worktree"))
        #expect(plan.contains("- Provider: GitHub"))
        #expect(plan.contains("- Issue: #123"))
        #expect(plan.contains("## Beschreibung"))
        #expect(plan.contains("## Kommentare"))
        #expect(plan.contains("### alice - 2025-03-29T12:00:00Z"))

        try? FileManager.default.removeItem(at: intentURL)
        try? FileManager.default.removeItem(at: cloneInfo.bareRepositoryPath)
    }

    @MainActor
    @Test
    func jiraTicketWorktreeCreationStoresProviderMetadataAndWritesPlan() async throws {
        let remote = try await createSeededRemote(named: "jira-ticket-worktree")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Jira-Ticket-Worktree-\(UUID().uuidString)"
        )
        let modelContext = try makeInMemoryModelContext()
        let repository = ManagedRepository(
            displayName: cloneInfo.displayName,
            remoteURL: remote.remote.absoluteString,
            bareRepositoryPath: cloneInfo.bareRepositoryPath.path,
            defaultBranch: cloneInfo.defaultBranch
        )
        modelContext.insert(repository)
        try modelContext.save()

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext
        appModel.worktreeDraft = WorktreeDraft(sourceBranch: cloneInfo.defaultBranch)
        appModel.worktreeDraft.branchName = "feature/abc-123-import-jira"
        appModel.worktreeDraft.ticketProvider = .jira
        appModel.worktreeDraft.ticketProviderStatuses = [
            TicketProviderStatus(provider: .jira, isAvailable: true, message: "ready"),
        ]
        appModel.worktreeDraft.selectedTicket = TicketSearchResult(
            reference: TicketReference(provider: .jira, id: "ABC-123", displayID: "ABC-123"),
            title: "Import Jira tickets",
            url: "https://example.atlassian.net/browse/ABC-123",
            status: "In Progress"
        )
        appModel.worktreeDraft.selectedIssueDetails = TicketDetails(
            reference: TicketReference(provider: .jira, id: "ABC-123", displayID: "ABC-123"),
            title: "Import Jira tickets",
            body: "Beschreibung aus Jira.",
            url: "https://example.atlassian.net/browse/ABC-123",
            labels: ["ios", "feature"],
            comments: [
                TicketComment(
                    author: "alice",
                    body: "Kommentar aus Jira.",
                    createdAt: Date(timeIntervalSince1970: 1_743_249_600),
                    url: nil
                )
            ]
        )
        appModel.worktreeDraft.hasConfirmedTicket = true

        await appModel.createWorktreeFromTicket(for: repository, in: modelContext)

        #expect(appModel.pendingErrorMessage == nil)
        #expect(repository.worktrees.count == 1)

        guard let worktree = repository.worktrees.first else {
            Issue.record("Expected created Jira worktree record")
            return
        }

        #expect(worktree.kind == .idea)
        #expect(worktree.materializedPath == nil)
        #expect(worktree.issueContext == "ABC-123 Import Jira tickets")
        #expect(worktree.ticketProvider == .jira)
        #expect(worktree.ticketIdentifier == "ABC-123")
        #expect(worktree.ticketURL == "https://example.atlassian.net/browse/ABC-123")

        let intentURL = AppPaths.intentFile(for: worktree.id)
        let plan = try String(contentsOf: intentURL, encoding: .utf8)
        #expect(plan.contains("- Provider: Jira Cloud"))
        #expect(plan.contains("- Ticket: ABC-123"))
        #expect(plan.contains("Kommentar aus Jira."))

        try? FileManager.default.removeItem(at: intentURL)
        try? FileManager.default.removeItem(at: cloneInfo.bareRepositoryPath)
    }

    @MainActor
    @Test
    func createWorktreeDoesNotRequireConfirmedTicketWhenGitHubIsAvailable() async throws {
        let remote = try await createSeededRemote(named: "manual-worktree")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Manual-Worktree-\(UUID().uuidString)"
        )
        let destinationRoot = try temporaryDirectory(named: "manual-worktree-root")
        let modelContext = try makeInMemoryModelContext()
        let repository = ManagedRepository(
            displayName: cloneInfo.displayName,
            remoteURL: remote.remote.absoluteString,
            bareRepositoryPath: cloneInfo.bareRepositoryPath.path,
            defaultBranch: cloneInfo.defaultBranch
        )
        modelContext.insert(repository)
        try modelContext.save()

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext
        appModel.worktreeDraft = WorktreeDraft(sourceBranch: cloneInfo.defaultBranch)
        appModel.worktreeDraft.branchName = "Feature Without Ticket"
        appModel.worktreeDraft.issueContext = "Manual context"
        appModel.worktreeDraft.destinationRootPath = destinationRoot.path
        appModel.worktreeDraft.ticketProvider = .github
        appModel.worktreeDraft.ticketProviderStatus = TicketProviderStatus(provider: .github, isAvailable: true, message: "ready")

        await appModel.createWorktree(for: repository, in: modelContext)

        #expect(appModel.pendingErrorMessage == nil)
        #expect(repository.worktrees.count == 1)
        #expect(repository.worktrees.first?.issueContext == "Manual context")
        #expect(repository.worktrees.first?.kind == .idea)
        #expect(repository.worktrees.first?.materializedPath == nil)
        #expect(repository.worktrees.first?.destinationRootPath == destinationRoot.path)
        #expect(repository.worktrees.first?.sourceBranch == cloneInfo.defaultBranch)
        #expect(repository.worktrees.first?.projectedMaterializationPath?.hasPrefix(destinationRoot.path + "/") == true)
        #expect(!FileManager.default.fileExists(atPath: repository.worktrees.first?.projectedMaterializationPath ?? ""))

        if let worktree = repository.worktrees.first {
            try? FileManager.default.removeItem(at: AppPaths.intentFile(for: worktree.id))
        }
        try? FileManager.default.removeItem(at: destinationRoot)
        try? FileManager.default.removeItem(at: cloneInfo.bareRepositoryPath)
    }

    @MainActor
    @Test
    func createPlanMaterializesIdeaTreeBeforeStartingDraft() async throws {
        let remote = try await createSeededRemote(named: "idea-plan-materialize")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Idea-Plan-\(UUID().uuidString)"
        )
        let modelContext = try makeInMemoryModelContext()
        let repository = ManagedRepository(
            displayName: cloneInfo.displayName,
            remoteURL: remote.remote.absoluteString,
            bareRepositoryPath: cloneInfo.bareRepositoryPath.path,
            defaultBranch: cloneInfo.defaultBranch
        )
        modelContext.insert(repository)
        try modelContext.save()

        let appModel = AppModel(services: AppServices(notificationService: RecordingNotificationService()))
        appModel.storedModelContext = modelContext
        appModel.availableAgents = [.codex]
        let worktree = WorktreeRecord(
            branchName: "feature/idea-plan",
            kind: .idea,
            sourceBranch: cloneInfo.defaultBranch,
            repository: repository
        )
        repository.worktrees = [worktree]

        await appModel.startAgentPlanDraft(
            using: .codex,
            for: worktree,
            in: repository,
            currentIntentText: "Investigate the feature work",
            modelContext: modelContext
        )

        #expect(worktree.kind == .regular)
        #expect(worktree.materializedPath != nil)
        #expect(FileManager.default.fileExists(atPath: try #require(worktree.materializedPath)))
        #expect(appModel.agentPlanDraft(for: worktree.id) != nil)

        if let worktreePath = worktree.materializedPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: worktreePath))
        }
        try? FileManager.default.removeItem(at: cloneInfo.bareRepositoryPath)
    }

    @MainActor
    @Test
    func prepareCopilotExecutionWithPlanMaterializesIdeaTree() async throws {
        let remote = try await createSeededRemote(named: "idea-execute-materialize")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "Idea-Execute-\(UUID().uuidString)"
        )
        let modelContext = try makeInMemoryModelContext()
        let repository = ManagedRepository(
            displayName: cloneInfo.displayName,
            remoteURL: remote.remote.absoluteString,
            bareRepositoryPath: cloneInfo.bareRepositoryPath.path,
            defaultBranch: cloneInfo.defaultBranch
        )
        modelContext.insert(repository)
        try modelContext.save()

        let discovery = CopilotModelDiscoveryService(
            runCommand: { _, _, _, _ in
                CommandResult(stdout: "", stderr: #"Error: Invalid value for option "--model" (choices: "gpt-5.4-mini")"#, exitCode: 1)
            },
            environmentProvider: { [:] }
        )
        let appModel = AppModel(services: AppServices(
            copilotModelDiscovery: discovery,
            notificationService: RecordingNotificationService()
        ))
        appModel.storedModelContext = modelContext
        appModel.availableAgents = [.githubCopilot]

        let worktree = WorktreeRecord(
            branchName: "feature/idea-execute",
            kind: .idea,
            sourceBranch: cloneInfo.defaultBranch,
            repository: repository
        )
        repository.worktrees = [worktree]
        appModel.saveIntent("Implement the feature", for: worktree.id)

        await appModel.prepareCopilotExecutionWithPlan(for: worktree, in: repository)

        let draft = try #require(appModel.pendingCopilotExecutionDraft)
        #expect(draft.promptText == "Implement the feature")
        #expect(worktree.kind == .regular)
        #expect(worktree.materializedPath != nil)
        #expect(FileManager.default.fileExists(atPath: try #require(worktree.materializedPath)))

        if let worktreePath = worktree.materializedPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: worktreePath))
        }
        try? FileManager.default.removeItem(at: cloneInfo.bareRepositoryPath)
    }

    @Test
    func codexPlanExtractorPrefersLastCompleteProposedPlanBlock() {
        let output = """
        Intro
        <proposed_plan>
        # First
        </proposed_plan>
        More output
        <proposed_plan>
        # Final
        - Step 1
        </proposed_plan>
        <proposed_plan>
        incomplete
        """

        let extracted = AppModel.extractLatestProposedPlanMarkdown(from: output)

        #expect(extracted == """
        # Final
        - Step 1
        """)
    }

    @Test
    func codexPlanResponseParserDecodesStructuredQuestions() {
        let response = AppModel.parseCodexPlanResponse(from: """
        {
          "status": "needs_user_input",
          "summary": "Need product clarification before planning.",
          "questions": [
            "Should the generated plan replace the current draft immediately?",
            "Do you want implementation details or only milestones?"
          ]
        }
        """)

        #expect(response?.status == .needsUserInput)
        #expect(response?.summary == "Need product clarification before planning.")
        #expect(response?.questions == [
            "Should the generated plan replace the current draft immediately?",
            "Do you want implementation details or only milestones?",
        ])
        #expect(response?.planMarkdown == nil)
    }

    @Test
    func codexPlanResponseParserRejectsNeedsUserInputWithoutQuestions() {
        let response = AppModel.parseCodexPlanResponse(from: """
        {
          "status": "needs_user_input",
          "summary": "Need product clarification before planning."
        }
        """)

        #expect(response == nil)
    }

    @Test
    func codexPlanResponseParserRejectsReadyWithoutPlanMarkdown() {
        let response = AppModel.parseCodexPlanResponse(from: """
        {
          "status": "ready",
          "summary": "Plan is ready."
        }
        """)

        #expect(response == nil)
    }

    @Test
    func cursorPrintedResponseParserExtractsSessionAndStructuredResult() {
        let parser = CursorAgentPrintJSONParser()
        let innerResult = """
        Got it. I will inspect the repository first.
        {"status":"ready","summary":"Plan is ready.","questions":null,"plan_markdown":"# Cursor Plan\\n- Inspect workspace"}
        """
        let firstEvent = String(
            data: try! JSONSerialization.data(withJSONObject: [
                "type": "message.delta",
                "session_id": "chat-123",
                "text": "Got it. ",
            ]),
            encoding: .utf8
        )! + "\n"
        let secondEvent = String(
            data: try! JSONSerialization.data(withJSONObject: [
                "type": "result",
                "result": innerResult,
                "session_id": "chat-123",
            ]),
            encoding: .utf8
        )! + "\n"

        _ = parser.consume(firstEvent)
        let streamedChunk = parser.consume(secondEvent)
        let finalChunk = parser.finish()
        let structuredResponse = AppModel.parseAgentPlanResponse(from: parser.latestResultText ?? "")

        #expect(parser.currentSessionID == "chat-123")
        #expect(parser.latestResultText?.contains("\"status\":\"ready\"") == true)
        #expect(streamedChunk.segments.contains(where: { $0.sourceAgent == .cursorCLI }))
        #expect(streamedChunk.renderedText.contains("Got it."))
        #expect(finalChunk.renderedText.contains("cursor-agent --resume chat-123"))
        #expect(structuredResponse?.planMarkdown == "# Cursor Plan\n- Inspect workspace")
    }

    @Test
    func cursorParserMergesThinkingDeltasIntoOneSegment() {
        let parser = CursorAgentPrintJSONParser()
        let session = "8d539ee2-1f26-4c8c-b087-d59cbf5867a0"
        func thinkingLine(_ text: String, subtype: String) -> String {
            let o: [String: Any] = [
                "type": "thinking",
                "subtype": subtype,
                "text": text,
                "session_id": session,
            ]
            return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
        }

        var merged = StructuredAgentOutputChunk()
        merged.append(parser.consume(thinkingLine("The user is wri", subtype: "delta")))
        merged.append(parser.consume(thinkingLine("ting in German.", subtype: "delta")))
        merged.append(parser.consume(thinkingLine("", subtype: "completed")))

        let reasoning = merged.segments.filter { $0.kind == .reasoning }
        let ids = Set(reasoning.map(\.id))
        #expect(ids.count == 1)
        #expect(ids.first == "\(session)-thinking")
        #expect(reasoning.last?.bodyText == "The user is writing in German.")
        #expect(reasoning.last?.status == .completed)
    }

    @Test
    func cursorParserMergesToolCallStartedAndCompletedByCallID() {
        let parser = CursorAgentPrintJSONParser()
        let session = "chat-123"
        let callID = "tool_call-1"
        let toolCallInner: [String: Any] = [
            "semSearchToolCall": [
                "args": ["query": "find", "targetDirectories": []],
            ] as [String: Any],
        ]
        let started: [String: Any] = [
            "type": "tool_call",
            "subtype": "started",
            "call_id": callID,
            "session_id": session,
            "tool_call": toolCallInner,
        ]
        let completed: [String: Any] = [
            "type": "tool_call",
            "subtype": "completed",
            "call_id": callID,
            "session_id": session,
            "tool_call": [
                "semSearchToolCall": [
                    "result": ["error": ["errorMessage": "Tool failed; this may be temporary. Try again."]],
                ] as [String: Any],
            ] as [String: Any],
        ]

        var merged = StructuredAgentOutputChunk()
        merged.append(parser.consume(String(data: try! JSONSerialization.data(withJSONObject: started), encoding: .utf8)! + "\n"))
        merged.append(parser.consume(String(data: try! JSONSerialization.data(withJSONObject: completed), encoding: .utf8)! + "\n"))

        let tools = merged.segments.filter { $0.kind == .toolCall }
        #expect(tools.count == 1)
        #expect(tools.first?.id == callID)
        #expect(tools.first?.status == .failed)
        #expect(tools.first?.aggregatedOutput?.contains("Tool failed") == true)
    }

    @Test
    func cursorParserMergesAssistantDeltasWithSameModelCallID() {
        let parser = CursorAgentPrintJSONParser()
        let session = "chat-123"
        let modelCall = "af3aac61-a4f0-4ab8-96c5-335eb768579d-1-njq2"
        func assistantLine(_ text: String) -> String {
            let content: [[String: Any]] = [["type": "text", "text": text]]
            let o: [String: Any] = [
                "type": "assistant",
                "session_id": session,
                "model_call_id": modelCall,
                "message": [
                    "role": "assistant",
                    "content": content,
                ] as [String: Any],
            ]
            return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
        }

        var merged = StructuredAgentOutputChunk()
        merged.append(parser.consume(assistantLine("Wir setzen ")))
        merged.append(parser.consume(assistantLine("Wir setzen `.keyboardShortcut` wie in anderen Sheets.")))

        let messages = merged.segments.filter { $0.kind == .agentMessage }
        #expect(Set(messages.map(\.id)) == [modelCall])
        #expect(messages.last?.bodyText == "Wir setzen `.keyboardShortcut` wie in anderen Sheets.")
    }

    @Test
    func cursorParserIgnoresWhitespaceOnlyAssistantMessageWithoutFallbackSegment() {
        let parser = CursorAgentPrintJSONParser()
        let session = "1690b03e-2db8-4cd8-aab4-ba772c07f05c"
        let content: [[String: Any]] = [["type": "text", "text": "\n\n\n"]]
        let o: [String: Any] = [
            "type": "assistant",
            "session_id": session,
            "message": [
                "role": "assistant",
                "content": content,
            ] as [String: Any],
            "timestamp_ms": 1774876090804,
        ]
        let line = String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
        let merged = parser.consume(line)
        #expect(merged.segments.isEmpty)
    }

    @Test
    func cursorParserSystemInitUpdatesSessionAndEmitsNoSegments() {
        let parser = CursorAgentPrintJSONParser()
        let o: [String: Any] = [
            "type": "system",
            "subtype": "init",
            "apiKeySource": "login",
            "cwd": "/tmp",
            "session_id": "session-abc",
            "model": "Auto",
            "permissionMode": "default",
        ]
        let line = String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
        let merged = parser.consume(line)
        #expect(merged.segments.isEmpty)
        #expect(parser.currentSessionID == "session-abc")
    }

    @Test
    func cursorPlanResponseParserExtractsEmbeddedStructuredJSON() {
        let structuredResponse = AppModel.parseAgentPlanResponse(from: """
        Got it. I'll scan the worktree and then return the plan.

        {
          "status": "ready",
          "summary": "Plan is ready.",
          "questions": null,
          "plan_markdown": "# Embedded Cursor Plan\\n- Inspect workspace\\n- Update plan tab"
        }
        """)

        #expect(structuredResponse?.summary == "Plan is ready.")
        #expect(structuredResponse?.planMarkdown == """
        # Embedded Cursor Plan
        - Inspect workspace
        - Update plan tab
        """)
    }

    @MainActor
    @Test
    func cursorPlanImportUsesSharedStructuredSchema() throws {
        let defaults = try makeUserDefaultsSuite()
        let appModel = AppModel(userDefaults: defaults)
        let repository = makeRepository(name: "CursorPlanStructuredImport")
        let worktree = WorktreeRecord(
            branchName: "feature/cursor-plan",
            issueContext: "Create the feature plan",
            path: "/tmp/cursor-plan-structured-import",
            repository: repository
        )
        repository.worktrees = [worktree]
        try appModel.writeIntent("Original plan", for: worktree.id)
        let responseURL = URL(fileURLWithPath: "/tmp/cursor-plan-response-\(UUID().uuidString).json")
        try """
        {
          "status": "ready",
          "summary": "Plan is ready.",
          "questions": null,
          "plan_markdown": "# Cursor Structured Plan\\n- Inspect flow\\n- Replace plan page"
        }
        """.write(to: responseURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: AppPaths.intentFile(for: worktree.id))
            try? FileManager.default.removeItem(at: AppPaths.implementationPlanFile(for: worktree.id))
            try? FileManager.default.removeItem(at: responseURL)
        }

        let run = RunRecord(
            actionKind: .aiAgent,
            title: "Cursor Plan",
            commandLine: "cursor-agent --print --output-format stream-json --stream-partial-output",
            outputText: "Noise only\n",
            status: .succeeded,
            worktreeID: worktree.id,
            repository: repository,
            worktree: worktree
        )
        run.isTransientPlanRun = true
        appModel.agentPlanDraftsByWorktreeID[worktree.id] = AgentPlanDraft(
            tool: .cursorCLI,
            worktreeID: worktree.id,
            repositoryID: repository.id,
            branchName: worktree.branchName,
            issueContext: worktree.issueContext ?? "",
            run: run,
            responseFilePath: responseURL.path
        )
        appModel.activeAgentPlanDraftWorktreeID = worktree.id

        appModel.importCompletedAgentPlanIfAvailable(forRunID: run.id)

        let importedPlan = try String(contentsOf: AppPaths.implementationPlanFile(for: worktree.id), encoding: .utf8)
        #expect(importedPlan == """
        # Cursor Structured Plan
        - Inspect flow
        - Replace plan page
        """)
        #expect(try String(contentsOf: AppPaths.intentFile(for: worktree.id), encoding: .utf8) == "Original plan")
        #expect(appModel.agentPlanDraft(for: worktree.id) == nil)
        #expect(appModel.activeAgentPlanDraftWorktreeID == nil)
    }

    @MainActor
    @Test
    func codexPlanImportReplacesPersistedPlanWithExtractedMarkdown() throws {
        let defaults = try makeUserDefaultsSuite()
        let appModel = AppModel(userDefaults: defaults)
        let repository = makeRepository(name: "CodexPlanImport")
        let worktree = WorktreeRecord(
            branchName: "feature/codex-plan",
            issueContext: "Create the feature plan",
            path: "/tmp/codex-plan-import",
            repository: repository
        )
        repository.worktrees = [worktree]
        try appModel.writeIntent("Original plan", for: worktree.id)
        defer {
            try? FileManager.default.removeItem(at: AppPaths.intentFile(for: worktree.id))
            try? FileManager.default.removeItem(at: AppPaths.implementationPlanFile(for: worktree.id))
        }

        let run = RunRecord(
            actionKind: .aiAgent,
            title: "Codex Plan",
            commandLine: "codex",
            outputText: """
            Noise
            <proposed_plan>
            # Imported Plan
            - Build the sheet
            - Replace the plan file
            </proposed_plan>
            """,
            status: .succeeded,
            worktreeID: worktree.id,
            repository: repository,
            worktree: worktree
        )
        run.isTransientPlanRun = true
        appModel.agentPlanDraftsByWorktreeID[worktree.id] = AgentPlanDraft(tool: .codex, 
            worktreeID: worktree.id,
            repositoryID: repository.id,
            branchName: worktree.branchName,
            issueContext: worktree.issueContext ?? "",
            run: run
        )
        appModel.activeAgentPlanDraftWorktreeID = worktree.id

        appModel.importCompletedCodexPlanIfAvailable(forRunID: run.id)

        let importedPlan = try String(contentsOf: AppPaths.implementationPlanFile(for: worktree.id), encoding: .utf8)
        #expect(importedPlan == """
        # Imported Plan
        - Build the sheet
        - Replace the plan file
        """)
        #expect(appModel.implementationPlanContentVersion(for: worktree.id) == 1)
        #expect(appModel.codexPlanDraft(for: worktree.id) == nil)
        #expect(appModel.activeAgentPlanDraftWorktreeID == nil)
    }

    @MainActor
    @Test
    func codexPlanImportPrefersStructuredResponseFile() throws {
        let defaults = try makeUserDefaultsSuite()
        let appModel = AppModel(userDefaults: defaults)
        let repository = makeRepository(name: "CodexPlanStructuredImport")
        let worktree = WorktreeRecord(
            branchName: "feature/structured-plan",
            issueContext: "Create the feature plan",
            path: "/tmp/codex-plan-structured-import",
            repository: repository
        )
        repository.worktrees = [worktree]
        try appModel.writeIntent("Original plan", for: worktree.id)
        let responseURL = URL(fileURLWithPath: "/tmp/codex-plan-response-\(UUID().uuidString).json")
        try """
        {
          "status": "ready",
          "summary": "Plan is ready.",
          "plan_markdown": "# Structured Plan\\n- Inspect flow\\n- Replace plan page"
        }
        """.write(to: responseURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: AppPaths.intentFile(for: worktree.id))
            try? FileManager.default.removeItem(at: AppPaths.implementationPlanFile(for: worktree.id))
            try? FileManager.default.removeItem(at: responseURL)
        }

        let run = RunRecord(
            actionKind: .aiAgent,
            title: "Codex Plan",
            commandLine: "codex exec --json",
            outputText: "Noise only\n",
            status: .succeeded,
            worktreeID: worktree.id,
            repository: repository,
            worktree: worktree
        )
        run.isTransientPlanRun = true
        appModel.agentPlanDraftsByWorktreeID[worktree.id] = AgentPlanDraft(tool: .codex, 
            worktreeID: worktree.id,
            repositoryID: repository.id,
            branchName: worktree.branchName,
            issueContext: worktree.issueContext ?? "",
            run: run,
            responseFilePath: responseURL.path
        )
        appModel.activeAgentPlanDraftWorktreeID = worktree.id

        appModel.importCompletedCodexPlanIfAvailable(forRunID: run.id)

        let importedPlan = try String(contentsOf: AppPaths.implementationPlanFile(for: worktree.id), encoding: .utf8)
        #expect(importedPlan == """
        # Structured Plan
        - Inspect flow
        - Replace plan page
        """)
        #expect(appModel.codexPlanDraft(for: worktree.id) == nil)
    }

    @MainActor
    @Test
    func codexPlanImportKeepsExistingPlanWhenNoCompleteBlockExists() throws {
        let defaults = try makeUserDefaultsSuite()
        let appModel = AppModel(userDefaults: defaults)
        let repository = makeRepository(name: "CodexPlanNoImport")
        let worktree = WorktreeRecord(
            branchName: "feature/no-import",
            issueContext: "Keep the current plan",
            path: "/tmp/codex-plan-no-import",
            repository: repository
        )
        repository.worktrees = [worktree]
        try appModel.writeIntent("Existing plan", for: worktree.id)
        defer {
            try? FileManager.default.removeItem(at: AppPaths.intentFile(for: worktree.id))
            try? FileManager.default.removeItem(at: AppPaths.implementationPlanFile(for: worktree.id))
        }

        let run = RunRecord(
            actionKind: .aiAgent,
            title: "Codex Plan",
            commandLine: "codex",
            outputText: """
            Codex is still thinking.
            <proposed_plan>
            # Incomplete
            """,
            status: .running,
            worktreeID: worktree.id,
            repository: repository,
            worktree: worktree
        )
        run.isTransientPlanRun = true
        appModel.agentPlanDraftsByWorktreeID[worktree.id] = AgentPlanDraft(tool: .codex, 
            worktreeID: worktree.id,
            repositoryID: repository.id,
            branchName: worktree.branchName,
            issueContext: worktree.issueContext ?? "",
            run: run
        )
        appModel.activeAgentPlanDraftWorktreeID = worktree.id

        appModel.importCompletedCodexPlanIfAvailable(forRunID: run.id)

        let persistedIntent = try String(contentsOf: AppPaths.intentFile(for: worktree.id), encoding: .utf8)
        #expect(persistedIntent == "Existing plan")
        #expect(appModel.loadImplementationPlan(for: worktree.id).isEmpty)
        #expect(appModel.implementationPlanContentVersion(for: worktree.id) == 0)
        #expect(appModel.codexPlanDraft(for: worktree.id)?.runID == run.id)
        #expect(appModel.activeAgentPlanDraftWorktreeID == worktree.id)
    }

    @MainActor
    @Test
    func moveWorktreeUpdatesPersistedPath() async throws {
        let remote = try await createSeededRemote(named: "appmodel-move-worktree")
        let cloneInfo = try await RepositoryManager().cloneBareRepository(
            remoteURL: remote.remote,
            preferredName: "AppModel-Move-\(UUID().uuidString)"
        )
        let modelContext = try makeInMemoryModelContext()
        let repository = ManagedRepository(
            displayName: cloneInfo.displayName,
            remoteURL: remote.remote.absoluteString,
            bareRepositoryPath: cloneInfo.bareRepositoryPath.path,
            defaultBranch: cloneInfo.defaultBranch
        )
        let worktreeInfo = try await WorktreeManager().createWorktree(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            branchName: "feature/move-in-appmodel",
            sourceBranch: cloneInfo.defaultBranch,
            directoryName: "feature/move-in-appmodel"
        )
        let worktree = WorktreeRecord(
            branchName: worktreeInfo.branchName,
            path: worktreeInfo.path.path,
            repository: repository
        )
        repository.worktrees = [worktree]
        modelContext.insert(repository)
        modelContext.insert(worktree)
        try modelContext.save()

        let appModel = AppModel()
        appModel.storedModelContext = modelContext
        let destinationRoot = try temporaryDirectory(named: "appmodel-move-root")

        await appModel.moveWorktree(worktree, in: repository, to: destinationRoot, modelContext: modelContext)

        #expect(appModel.pendingErrorMessage == nil)
        #expect(worktree.path.hasPrefix(destinationRoot.path + "/"))
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        try? FileManager.default.removeItem(at: destinationRoot)
        try? FileManager.default.removeItem(at: cloneInfo.bareRepositoryPath)
    }

    private func createSeededRemote(named name: String) async throws -> (root: URL, remote: URL) {
        let origin = try temporaryDirectory(named: name)
        let remote = origin.appendingPathComponent("\(name).git")
        let checkout = origin.appendingPathComponent("checkout")

        try await runGit(["init", "--bare", remote.path], currentDirectoryURL: origin)
        try await runGit(["clone", remote.path, checkout.path], currentDirectoryURL: origin)
        try "hello".write(to: checkout.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await runGit(["-C", checkout.path, "add", "."], currentDirectoryURL: origin)
        try await runGit(["-C", checkout.path, "config", "user.email", "tests@example.com"], currentDirectoryURL: origin)
        try await runGit(["-C", checkout.path, "config", "user.name", "Stackriot Tests"], currentDirectoryURL: origin)
        try await runGit(["-C", checkout.path, "config", "commit.gpgsign", "false"], currentDirectoryURL: origin)
        try await runGit(["-C", checkout.path, "commit", "-m", "Initial"], currentDirectoryURL: origin)
        try await runGit(["-C", checkout.path, "push", "origin", "HEAD:main"], currentDirectoryURL: origin)
        try await runGit(["-C", remote.path, "symbolic-ref", "HEAD", "refs/heads/main"], currentDirectoryURL: origin)

        return (origin, remote)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StackriotTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + "-" + name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func configureGitIdentity(in directory: URL) async throws {
        try await runGit(["-C", directory.path, "config", "user.email", "tests@example.com"], currentDirectoryURL: directory)
        try await runGit(["-C", directory.path, "config", "user.name", "Stackriot Tests"], currentDirectoryURL: directory)
        try await runGit(["-C", directory.path, "config", "commit.gpgsign", "false"], currentDirectoryURL: directory)
    }

    private func cloneRemoteForEditing(_ remote: URL, name: String) async throws -> URL {
        let root = try temporaryDirectory(named: name)
        let checkout = root.appendingPathComponent("checkout")
        try await runGit(["clone", remote.path, checkout.path], currentDirectoryURL: root)
        try await configureGitIdentity(in: checkout)
        return checkout
    }

    private func commitAll(in directory: URL, message: String) async throws {
        try await runGit(["-C", directory.path, "add", "."], currentDirectoryURL: directory)
        try await runGit(["-C", directory.path, "commit", "-m", message], currentDirectoryURL: directory)
    }

    private func runGit(_ arguments: [String], currentDirectoryURL: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
        )
        #expect(result.exitCode == 0, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
    }

    @MainActor
    private func makeInMemoryModelContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RepositoryNamespace.self,
            RepositoryProject.self,
            ManagedRepository.self,
            RepositoryRemote.self,
            StoredSSHKey.self,
            WorktreeRecord.self,
            ActionTemplateRecord.self,
            RunRecord.self,
            AgentRawLogRecord.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func makeUserDefaultsSuite() throws -> UserDefaults {
        let suiteName = "StackriotTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "StackriotTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create UserDefaults suite"])
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeRepository(
        name: String,
        namespace: RepositoryNamespace? = nil,
        project: RepositoryProject? = nil
    ) -> ManagedRepository {
        ManagedRepository(
            displayName: name,
            bareRepositoryPath: "/tmp/\(name)",
            defaultBranch: "main",
            namespace: namespace,
            project: project
        )
    }
}

private struct DeliveredNotificationSnapshot: Sendable, Equatable {
    let identifier: String
    let title: String
    let subtitle: String
    let body: String
}

private final class TestUserNotificationCenter: UserNotificationCentering, @unchecked Sendable {
    private let lock = NSLock()
    private var currentAuthorizationStatus: UNAuthorizationStatus
    private var requestAuthorizationCallCountValue = 0
    private var deliveredRequests: [DeliveredNotificationSnapshot] = []
    private let authorizationGrantResult: Bool

    init(
        authorizationStatus: UNAuthorizationStatus,
        authorizationGrantResult: Bool = false
    ) {
        currentAuthorizationStatus = authorizationStatus
        self.authorizationGrantResult = authorizationGrantResult
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        lock.withLock { currentAuthorizationStatus }
    }

    func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool {
        lock.withLock {
            requestAuthorizationCallCountValue += 1
            currentAuthorizationStatus = authorizationGrantResult ? .authorized : .denied
        }
        return authorizationGrantResult
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock {
            deliveredRequests.append(
                DeliveredNotificationSnapshot(
                    identifier: request.identifier,
                    title: request.content.title,
                    subtitle: request.content.subtitle,
                    body: request.content.body
                )
            )
        }
    }

    var requestAuthorizationCallCount: Int {
        get async { lock.withLock { requestAuthorizationCallCountValue } }
    }

    func deliveredRequestSnapshots() async -> [DeliveredNotificationSnapshot] {
        lock.withLock { deliveredRequests }
    }
}

private actor RecordingNotificationService: AppNotificationServing {
    private(set) var deliveredRequests: [AppNotificationRequest] = []
    private(set) var prepareCallCount = 0

    @discardableResult
    func prepareAuthorization() async -> AppNotificationAuthorizationState {
        prepareCallCount += 1
        return .authorized
    }

    @discardableResult
    func deliver(_ request: AppNotificationRequest) async -> AppNotificationDeliveryResult {
        deliveredRequests.append(request)
        return .delivered
    }
}

private extension NSLock {
    func withLock<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
