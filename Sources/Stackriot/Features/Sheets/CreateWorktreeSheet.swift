import SwiftData
import SwiftUI

struct CreateWorktreeSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let repository: ManagedRepository

    @State private var isCreating = false
    @State private var isTicketDrawerPresented = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isNameFieldFocused: Bool

    private var canCreate: Bool {
        guard !appModel.worktreeDraft.normalizedBranchName.isEmpty else { return false }
        return !isCreating
    }

    private var sourceBranchName: String {
        let sourceBranch = appModel.worktreeDraft.sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceBranch.isEmpty ? repository.defaultBranch : sourceBranch
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

    private var projectedPathLabel: String {
        switch appModel.worktreeDraft.creationMode {
        case .ideaTree:
            "Geplanter Materialisierungspfad"
        case .fullWorktree:
            "Effektiver Pfad"
        }
    }

    private var destinationHelpText: String {
        switch appModel.worktreeDraft.creationMode {
        case .ideaTree:
            "Stackriot merkt sich diesen Ort fuer die spaetere Materialisierung des IdeaTrees."
        case .fullWorktree:
            "Stackriot legt den Git-Worktree sofort unter diesem Zielordner an."
        }
    }

    private var creationSummaryText: String {
        switch appModel.worktreeDraft.creationMode {
        case .ideaTree:
            "Der Eintrag wird zuerst nur als IdeaTree mit Intent, Ticket-Kontext und Zielpfad gespeichert."
        case .fullWorktree:
            "Der Eintrag wird sofort als echter Git-Worktree angelegt und als regulaerer Worktree gespeichert."
        }
    }

    var body: some View {
        let draft = appModel.worktreeDraft
        let status = draft.selectedTicketProviderStatus
        let selectedProvider = draft.ticketProvider ?? draft.availableTicketProviders.first

        HStack(alignment: .top, spacing: 0) {
            mainContent(draft: draft, status: status, selectedProvider: selectedProvider)

            if isTicketDrawerPresented {
                Divider()
                WorktreeTicketDrawer(
                    repository: repository,
                    isCreating: isCreating,
                    triggerImmediateSearch: triggerImmediateSearch,
                    closeDrawer: closeTicketDrawer
                )
                .frame(width: 340)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: isTicketDrawerPresented ? 981 : 640)
        .background(.regularMaterial)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isTicketDrawerPresented)
        .task(id: repository.id) {
            await appModel.refreshTicketProviderStatus(for: repository)
            isNameFieldFocused = true
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .onChange(of: appModel.worktreeDraft.ticketSearchText) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onChange(of: appModel.worktreeDraft.ticketProvider) { _, _ in
            guard isTicketDrawerPresented else { return }
            guard appModel.worktreeDraft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return
            }
            triggerImmediateSearch()
        }
        .onChange(of: isTicketDrawerPresented) { _, isPresented in
            if !isPresented {
                searchTask?.cancel()
                return
            }
            guard appModel.worktreeDraft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return
            }
            triggerImmediateSearch()
        }
    }

    private func mainContent(
        draft: WorktreeDraft,
        status: TicketProviderStatus?,
        selectedProvider: TicketProviderKind?
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection(draft: draft)
            worktreeInputSection(draft: draft)
            if isCreating {
                ProgressView(draft.creationMode.progressTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            actionButtons(draft: draft)
        }
        .padding(24)
        .frame(minWidth: 640, alignment: .topLeading)
    }

    private func headerSection(draft: WorktreeDraft) -> some View {
        @Bindable var appModel = appModel
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(draft.creationMode.sheetTitle)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Picker("", selection: $appModel.worktreeDraft.creationMode) {
                ForEach(WorktreeCreationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .disabled(isCreating)
            Button(action: toggleTicketDrawer) {
                Label(isTicketDrawerPresented ? "Close" : "Open", systemImage: "sidebar.right")
            }
            .disabled(isCreating)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func worktreeInputSection(draft: WorktreeDraft) -> some View {
        @Bindable var appModel = appModel

        return VStack(alignment: .leading, spacing: 12) {
            Text("Worktree-Eingabe")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Feature Name", text: $appModel.worktreeDraft.branchName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
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
                Text("Neuer Branch wird aus \(sourceBranchName) erzeugt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Text(destinationHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let projectedDestinationPath {
                    Text("\(projectedPathLabel): \(projectedDestinationPath)")
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
    }

    private func ticketSummarySection(
        draft: WorktreeDraft,
        status: TicketProviderStatus?,
        selectedProvider: TicketProviderKind?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Ticket (optional)", systemImage: "tag")
                        .font(.headline)

                    if let selectedProvider {
                        Text("Aktiver Provider: \(selectedProvider.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(action: toggleTicketDrawer) {
                    Label(isTicketDrawerPresented ? "Drawer schliessen" : "Drawer oeffnen", systemImage: "sidebar.right")
                }
                .disabled(isCreating)
            }

            if let selectedTicket = draft.selectedTicket {
                ticketSelectionBanner(
                    title: "\(selectedTicket.reference.displayID) \(selectedTicket.title)",
                    subtitle: draft.hasConfirmedTicket
                        ? "\(selectedTicket.reference.provider.ticketLabel) bestaetigt"
                        : "\(selectedTicket.reference.provider.ticketLabel) ausgewaehlt",
                    url: draft.selectedIssueDetails?.url,
                    isConfirmed: draft.hasConfirmedTicket
                )
            } else if let status {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.isAvailable ? .green : .orange)
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((status.isAvailable ? Color.green : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text("Suche optional ein GitHub- oder Jira-Ticket im Drawer, um Kontext und einen Branch-Vorschlag zu uebernehmen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func ticketSelectionBanner(
        title: String,
        subtitle: String,
        url: String?,
        isConfirmed: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isConfirmed ? "checkmark.seal.fill" : "number")
                    .foregroundStyle(isConfirmed ? .green : .secondary)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.subheadline.weight(.medium))

            if let url {
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func actionButtons(draft: WorktreeDraft) -> some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isCreating)

            Button(draft.creationMode.primaryActionTitle) {
                createWorktree()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
            .commandEnterAction(disabled: !canCreate) { createWorktree() }
        }
    }

    private func toggleTicketDrawer() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            isTicketDrawerPresented.toggle()
        }
    }

    private func closeTicketDrawer() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            isTicketDrawerPresented = false
        }
    }

    private func scheduleSearch(for query: String) {
        searchTask?.cancel()
        Task { @MainActor in
            appModel.clearWorktreeTicketSelection()
        }

        guard isTicketDrawerPresented else { return }
        guard appModel.worktreeDraft.selectedTicketProviderStatus?.isAvailable == true else { return }
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
        guard isTicketDrawerPresented else { return }
        searchTask?.cancel()
        Task {
            await appModel.searchWorktreeTickets(for: repository)
        }
    }

    private func createWorktree() {
        guard canCreate else { return }
        appModel.pendingErrorMessage = nil
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

private struct WorktreeTicketDrawer: View {
    @Environment(AppModel.self) private var appModel

    let repository: ManagedRepository
    let isCreating: Bool
    let triggerImmediateSearch: () -> Void
    let closeDrawer: () -> Void

    var body: some View {
        @Bindable var appModel = appModel
        let draft = appModel.worktreeDraft
        let status = draft.selectedTicketProviderStatus
        let selectedProvider = draft.ticketProvider ?? draft.availableTicketProviders.first
        let helperText = selectedProvider?.searchHint ?? "Suche nach einem Ticket, um optional Kontext fuer diesen Worktree zu uebernehmen."

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ticket-Suche")
                        .font(.headline)
                    Text("GitHub- oder Jira-Kontext fuer den neuen \(draft.creationMode.displayName) uebernehmen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: closeDrawer) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
            }

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

                Button("Suchen") {
                    triggerImmediateSearch()
                }
                .disabled(isCreating || status?.isAvailable != true || draft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ticketResultsSection(draft: draft, status: status, helperText: helperText)

            if let selectedTicket = draft.selectedTicket {
                selectedTicketDetailsCard(draft: draft, selectedTicket: selectedTicket)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func ticketResultsSection(
        draft: WorktreeDraft,
        status: TicketProviderStatus?,
        helperText: String
    ) -> some View {
        if draft.isTicketLoading {
            ProgressView("Tickets werden geladen...")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if status?.isAvailable == true {
            let trimmedSearch = draft.ticketSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedSearch.isEmpty {
                Text(helperText)
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
    }

    private func selectedTicketDetailsCard(
        draft: WorktreeDraft,
        selectedTicket: TicketSearchResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: draft.hasConfirmedTicket ? "checkmark.seal.fill" : "number")
                    .foregroundStyle(draft.hasConfirmedTicket ? .green : .secondary)
                Text(
                    draft.hasConfirmedTicket
                        ? "\(selectedTicket.reference.provider.ticketLabel) bestaetigt"
                        : "\(selectedTicket.reference.provider.ticketLabel) ausgewaehlt"
                )
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
