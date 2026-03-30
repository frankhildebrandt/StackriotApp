import Foundation

struct CopilotModelDiscoveryService {
    typealias CommandExecutor = @Sendable (_ executable: String, _ arguments: [String], _ currentDirectoryURL: URL?, _ environment: [String: String]) async throws -> CommandResult
    typealias EnvironmentProvider = @Sendable () async -> [String: String]

    private static let invalidModelProbe = "__stackriot_model_probe__"

    private let runCommand: CommandExecutor
    private let environmentProvider: EnvironmentProvider

    init(
        runCommand: @escaping CommandExecutor = CopilotModelDiscoveryService.liveCommand,
        environmentProvider: @escaping EnvironmentProvider = CopilotModelDiscoveryService.liveEnvironment
    ) {
        self.runCommand = runCommand
        self.environmentProvider = environmentProvider
    }

    func discoverModels() async throws -> [CopilotModelOption] {
        let environment = await environmentProvider()
        let result = try await runCommand(
            "copilot",
            [
                "-p", "Stackriot Copilot model discovery probe",
                "--model", Self.invalidModelProbe,
                "--allow-all",
                "--no-ask-user",
                "--output-format", "json",
                "--no-color",
            ],
            nil,
            environment
        )

        let combinedOutput = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if let parsedModels = Self.parseModelChoices(from: combinedOutput), !parsedModels.isEmpty {
            return [.auto] + parsedModels.map { CopilotModelOption(id: $0, displayName: $0, isAuto: false) }
        }

        if combinedOutput.localizedCaseInsensitiveContains("Model \"\(Self.invalidModelProbe)\" from --model flag is not available.") {
            return [.auto]
        }

        let errorMessage = combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if errorMessage.isEmpty {
            throw StackriotError.commandFailed("GitHub Copilot model discovery failed without output.")
        }

        throw StackriotError.commandFailed(errorMessage)
    }

    static func parseModelChoices(from output: String) -> [String]? {
        guard
            let choicesRange = output.range(
                of: #"choices:\s*((?:"[^"]+"\s*,\s*)*"[^"]+")"#,
                options: .regularExpression
            )
        else {
            return nil
        }

        let choicesText = String(output[choicesRange])
        let modelMatches = choicesText.matches(of: /"([^"]+)"/)
        let models = modelMatches.map { String($0.1) }

        guard !models.isEmpty else { return nil }

        var seen = Set<String>()
        return models.filter { seen.insert($0).inserted }
    }

    private static func liveCommand(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]
    ) async throws -> CommandResult {
        try await CommandRunner.runCollected(
            executable: executable,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment
        )
    }

    private static func liveEnvironment() async -> [String: String] {
        await ShellEnvironment.resolvedEnvironment()
    }
}
