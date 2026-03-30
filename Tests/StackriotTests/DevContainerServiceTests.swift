import Foundation
@testable import Stackriot
import Testing

@MainActor
struct DevContainerServiceTests {
    @Test
    func detectsFolderConfigBeforeRootConfig() throws {
        let workspace = try makeTemporaryWorkspace()
        let folderConfig = workspace.appendingPathComponent(".devcontainer/devcontainer.json")
        let rootConfig = workspace.appendingPathComponent(".devcontainer.json")

        try FileManager.default.createDirectory(at: folderConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: folderConfig, atomically: true, encoding: .utf8)
        try "{}".write(to: rootConfig, atomically: true, encoding: .utf8)

        let service = DevContainerService()
        let configuration = try #require(service.configuration(at: workspace))

        #expect(configuration.configFileURL == folderConfig)
        #expect(configuration.displayPath == ".devcontainer/devcontainer.json")
    }

    @Test
    func detectsRootConfigWhenFolderConfigIsMissing() throws {
        let workspace = try makeTemporaryWorkspace()
        let rootConfig = workspace.appendingPathComponent(".devcontainer.json")
        try "{}".write(to: rootConfig, atomically: true, encoding: .utf8)

        let service = DevContainerService()
        let configuration = try #require(service.configuration(at: workspace))

        #expect(configuration.configFileURL == rootConfig)
        #expect(configuration.displayPath == ".devcontainer.json")
    }

    @Test
    func returnsNilWhenNoDevcontainerConfigExists() throws {
        let workspace = try makeTemporaryWorkspace()

        let service = DevContainerService()

        #expect(service.configuration(at: workspace) == nil)
    }

    @Test
    func parsesDockerStatsIntoSnapshot() async throws {
        let workspace = try makeTemporaryWorkspace()
        let config = workspace.appendingPathComponent(".devcontainer.json")
        try "{}".write(to: config, atomically: true, encoding: .utf8)

        let service = DevContainerService(commandExecutor: { executable, arguments, _ in
            if executable == "docker",
               arguments.count == 8,
               arguments[0] == "ps",
               arguments[1] == "-a",
               arguments[2] == "--filter",
               arguments[4] == "--filter",
               arguments[6] == "--format",
               arguments[7] == "{{.ID}}",
               arguments[3].contains("devcontainer.local_folder="),
               arguments[5].contains("devcontainer.config_file=") {
                return CommandResult(stdout: "abc123\n", stderr: "", exitCode: 0)
            }

            if executable == "docker",
               arguments.count == 7,
               arguments[0] == "ps",
               arguments[1] == "--filter",
               arguments[3] == "--filter",
               arguments[5] == "--format",
               arguments[6] == "{{.ID}}",
               arguments[2].contains("devcontainer.local_folder="),
               arguments[4].contains("devcontainer.config_file=") {
                return CommandResult(stdout: "abc123\n", stderr: "", exitCode: 0)
            }

            switch (executable, arguments) {
            case ("docker", ["inspect", "abc123"]):
                return CommandResult(
                    stdout: #"[{"Id":"abc123","Name":"/demo-devcontainer","Config":{"Image":"ghcr.io/demo/image:latest"}}]"#,
                    stderr: "",
                    exitCode: 0
                )
            case ("docker", ["stats", "--no-stream", "--format", "{{json .}}", "abc123"]):
                return CommandResult(
                    stdout: #"{"CPUPerc":"1.23%","MemUsage":"512MiB / 8GiB","MemPerc":"6.25%"}"# + "\n",
                    stderr: "",
                    exitCode: 0
                )
            default:
                return CommandResult(stdout: "", stderr: "unexpected command: \(executable) \(arguments.joined(separator: " "))", exitCode: 1)
            }
        })

        let snapshot = await service.status(for: workspace)

        #expect(snapshot.runtimeStatus == DevContainerRuntimeStatus.running)
        #expect(snapshot.containerName == "demo-devcontainer")
        #expect(snapshot.imageName == "ghcr.io/demo/image:latest")
        #expect(snapshot.resourceUsage?.cpuPercent == "1.23%")
        #expect(snapshot.resourceUsage?.memoryUsage == "512MiB / 8GiB")
        #expect(snapshot.resourceUsage?.memoryPercent == "6.25%")
    }

    @Test
    func surfacesDockerConnectivityErrorsInSnapshot() async throws {
        let workspace = try makeTemporaryWorkspace()
        let config = workspace.appendingPathComponent(".devcontainer.json")
        try "{}".write(to: config, atomically: true, encoding: .utf8)

        let service = DevContainerService(commandExecutor: { _, _, _ in
            CommandResult(stdout: "", stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?", exitCode: 1)
        })

        let snapshot = await service.status(for: workspace)

        #expect(snapshot.runtimeStatus == DevContainerRuntimeStatus.unknown)
        #expect(snapshot.detailsErrorMessage == "Docker is not reachable. Start Docker Desktop or another Docker engine and try again.")
    }

    private func makeTemporaryWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }
}
