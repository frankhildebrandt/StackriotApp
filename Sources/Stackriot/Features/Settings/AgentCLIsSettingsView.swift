import SwiftUI

struct AgentCLIsSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedCLI: AgentCLISettingsDestination = .copilot

    var body: some View {
        SettingsFormPage(category: .agentCLIs) {
            Section {
                Picker("CLI", selection: $selectedCLI) {
                    ForEach(AgentCLISettingsDestination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
            } footer: {
                Text("Stackriot keeps terminal-agent CLIs separate from the in-app AI provider configuration.")
            }

            switch selectedCLI {
            case .claude:
                ClaudeCLISettingsView()
            case .codex:
                CodexCLISettingsView()
            case .cursor:
                CursorCLISettingsView()
            case .copilot:
                CopilotCLISettingsView()
            case .openCode:
                OpenCodeCLISettingsView()
            }
        }
        .sheet(isPresented: Binding(
            get: { appModel.isACPMetadataConsolePresented },
            set: { appModel.isACPMetadataConsolePresented = $0 }
        )) {
            ACPMetadataDiscoveryConsoleSheet()
        }
    }
}

private enum AgentCLISettingsDestination: String, CaseIterable, Identifiable {
    case claude
    case codex
    case cursor
    case copilot
    case openCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:
            "Claude Code"
        case .codex:
            "Codex"
        case .cursor:
            "Cursor"
        case .copilot:
            "GitHub Copilot"
        case .openCode:
            "OpenCode"
        }
    }
}

struct ClaudeCLISettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AgentACPMetadataSection(
            tool: .claudeCode,
            title: "Claude Code",
            snapshot: appModel.acpAgentSnapshotsByTool[.claudeCode],
            report: appModel.acpMetadataDiscoveryReportsByTool[.claudeCode],
            isRefreshing: appModel.isRefreshingACPMetadata,
            lastRefreshAt: appModel.lastACPMetadataRefreshAt,
            emptyStateText: "No ACP metadata available yet for Claude Code.",
            refreshAction: { appModel.refreshACPMetadata() },
            cancelAction: { appModel.cancelACPMetadataRefresh() },
            openConsoleAction: { appModel.isACPMetadataConsolePresented = true }
        ) {}
    }
}

struct CodexCLISettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AgentACPMetadataSection(
            tool: .codex,
            title: "Codex",
            snapshot: appModel.acpAgentSnapshotsByTool[.codex],
            report: appModel.acpMetadataDiscoveryReportsByTool[.codex],
            isRefreshing: appModel.isRefreshingACPMetadata,
            lastRefreshAt: appModel.lastACPMetadataRefreshAt,
            emptyStateText: "No ACP metadata available yet for Codex.",
            refreshAction: { appModel.refreshACPMetadata() },
            cancelAction: { appModel.cancelACPMetadataRefresh() },
            openConsoleAction: { appModel.isACPMetadataConsolePresented = true }
        ) {}
    }
}

struct CursorCLISettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AgentACPMetadataSection(
            tool: .cursorCLI,
            title: "Cursor",
            snapshot: appModel.acpAgentSnapshotsByTool[.cursorCLI],
            report: appModel.acpMetadataDiscoveryReportsByTool[.cursorCLI],
            isRefreshing: appModel.isRefreshingACPMetadata,
            lastRefreshAt: appModel.lastACPMetadataRefreshAt,
            emptyStateText: "No ACP metadata available yet for Cursor.",
            refreshAction: { appModel.refreshACPMetadata() },
            cancelAction: { appModel.cancelACPMetadataRefresh() },
            openConsoleAction: { appModel.isACPMetadataConsolePresented = true }
        ) {}
    }
}

