import SwiftUI

struct AgentRunSummaryWindow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let run: RunRecord
    let isSummarizing: Bool
    let onClose: () -> Void

    @State private var diffSnapshot = WorkspaceDiffSnapshot(files: [])
    @State private var isLoadingDiff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.aiSummaryTitle ?? "Agent-Zusammenfassung")
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                if let commitMessage, let worktree = resolvedWorktree, let repository = resolvedRepository {
                    Button {
                        Task {
                            await appModel.runGitCommit(
                                message: commitMessage.fullMessage,
                                in: worktree,
                                repository: repository,
                                modelContext: modelContext
                            )
                        }
                    } label: {
                        Label("Commit Work", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(diffSnapshot.files.isEmpty)
                    .help(diffSnapshot.files.isEmpty ? "Keine lokalen Änderungen zum Committen vorhanden." : "Erstellt einen Commit aus der AI-Zusammenfassung.")
                }
                Button {
                    onClose()
                } label: {
                    Label("Schliessen", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summarySection
                    if let commitMessage {
                        commitPreviewSection(commitMessage)
                    }
                    changelogSection
                }
            }
        }
        .task(id: resolvedWorktree?.id) {
            await reloadDiff()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var summarySection: some View {
        section(title: "Zusammenfassung") {
            if isSummarizing {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView()
                    Text("Die AI fasst den Agent-Output gerade zusammen…")
                        .foregroundStyle(.secondary)
                }
            } else if let summary = run.aiSummaryText?.nonEmpty {
                ScrollView {
                    Text(summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 220)
            } else {
                Text("Noch keine Zusammenfassung verfuegbar.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func commitPreviewSection(_ commitMessage: GeneratedCommitMessage) -> some View {
        section(title: "Generierter Commit") {
            Text("Die Nachricht wird direkt aus der AI-Zusammenfassung erzeugt und folgt einer prägnanten Subject-Zeile mit Arbeitsumfang als Liste.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(commitMessage.fullMessage)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(minHeight: 100, maxHeight: 180)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private var changelogSection: some View {
        section(title: "Changelog") {
            if isLoadingDiff {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                WorkspaceDiffFileList(
                    files: diffSnapshot.files,
                    emptyTitle: "Kein Changelog verfuegbar",
                    emptyDescription: "Im zugehörigen Worktree gibt es aktuell keine lokalen Änderungen.",
                    usesVerticalScrollView: false
                )
                .background(.clear)
            }
        }
    }

    private var resolvedWorktree: WorktreeRecord? {
        if let worktree = run.worktree {
            return worktree
        }
        guard let worktreeID = run.worktreeID else { return nil }
        return appModel.worktreeRecord(with: worktreeID)
    }

    private var resolvedRepository: ManagedRepository? {
        run.repository ?? resolvedWorktree?.repository
    }

    private var commitMessage: GeneratedCommitMessage? {
        GeneratedCommitMessage(summaryTitle: run.aiSummaryTitle, summaryText: run.aiSummaryText)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    @MainActor
    private func reloadDiff() async {
        guard let resolvedWorktree else {
            diffSnapshot = WorkspaceDiffSnapshot(files: [])
            return
        }

        isLoadingDiff = true
        diffSnapshot = await appModel.loadDiff(for: resolvedWorktree)
        isLoadingDiff = false
    }
}
