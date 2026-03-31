import SwiftData
import SwiftUI

struct CreateWorktreeSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let repository: ManagedRepository

    @State private var isCreating = false
    @State private var pendingCreationConfirmation = false
    @State private var searchTask: Task<Void, Never>?

    private var canCreate: Bool {
        guard !appModel.worktreeDraft.normalizedBranchName.isEmpty else { return false }
        return !isCreating
    }

    private var sourceBranchName: String {
        let sourceBranch = appModel.worktreeDraft.sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceBranch.isEmpty ? repository.defaultBranch : sourceBranch
    }

    private var creationConfirmationMessage: String {
        let destinationDescription = projectedDestinationPath
            ?? "Standardpfad unter \(AppPaths.worktreesRoot.path)"
        var message = """
        Es wird ein neuer IdeaTree mit dem Branch \(appModel.worktreeDraft.normalizedBranchName) aus \(sourceBranchName) angelegt.
        Geplanter Zielpfad bei spaeterer Materialisierung: \(destinationDescription)
        Zunaechst wird nur der Datensatz mit Intent und Metadaten gespeichert; ein Git-Worktree wird noch nicht erstellt.
        """

        if appModel.worktreeDraft.hasConfirmedTicket, let selectedTicket = appModel.worktreeDraft.selectedTicket {
            message += "\n\nDas bestaetigte \(selectedTicket.reference.provider.ticketLabel) \(selectedTicket.reference.displayID) wird als Kontext uebernommen und der initiale Plan vorbereitet."
        } else if let issueContext = appModel.worktreeDraft.issueContext.nilIfBlank {
            message += "\n\nDer Kontext \"\(issueContext)\" wird dem Worktree zugeordnet."
        }

        return message
    }

    private var destinationRootDescription: String {
        appModel.worktreeDraft.destinationRootPath?.nilIfBlank ?? "Standardpfad"
    }

    private var projectedDestinationPath: String? {
        let normalizedBranchName = appModel.worktreeDraft.normalizedBranchName
        guard !normalizedBranchName.isEmpty else { return nil }
        guard let destinationRoot = appModel.worktreeDraft.destinationRootURL else { return nil }
        return destinationRoot.appendingPathComponent(normalizedBranchName, isDirectory: true).path
    }

    var body: some View {
        @Bindable var appModel = appModel
        let draft = appModel.worktreeDraft
        let status = draft.selectedTicketProviderStatus
        let selectedProvider = draft.ticketProvider ?? draft.availableTicketProviders.first

        VStack(alignment: .leading, spacing: 20) {
            Text("Create IdeaTree")
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
                            .disabled(isCreating)
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
                            .disabled(isCreating)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kontext (optional)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Kurzer Kontext", text: $appModel.worktreeDraft.issueContext)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isCreating || draft.hasConfirmedTicket)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Zielordner")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        Text(destinationRootDescription)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(draft.destinationRootPath == nil ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        HStack(spacing: 8) {
                            Button("Open Folder") {
                                chooseDestinationRoot()
                            }
                            .disabled(isCreating)

                            Button("Standardpfad") {
                                appModel.worktreeDraft.destinationRootPath = nil
                            }
                            .disabled(isCreating || draft.destinationRootPath == nil)
                        }

                        if let projectedDestinationPath {
                            Text("Effektiver Pfad: \(projectedDestinationPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Text("Bare repository: \(repository.bareRepositoryPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            appModel.worktreeDraft.isTicketSectionExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: draft.isTicketSectionExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text("Ticket (optional)")
                                .font(.headline)
                            Spacer()
                            if draft.hasConfirmedTicket, let selectedTicket = draft.selectedTicket {
                                Text(selectedTicket.reference.displayID)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if draft.isTicketSectionExpanded {
                        VStack(alignment: .leading, spacing: 12) {
                            if draft.availableTicketProviders.count > 1 {
                                Picker("Provider", selection: Binding(
                                    get: { draft.ticketProvider ?? draft.availableTicketProviders.first ?? .github },
                                    set: { appModel.setWorktreeTicketProvider($0) }
                                )) {
                                    ForEach(draft.availableTicketProviders) { provider in
                                        Text(provider.displayName).tag(provider)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .disabled(isCreating)
                            } else if let selectedProvider {
                                LabeledContent("Provider", value: selectedProvider.displayName)
                            }

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
                                TextField(selectedProvider?.searchPrompt ?? "Ticket-Key oder Titel", text: $appModel.worktreeDraft.ticketSearchText)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(isCreating || status?.isAvailable != true)
                                    .onSubmit {
                                        guard !isCreating, status?.isAvailable == true else { return }
                                        guard !draft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                        triggerImmediateSearch()
                                    }

                                Button("Suchen") {
                                    triggerImmediateSearch()
                                }
                                .disabled(isCreating || status?.isAvailable != true || draft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            if draft.isTicketLoading {
                                ProgressView("Tickets werden geladen...")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if status?.isAvailable == true {
                                if draft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(selectedProvider?.searchHint ?? "Suche nach einem Ticket, um optional Kontext fuer diesen Worktree zu uebernehmen.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if draft.ticketSearchResults.isEmpty {
                                    Text("Keine Tickets gefunden.")
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
                                                        Text("\(issue.reference.displayID) \(issue.title)")
                                                            .font(.subheadline.weight(.medium))
                                                            .foregroundStyle(.primary)
                                                            .frame(maxWidth: .infinity, alignment: .leading)
                                                        Text(issue.status.capitalized)
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    .padding(10)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(isCreating)
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 220)
                                }
                            }

                            if let selectedTicket = draft.selectedTicket {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Image(systemName: draft.hasConfirmedTicket ? "checkmark.seal.fill" : "number")
                                            .foregroundStyle(draft.hasConfirmedTicket ? .green : .secondary)
                                        Text(draft.hasConfirmedTicket ? "\(selectedTicket.reference.provider.ticketLabel) bestaetigt" : "\(selectedTicket.reference.provider.ticketLabel) ausgewaehlt")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }

                                    Text("\(selectedTicket.reference.displayID) \(selectedTicket.title)")
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

                                    if draft.isGeneratingSuggestedName {
                                        ProgressView("Worktree-Name wird vorgeschlagen…")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else if let details = draft.selectedIssueDetails {
                                        Button("Worktree-Namen neu vorschlagen") {
                                            Task {
                                                await appModel.populateSuggestedWorktreeName(from: details)
                                            }
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(isCreating)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if isCreating {
                ProgressView("IdeaTree wird erstellt…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)

                Button("Create IdeaTree") {
                    pendingCreationConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
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
        .onChange(of: appModel.worktreeDraft.ticketProvider) { _, _ in
            guard appModel.worktreeDraft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return
            }
            triggerImmediateSearch()
        }
        .confirmationDialog("IdeaTree erstellen?", isPresented: $pendingCreationConfirmation) {
            Button("Erstellen") {
                createWorktree()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(creationConfirmationMessage)
        }
    }

    private func scheduleSearch(for query: String) {
        searchTask?.cancel()
        Task { @MainActor in
            appModel.clearWorktreeTicketSelection()
        }

        guard appModel.worktreeDraft.selectedTicketProviderStatus?.isAvailable == true else { return }
        guard appModel.worktreeDraft.isTicketSectionExpanded else { return }
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
            await appModel.createWorktree(for: repository, in: modelContext)
            isCreating = false
            if appModel.pendingErrorMessage == nil {
                dismiss()
            }
        }
    }

    private func chooseDestinationRoot() {
        let initialDirectory = appModel.worktreeDraft.destinationRootURL
            ?? AppPaths.worktreesRoot.appendingPathComponent(AppPaths.sanitizedPathComponent(repository.displayName), isDirectory: true)
        guard let selectedDirectory = IDEManager.chooseDirectory(
            title: "Zielordner waehlen",
            message: "Stackriot erstellt darunter einen Unterordner fuer den neuen Worktree.",
            prompt: "Auswaehlen",
            initialDirectory: initialDirectory
        ) else {
            return
        }
        appModel.worktreeDraft.destinationRootPath = selectedDirectory.path
    }
}
