import Foundation
import SwiftData
import Testing
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
    @MainActor
    func ensureSelectedWorktreeActivatesSpecialTabForInitialSelection() {
        let appModel = AppModel()
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
        let appModel = AppModel()
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

        let appModel = AppModel()
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

        let appModel = AppModel()
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

        let appModel = AppModel()
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
    func assignRepositoryKeepsNamespaceAndProjectConsistent() throws {
        let modelContext = try makeInMemoryModelContext()
        let appModel = AppModel()
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
        let appModel = AppModel()
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
        let appModel = AppModel()
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
        let appModel = AppModel()
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

        let appModel = AppModel()
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
        #expect(worktree.issueContext == "#123 Ticket backed worktree")

        let planURL = AppPaths.planFile(for: worktree.id)
        let plan = try String(contentsOf: planURL, encoding: .utf8)
        #expect(plan.contains("# Ticket backed worktree"))
        #expect(plan.contains("- Issue: #123"))
        #expect(plan.contains("## Beschreibung"))
        #expect(plan.contains("## Kommentare"))
        #expect(plan.contains("### alice - 2025-03-29T12:00:00Z"))

        try? FileManager.default.removeItem(at: planURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: worktree.path))
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
            configurations: configuration
        )
        return ModelContext(container)
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
