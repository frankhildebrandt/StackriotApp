import SwiftData
import SwiftUI

struct GitCommitSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let worktree: WorktreeRecord
    let repository: ManagedRepository

    @State private var message = ""
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Commit")
                .font(.title2.weight(.semibold))

            Text(worktree.branchName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("All current changes in this workspace will be staged and committed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Commit-Nachricht", text: $message, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button {
                        generateCommitMessage()
                    } label: {
                        HStack(spacing: 4) {
                            if isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text("KI-Nachricht generieren")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isGenerating)

                    if let error = generationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Abbrechen") {
                    dismiss()
                }
                Button("Commit") {
                    Task {
                        await appModel.runGitCommit(
                            message: message,
                            in: worktree,
                            repository: repository,
                            modelContext: modelContext
                        )
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }

    private func generateCommitMessage() {
        isGenerating = true
        generationError = nil
        guard let worktreePath = worktree.materializedPath else {
            generationError = "Der Worktree ist noch nicht materialisiert."
            isGenerating = false
            return
        }

        Task {
            do {
                let diff = try await fetchGitDiff(at: worktreePath)
                guard diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    await MainActor.run {
                        generationError = "Keine Änderungen gefunden."
                        isGenerating = false
                    }
                    return
                }
                let summary = try await appModel.services.aiProviderService.generateCommitMessage(diff: diff)
                let generated = GeneratedCommitMessage(summaryTitle: summary.title, summaryText: summary.summary)
                await MainActor.run {
                    message = generated?.fullMessage ?? summary.title
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    generationError = error.localizedDescription
                    isGenerating = false
                }
            }
        }
    }

    private func fetchGitDiff(at path: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // No committed history yet or all changes are untracked — try plain diff
            let fallbackProcess = Process()
            fallbackProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            fallbackProcess.arguments = ["diff", "--cached"]
            fallbackProcess.currentDirectoryURL = URL(fileURLWithPath: path)

            let fallbackPipe = Pipe()
            fallbackProcess.standardOutput = fallbackPipe
            fallbackProcess.standardError = Pipe()

            try fallbackProcess.run()
            fallbackProcess.waitUntilExit()

            let fallbackData = fallbackPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: fallbackData, encoding: .utf8) ?? ""
        }

        return output
    }
}
