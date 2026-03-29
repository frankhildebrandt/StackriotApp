import SwiftData
import SwiftUI

struct CreateWorktreeSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let repository: ManagedRepository

    @State private var isCreating = false
    @State private var searchTask: Task<Void, Never>?

    private var requiresConfirmedTicket: Bool {
        appModel.worktreeDraft.ticketProviderStatus?.isAvailable == true
            && appModel.worktreeDraft.ticketProvider == .github
    }

    private var canCreate: Bool {
        guard !appModel.worktreeDraft.normalizedBranchName.isEmpty else { return false }
        guard !isCreating else { return false }
        return !requiresConfirmedTicket || appModel.worktreeDraft.hasConfirmedTicket
    }

    var body: some View {
        @Bindable var appModel = appModel
        let draft = appModel.worktreeDraft
        let status = draft.ticketProviderStatus

        VStack(alignment: .leading, spacing: 20) {
            Text("Create Worktree")
                .font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Worktree-Eingabe")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Feature Name", text: $appModel.worktreeDraft.branchName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Normalisierte Vorschau")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(draft.normalizedBranchName.nilIfBlank ?? "-")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(draft.normalizedBranchName.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source Branch")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Source Branch", text: $appModel.worktreeDraft.sourceBranch)
                            .textFieldStyle(.roundedBorder)
                    }

                    if !requiresConfirmedTicket {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Kontext (optional)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("Kurzer Kontext", text: $appModel.worktreeDraft.issueContext)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    Text("Bare repository: \(repository.bareRepositoryPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Ticket-Auswahl")
                        .font(.headline)

                    if let status {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(status.isAvailable ? .green : .orange)
                            Text(status.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((status.isAvailable ? Color.green : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    HStack(spacing: 8) {
                        TextField("Issue # oder Titel", text: $appModel.worktreeDraft.ticketSearchText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(status?.isAvailable != true)

                        Button("Suchen") {
                            triggerImmediateSearch()
                        }
                        .disabled(status?.isAvailable != true || draft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if draft.isTicketLoading {
                        ProgressView("GitHub-Issues werden geladen...")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if status?.isAvailable == true {
                        if draft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Suche nach einer Issue-Nummer oder einem Titel, um ein Ticket fuer diesen Worktree zu bestaetigen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if draft.ticketSearchResults.isEmpty {
                            Text("Keine Issues gefunden.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(draft.ticketSearchResults) { issue in
                                        Button {
                                            Task {
                                                await appModel.confirmWorktreeTicket(issue, for: repository)
                                            }
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("#\(issue.number) \(issue.title)")
                                                    .font(.subheadline.weight(.medium))
                                                    .foregroundStyle(.primary)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                Text(issue.state.capitalized)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 220)
                        }
                    }

                    if let selectedIssue = draft.selectedTicket {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: draft.hasConfirmedTicket ? "checkmark.seal.fill" : "number")
                                    .foregroundStyle(draft.hasConfirmedTicket ? .green : .secondary)
                                Text(draft.hasConfirmedTicket ? "Issue bestaetigt" : "Issue ausgewaehlt")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }

                            Text("#\(selectedIssue.number) \(selectedIssue.title)")
                                .font(.subheadline.weight(.medium))

                            if let details = draft.selectedIssueDetails {
                                Text(details.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if !details.labels.isEmpty {
                                    Text(details.labels.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    createWorktree()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(.regularMaterial)
        .task(id: repository.id) {
            await appModel.refreshTicketProviderStatus(for: repository)
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .onChange(of: appModel.worktreeDraft.ticketSearchText) { _, newValue in
            scheduleSearch(for: newValue)
        }
    }

    private func scheduleSearch(for query: String) {
        searchTask?.cancel()
        Task { @MainActor in
            appModel.clearWorktreeTicketSelection()
        }

        guard requiresConfirmedTicket else { return }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Task { @MainActor in
                appModel.worktreeDraft.ticketSearchResults = []
            }
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await appModel.searchWorktreeTickets(for: repository)
        }
    }

    private func triggerImmediateSearch() {
        searchTask?.cancel()
        Task {
            await appModel.searchWorktreeTickets(for: repository)
        }
    }

    private func createWorktree() {
        isCreating = true
        Task {
            if requiresConfirmedTicket {
                await appModel.createWorktreeFromTicket(for: repository, in: modelContext)
            } else {
                await appModel.createWorktree(for: repository, in: modelContext)
            }
            isCreating = false
            if appModel.pendingErrorMessage == nil {
                dismiss()
            }
        }
    }
}
