import Foundation
import SwiftData
import Testing
@testable import DevVault

struct DevVaultTests {
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
            ]
        )
        #expect(refresh.status == .ready)
        #expect(refresh.fetchedAt != nil)

        let disabledRefresh = await RepositoryManager().refreshRepository(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            remotes: [
                RemoteExecutionContext(name: "origin", url: remoteOne.remote.path, fetchEnabled: true, privateKeyRef: nil),
                RemoteExecutionContext(name: "broken", url: "/definitely/missing.git", fetchEnabled: false, privateKeyRef: nil),
            ]
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
        try await runGit(["-C", worktreeInfo.path.path, "config", "user.name", "DevVault Tests"], currentDirectoryURL: worktreeInfo.path)
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

    private func createSeededRemote(named name: String) async throws -> (root: URL, remote: URL) {
        let origin = try temporaryDirectory(named: name)
        let remote = origin.appendingPathComponent("\(name).git")
        let checkout = origin.appendingPathComponent("checkout")

        try await runGit(["init", "--bare", remote.path], currentDirectoryURL: origin)
        try await runGit(["clone", remote.path, checkout.path], currentDirectoryURL: origin)
        try "hello".write(to: checkout.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await runGit(["-C", checkout.path, "add", "."], currentDirectoryURL: origin)
        try await runGit(["-C", checkout.path, "config", "user.email", "tests@example.com"], currentDirectoryURL: origin)
        try await runGit(["-C", checkout.path, "config", "user.name", "DevVault Tests"], currentDirectoryURL: origin)
        try await runGit(["-C", checkout.path, "config", "commit.gpgsign", "false"], currentDirectoryURL: origin)
        try await runGit(["-C", checkout.path, "commit", "-m", "Initial"], currentDirectoryURL: origin)
        try await runGit(["-C", checkout.path, "push", "origin", "HEAD:main"], currentDirectoryURL: origin)
        try await runGit(["-C", remote.path, "symbolic-ref", "HEAD", "refs/heads/main"], currentDirectoryURL: origin)

        return (origin, remote)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevVaultTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + "-" + name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func configureGitIdentity(in directory: URL) async throws {
        try await runGit(["-C", directory.path, "config", "user.email", "tests@example.com"], currentDirectoryURL: directory)
        try await runGit(["-C", directory.path, "config", "user.name", "DevVault Tests"], currentDirectoryURL: directory)
        try await runGit(["-C", directory.path, "config", "commit.gpgsign", "false"], currentDirectoryURL: directory)
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