struct OpenCodeCLISettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        AgentACPMetadataSection(
            tool: .openCode,
            title: "OpenCode",
            snapshot: snapshot,
            report: appModel.acpMetadataDiscoveryReportsByTool[.openCode],
            isRefreshing: appModel.isRefreshingACPMetadata,
            lastRefreshAt: appModel.lastACPMetadataRefreshAt,
            emptyStateText: "OpenCode did not publish ACP metadata yet.",
            refreshAction: { appModel.refreshACPMetadata() },
            cancelAction: { appModel.cancelACPMetadataRefresh() },
            openConsoleAction: { appModel.isACPMetadataConsolePresented = true },
            footer: "Stackriot reads OpenCode's ACP handshake to show the live model catalog, auth hint, and advertised session modes."
        ) {
            if let modelOption {
                Picker("Default model", selection: Binding(
                    get: {
                        AppPreferences.defaultACPConfigValue(for: .openCode, configOption: modelOption)
                    },
                    set: { newValue in
                        AppPreferences.setDefaultACPConfigValue(newValue, for: .openCode, configOption: modelOption)
                    }
                )) {
                    ForEach(modelOption.flatOptions) { option in
                        Text(option.displayName).tag(option.value)
                    }
                }
            }
        }
    }

    private var snapshot: ACPAgentSnapshot? {
        appModel.acpAgentSnapshotsByTool[.openCode]
    }

    private var modelOption: ACPDiscoveredConfigOption? {
        guard let snapshot, snapshot.models.isEmpty == false else { return nil }
        let options = snapshot.models.map {
            ACPDiscoveredConfigValue(value: $0.id, displayName: $0.displayName, description: $0.description)
        }
        return ACPDiscoveredConfigOption(
            id: "model",
            displayName: "Model",
            description: "ACP-discovered OpenCode model catalog.",
            rawCategory: ACPDiscoveredConfigSemanticCategory.model.rawValue,
            currentValue: snapshot.currentModelID ?? options[0].value,
            groups: [ACPDiscoveredConfigValueGroup(groupID: nil, displayName: nil, options: options)]
        )
    }
}

private struct AgentACPMetadataSection<Content: View>: View {
    let tool: AIAgentTool
    let title: String
    let snapshot: ACPAgentSnapshot?
    let report: ACPMetadataDiscoveryReport?
    let isRefreshing: Bool
    let lastRefreshAt: Date?
    let emptyStateText: String
    let footer: String?
    let content: Content
    let refreshAction: () -> Void
    let cancelAction: () -> Void
    let openConsoleAction: () -> Void

    init(
        tool: AIAgentTool,
        title: String,
        snapshot: ACPAgentSnapshot?,
        report: ACPMetadataDiscoveryReport?,
        isRefreshing: Bool,
        lastRefreshAt: Date?,
        emptyStateText: String,
        refreshAction: @escaping () -> Void,
        cancelAction: @escaping () -> Void,
        openConsoleAction: @escaping () -> Void,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.tool = tool
        self.title = title
        self.snapshot = snapshot
        self.report = report
        self.isRefreshing = isRefreshing
        self.lastRefreshAt = lastRefreshAt
        self.emptyStateText = emptyStateText
        self.footer = footer
        self.content = content()
        self.refreshAction = refreshAction
        self.cancelAction = cancelAction
        self.openConsoleAction = openConsoleAction
    }

