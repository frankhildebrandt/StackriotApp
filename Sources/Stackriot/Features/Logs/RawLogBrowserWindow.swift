import SwiftData
import SwiftUI

struct RawLogBrowserWindow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AgentRawLogRecord.startedAt, order: .reverse) private var rawLogs: [AgentRawLogRecord]

    @State private var searchText = ""
    @State private var selectedAgent: AIAgentTool?
    @State private var selectedProject = "Alle Projekte"
    @State private var selectedRepository = "Alle Repositories"
    @State private var selectedLogID: UUID?
    @State private var logText = ""
    @State private var logLoadError: String?
    @State private var pendingDeletion: AgentRawLogRecord?

    private let allProjectsLabel = "Alle Projekte"
    private let allRepositoriesLabel = "Alle Repositories"

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if filteredLogs.isEmpty {
                    ContentUnavailableView(
                        "Keine RAW-Logs",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Neue AI-Agent-Runs erscheinen hier automatisch als dateibasierte Artefakte.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(filteredLogs, selection: $selectedLogID) {
                        TableColumn("Agent") { record in
                            Label(record.agentTool.displayName, systemImage: record.agentTool.systemImageName)
                        }
                        .width(min: 130, ideal: 150)

                        TableColumn("Projekt") { record in
                            Text(record.displayProjectName)
                                .foregroundStyle(record.projectName == nil ? .secondary : .primary)
                        }
                        .width(min: 140, ideal: 170)

                        TableColumn("Repository") { record in
                            Text(record.displayRepositoryName)
                        }
                        .width(min: 160, ideal: 190)

                        TableColumn("Worktree") { record in
                            Text(record.displayWorktreeName)
                                .foregroundStyle(record.worktreeBranchName == nil ? .secondary : .primary)
                        }
                        .width(min: 130, ideal: 160)

                        TableColumn("Status") { record in
                            Text(record.status.rawValue.capitalized)
                                .foregroundStyle(statusColor(for: record.status))
                        }
                        .width(min: 90, ideal: 100)

                        TableColumn("Start") { record in
                            Text(record.startedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                                .font(.caption.monospacedDigit())
                        }
                        .width(min: 150, ideal: 165)

                        TableColumn("Dauer") { record in
                            Text(durationText(for: record))
                                .font(.caption.monospacedDigit())
                        }
                        .width(min: 80, ideal: 90)
                    }
                }
            }
            .navigationTitle("RAW Logs")
        } detail: {
            if let selectedRecord {
                detailView(for: selectedRecord)
            } else {
                ContentUnavailableView(
                    "Kein Log ausgewaehlt",
                    systemImage: "doc.text",
                    description: Text("Waehle links einen archivierten Agentenlauf aus.")
                )
            }
        }
        .task(id: filteredLogs.map(\.id)) {
            ensureSelection()
        }
        .task(id: selectedRecord?.id) {
            await reloadSelectedLog()
        }
        .confirmationDialog("RAW-Log loeschen?", item: $pendingDeletion) { record in
            Button("Loeschen", role: .destructive) {
                let deletedID = record.id
                appModel.deleteRawLog(record, in: modelContext)
                if selectedLogID == deletedID {
                    selectedLogID = filteredLogs.first(where: { $0.id != deletedID })?.id
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { record in
            Text("Die archivierte Datei und ihre Metadaten fuer \(record.title) werden entfernt. Der urspruengliche RunRecord bleibt erhalten.")
        }
        .alert("Stackriot", isPresented: Binding(
            get: { appModel.pendingErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    appModel.pendingErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                appModel.pendingErrorMessage = nil
            }
        } message: {
            Text(appModel.pendingErrorMessage ?? "")
        }
    }

    private var filteredLogs: [AgentRawLogRecord] {
        rawLogs.filter { record in
            let matchesAgent = selectedAgent.map { record.agentTool == $0 } ?? true
            let matchesProject = selectedProject == allProjectsLabel || record.displayProjectName == selectedProject
            let matchesRepository = selectedRepository == allRepositoriesLabel || record.displayRepositoryName == selectedRepository
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch: Bool
            if query.isEmpty {
                matchesSearch = true
            } else {
                let haystack = [
                    record.title,
                    record.promptText ?? "",
                    record.displayProjectName,
                    record.displayRepositoryName,
                    record.displayWorktreeName,
                    record.agentTool.displayName,
                ].joined(separator: "\n")
                matchesSearch = haystack.localizedCaseInsensitiveContains(query)
            }
            return matchesAgent && matchesProject && matchesRepository && matchesSearch
        }
    }

    private var selectedRecord: AgentRawLogRecord? {
        if let selectedLogID, let selected = filteredLogs.first(where: { $0.id == selectedLogID }) {
            return selected
        }
        return filteredLogs.first
    }

    private var projectOptions: [String] {
        [allProjectsLabel] + Array(Set(rawLogs.map(\.displayProjectName))).sorted()
    }

    private var repositoryOptions: [String] {
        [allRepositoriesLabel] + Array(Set(rawLogs.map(\.displayRepositoryName))).sorted()
    }

    private var availableAgents: [AIAgentTool] {
        Array(Set(rawLogs.map(\.agentTool))).sorted { $0.displayName < $1.displayName }
    }

    @ViewBuilder
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("Suche nach Prompt, Projekt, Repository oder Agent", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Agent", selection: Binding(
                    get: { selectedAgent },
                    set: { selectedAgent = $0 }
                )) {
                    Text("Alle Agenten").tag(Optional<AIAgentTool>.none)
                    ForEach(availableAgents) { tool in
                        Text(tool.displayName).tag(Optional(tool))
                    }
                }
                .frame(width: 170)

                Picker("Projekt", selection: $selectedProject) {
                    ForEach(projectOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .frame(width: 180)

                Picker("Repository", selection: $selectedRepository) {
                    ForEach(repositoryOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .frame(width: 200)
            }

            Text("\(filteredLogs.count) archivierte Logs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    @ViewBuilder
    private func detailView(for record: AgentRawLogRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(record.agentTool.displayName, systemImage: record.agentTool.systemImageName)
                        .font(.title3.weight(.semibold))
                    Text(record.title)
                        .font(.headline)
                    Text(record.logFileURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        appModel.copyRawLogContents(record)
                    } label: {
                        Label("Kopieren", systemImage: "doc.on.doc")
                    }

                    Button {
                        appModel.revealRawLogInFinder(record)
                    } label: {
                        Label("Im Finder", systemImage: "folder")
                    }

                    Button {
                        appModel.openRawLogExternally(record)
                    } label: {
                        Label("Extern oeffnen", systemImage: "arrow.up.forward.app")
                    }

                    Button(role: .destructive) {
                        pendingDeletion = record
                    } label: {
                        Label("Loeschen", systemImage: "trash")
                    }
                    .disabled(record.status == .running)
                }
                .buttonStyle(.bordered)
            }

            metadataGrid(for: record)

            GroupBox("Prompt") {
                ScrollView {
                    Text(record.promptText?.nonEmpty ?? "Kein initialer Prompt gespeichert.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
                .frame(minHeight: 90, maxHeight: 160)
            }

            GroupBox("RAW Log") {
                if let logLoadError {
                    ContentUnavailableView("Log konnte nicht geladen werden", systemImage: "exclamationmark.triangle", description: Text(logLoadError))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: .constant(logText))
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.black.opacity(0.92))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .navigationTitle(record.title)
    }

    @ViewBuilder
    private func metadataGrid(for record: AgentRawLogRecord) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            GridRow {
                metadataValue("Projekt", value: record.displayProjectName, secondary: record.projectName == nil)
                metadataValue("Repository", value: record.displayRepositoryName, secondary: record.repositoryName == nil)
                metadataValue("Worktree", value: record.displayWorktreeName, secondary: record.worktreeBranchName == nil)
            }
            GridRow {
                metadataValue("Status", value: record.status.rawValue.capitalized, color: statusColor(for: record.status))
                metadataValue("Start", value: record.startedAt.formatted(date: .abbreviated, time: .shortened))
                metadataValue("Dauer", value: durationText(for: record))
            }
            GridRow {
                metadataValue("Ende", value: record.endedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Laeuft")
                metadataValue("Dateigroesse", value: ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                metadataValue("Run ID", value: record.runID?.uuidString ?? "Kein persistierter Run")
            }
        }
    }

    @ViewBuilder
    private func metadataValue(
        _ title: String,
        value: String,
        secondary: Bool = false,
        color: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ensureSelection() {
        if let selectedLogID, filteredLogs.contains(where: { $0.id == selectedLogID }) {
            return
        }
        selectedLogID = filteredLogs.first?.id
    }

    @MainActor
    private func reloadSelectedLog() async {
        guard let selectedRecord else {
            logText = ""
            logLoadError = nil
            return
        }

        do {
            logText = try appModel.rawLogContents(selectedRecord)
            logLoadError = nil
        } catch {
            logText = ""
            logLoadError = error.localizedDescription
        }
    }

    private func durationText(for record: AgentRawLogRecord) -> String {
        let seconds: Int
        if let durationSeconds = record.durationSeconds {
            seconds = max(0, Int(durationSeconds.rounded()))
        } else if let endedAt = record.endedAt {
            seconds = max(0, Int(endedAt.timeIntervalSince(record.startedAt).rounded()))
        } else if record.status == .running {
            return "…"
        } else {
            return "-"
        }

        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
    }

    private func statusColor(for status: RunStatusKind) -> Color {
        switch status {
        case .pending, .running:
            .orange
        case .succeeded:
            .green
        case .failed:
            .red
        case .cancelled:
            .gray
        }
    }
}
