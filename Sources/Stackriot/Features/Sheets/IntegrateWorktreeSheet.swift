import SwiftData
import SwiftUI

struct IntegrateWorktreeSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let worktreeID: UUID
    let repository: ManagedRepository
    let initialBranchName: String

    @State private var draft: IntegrationDraft
    @State private var isGHAvailable = false
    @State private var isRunning = false

    private var worktree: WorktreeRecord? {
        appModel.worktreeRecord(with: worktreeID)
    }

    private var branchName: String {
        worktree?.branchName ?? initialBranchName
    }

    private var hasGitHubRemote: Bool {
        repository.remotes.contains { GitHubCLIService.isGitHubRemote(url: $0.url) }
    }

    private var canUseGitHubPR: Bool {
        isGHAvailable && hasGitHubRemote
    }

    init(worktreeID: UUID, repository: ManagedRepository, initialBranchName: String) {
        self.worktreeID = worktreeID
        self.repository = repository
        self.initialBranchName = initialBranchName
        _draft = State(initialValue: IntegrationDraft(
            method: .localMerge,
            deleteAfterIntegration: true,
            prTitle: initialBranchName,
            prBody: ""
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Integrieren in \(repository.defaultBranch)")
                    .font(.title2.weight(.semibold))
                Text(branchName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text("Ein Worktree repräsentiert ein Feature — nach dem Merge ist seine Aufgabe erfüllt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("Integrations-Methode")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Picker("Methode", selection: $draft.method) {
                    ForEach(IntegrationDraft.Method.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.segmented)
            }

            if draft.method == .githubPR {
                if !canUseGitHubPR {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        if !isGHAvailable {
                            Text("`gh` CLI nicht gefunden. Installiere die GitHub CLI für PR-Support.")
                        } else {
                            Text("Kein GitHub-Remote konfiguriert. Füge einen Remote mit einer github.com-URL hinzu.")
                        }
                    }
                    .font(.caption)
                    .padding(10)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PR Titel")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("Titel des Pull Requests", text: $draft.prTitle)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Beschreibung (optional)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $draft.prBody)
                                .frame(minHeight: 90)
                                .font(.body)
                                .padding(4)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        }
                    }
                }
            }

            Divider()

            Toggle("Worktree nach Integration löschen", isOn: $draft.deleteAfterIntegration)

            Divider()

            HStack {
                Spacer()
                Button("Abbrechen") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(draft.method == .githubPR ? "PR erstellen" : "Jetzt integrieren") {
                    guard let worktree else {
                        dismiss()
                        return
                    }
                    isRunning = true
                    Task {
                        await appModel.startIntegration(
                            worktree,
                            repository: repository,
                            draft: draft,
                            modelContext: modelContext
                        )
                        isRunning = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || (draft.method == .githubPR && !canUseGitHubPR) || (draft.method == .githubPR && draft.prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(.regularMaterial)
        .onChange(of: worktree == nil) { _, isMissing in
            if isMissing {
                dismiss()
            }
        }
        .task {
            isGHAvailable = await appModel.services.gitHubCLIService.isGHAvailable()
            if !isGHAvailable || !hasGitHubRemote {
                draft.method = .localMerge
            }
        }
    }
}