    var body: some View {
        Section {
            if let snapshot {
                ACPAgentSnapshotSummary(snapshot: snapshot)
                content
            } else {
                Text(emptyStateText)
                    .foregroundStyle(.secondary)
            }

            ACPMetadataDiscoveryStatusView(
                tool: tool,
                report: report,
                isRefreshing: isRefreshing,
                lastRefreshAt: lastRefreshAt
            )

            HStack(spacing: 12) {
                Button("Refresh ACP metadata") {
                    refreshAction()
                }
                .disabled(isRefreshing)

                if isRefreshing {
                    Button("Cancel ACP refresh") {
                        cancelAction()
                    }
                }

                Button("Open discovery console") {
                    openConsoleAction()
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}

struct ACPMetadataDiscoveryStatusView: View {
    let tool: AIAgentTool
    let report: ACPMetadataDiscoveryReport?
    let isRefreshing: Bool
    let lastRefreshAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isRefreshing {
                ProgressView("Refreshing ACP metadata for installed CLIs...")
                    .controlSize(.small)
            }

            if let report {
                Label(report.summary, systemImage: systemImageName(for: report.status))
                    .foregroundStyle(color(for: report.status))

                if let executablePath = report.executablePath?.nonEmpty {
                    Text(executablePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let detail = report.detail?.nonEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            } else if !isRefreshing, let lastRefreshAt {
                Text("\(tool.displayName) was checked on \(lastRefreshAt, format: .dateTime.year().month().day().hour().minute().second()).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastRefreshAt, report != nil {
                Text("Last refreshed \(lastRefreshAt, format: .dateTime.year().month().day().hour().minute().second())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func systemImageName(for status: ACPMetadataDiscoveryStatus) -> String {
        switch status {
        case .running:
            "arrow.triangle.2.circlepath.circle.fill"
        case .succeeded:
            "checkmark.circle.fill"
        case .unavailable:
            "exclamationmark.triangle.fill"
        case .failed:
            "xmark.octagon.fill"
        case .cancelled:
            "stop.circle.fill"
        }
    }

    private func color(for status: ACPMetadataDiscoveryStatus) -> Color {
        switch status {
        case .running:
            .blue
        case .succeeded:
            .green
        case .unavailable:
            .orange
        case .failed:
            .red
        case .cancelled:
            .secondary
        }
    }
}

private struct ACPMetadataDiscoveryConsoleSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private var reports: [ACPMetadataDiscoveryReport] {
        AIAgentTool.allCases.compactMap { tool in
            guard tool.supportsACPDiscovery else { return nil }
            return appModel.acpMetadataDiscoveryReportsByTool[tool]
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if reports.isEmpty {
                    ContentUnavailableView(
                        "No ACP discovery output yet",
                        systemImage: "terminal",
                        description: Text("Click Refresh ACP metadata to start a visible ACP handshake and collect CLI diagnostics.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let summary = appModel.acpMetadataRefreshSummary?.nonEmpty {
                                Text(summary)
                                    .font(.headline)
                            }

                            ForEach(reports, id: \.tool) { report in
                                GroupBox(report.tool.displayName) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Label(report.summary, systemImage: systemImageName(for: report.status))
                                            .foregroundStyle(color(for: report.status))

                                        if let finishedAt = report.finishedAt {
                                            Text("Updated \(finishedAt, format: .dateTime.year().month().day().hour().minute().second())")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else if let startedAt = report.startedAt {
                                            Text("Started \(startedAt, format: .dateTime.year().month().day().hour().minute().second())")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Text(report.detail ?? "No diagnostics available.")
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(10)
                                            .background(.black.opacity(0.06))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("ACP Discovery Console")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if appModel.isRefreshingACPMetadata {
                        Button("Cancel Refresh") {
                            appModel.cancelACPMetadataRefresh()
                        }
                    } else {
                        Button("Refresh") {
                            appModel.refreshACPMetadata()
                        }
                    }
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func systemImageName(for status: ACPMetadataDiscoveryStatus) -> String {
        switch status {
        case .running:
            "arrow.triangle.2.circlepath.circle.fill"
        case .succeeded:
            "checkmark.circle.fill"
        case .unavailable:
            "exclamationmark.triangle.fill"
        case .failed:
            "xmark.octagon.fill"
        case .cancelled:
            "stop.circle.fill"
        }
    }

    private func color(for status: ACPMetadataDiscoveryStatus) -> Color {
        switch status {
        case .running:
            .blue
        case .succeeded:
            .green
        case .unavailable:
            .orange
        case .failed:
            .red
        case .cancelled:
            .secondary
        }
    }
}
