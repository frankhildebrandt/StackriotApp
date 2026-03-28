import Foundation
import Testing
@testable import DevVault

struct DevVaultTests {
    @Test
    func sanitizedPathComponentNormalizesNames() {
        #expect(AppPaths.sanitizedPathComponent("Feature/ABC 123") == "feature-abc-123")
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
    func repositoryCloneAndWorktreeCreationWorkLocally() async throws {
        let origin = try temporaryDirectory(named: "origin")
        let remote = origin.appendingPathComponent("sample.git")
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

        let cloneInfo = try await RepositoryManager().cloneBareRepository(remoteURL: remote, preferredName: "Sample")
        #expect(FileManager.default.fileExists(atPath: cloneInfo.bareRepositoryPath.path))
        #expect(cloneInfo.defaultBranch == "main")

        let worktreeInfo = try await WorktreeManager().createWorktree(
            bareRepositoryPath: cloneInfo.bareRepositoryPath,
            repositoryName: cloneInfo.displayName,
            branchName: "feature/tests",
            sourceBranch: cloneInfo.defaultBranch
        )

        #expect(FileManager.default.fileExists(atPath: worktreeInfo.path.path))
        #expect(FileManager.default.fileExists(atPath: worktreeInfo.path.appendingPathComponent("README.md").path))
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevVaultTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString + "-" + name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func runGit(_ arguments: [String], currentDirectoryURL: URL) async throws {
        let result = try await CommandRunner.runCollected(
            executable: "git",
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL
        )
        #expect(result.exitCode == 0, "git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
    }
}
