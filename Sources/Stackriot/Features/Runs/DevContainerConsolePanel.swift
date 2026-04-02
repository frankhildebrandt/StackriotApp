import SwiftUI

struct DevContainerConsolePanel: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let worktree: WorktreeRecord

    private var state: DevContainerWorkspaceState {
        appModel.devContainerState(for: worktree)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if shouldShowDiagnostics {
                diagnosticsCard
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    StatChip(title: "Status", value: statusValue)
                    StatChip(title: "Container", value: containerValue)
                    StatChip(title: "Image", value: imageValue)
                    StatChip(title: "CPU", value: cpuValue)
                    StatChip(title: "Memory", value: memoryValue)
                    StatChip(title: "CLI", value: cliValue)
                }
                .padding(.vertical, 1)
            }

            if let message = state.detailsErrorMessage?.nonEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Devcontainer", systemImage: "shippingbox.fill")
                    .font(.subheadline.weight(.semibold))
                if let configurationPath = state.configuration?.displayPath {
                    Text(configurationPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let lastUpdatedAt = state.lastUpdatedAt {
                    Text("Last checked \(lastUpdatedAt, format: .dateTime.hour().minute().second())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if state.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(state.activeOperation?.progressTitle ?? "Working")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task {
                    await appModel.refreshDevContainerState(for: worktree)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(state.isBusy)
            .help("Devcontainer-Status aktualisieren")

            Button {
                Task {
                    await appModel.openDevContainerTerminal(for: worktree, in: modelContext)
                }
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
            .disabled(!state.canOpenTerminal)

            Button {
                guard let repository = worktree.repository else { return }
                appModel.openDevContainerLogs(for: worktree, in: repository)
            } label: {
                Label("Logs", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: diagnosticsIconName)
                    .foregroundStyle(diagnosticsColor)
                Text(state.diagnosticIssue?.displayTitle ?? "Diagnostics")
                    .font(.subheadline.weight(.semibold))
            }

            Text(diagnosticsMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let help = installHelpText {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                SettingsLink {
                    Text("Open Settings")
                }
                .buttonStyle(.bordered)

                if state.diagnosticIssue == .dockerMissing || state.diagnosticIssue == .cliUnavailable || state.diagnosticIssue == .featureDisabled {
                    Button("Refresh") {
                        Task {
                            await appModel.refreshDevContainerState(for: worktree)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(diagnosticsColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statusValue: String {
        if let activeOperation = state.activeOperation {
            return activeOperation.progressTitle
        }
        return state.runtimeStatus.displayName
    }

    private var containerValue: String {
        if let name = state.containerName?.nonEmpty {
            return name
        }
        if let containerID = state.containerID?.nonEmpty {
            return String(containerID.prefix(12))
        }
        return "—"
    }

    private var imageValue: String {
        state.imageName?.nonEmpty ?? "—"
    }

    private var cpuValue: String {
        state.resourceUsage?.cpuPercent?.nonEmpty ?? "—"
    }

    private var memoryValue: String {
        if let usage = state.resourceUsage?.memoryUsage?.nonEmpty,
           let percent = state.resourceUsage?.memoryPercent?.nonEmpty {
            return "\(usage) · \(percent)"
        }
        return state.resourceUsage?.memoryUsage?.nonEmpty ?? "—"
    }

    private var cliValue: String {
        state.toolingStatus.resolvedCLI?.displayName ?? "Unavailable"
    }

    private var shouldShowDiagnostics: Bool {
        state.diagnosticIssue != nil
    }

    private var diagnosticsIconName: String {
        switch state.diagnosticIssue {
        case .featureDisabled:
            "gearshape.2"
        case .dockerMissing, .cliUnavailable:
            "wrench.and.screwdriver"
        case .dockerUnreachable, .containerUnreachable:
            "exclamationmark.triangle.fill"
        case .noConfiguration, nil:
            "info.circle"
        }
    }

    private var diagnosticsColor: Color {
        switch state.diagnosticIssue {
        case .dockerMissing, .cliUnavailable, .dockerUnreachable, .containerUnreachable:
            .orange
        case .featureDisabled:
            .blue
        case .noConfiguration, nil:
            .secondary
        }
    }

    private var diagnosticsMessage: String {
        switch state.diagnosticIssue {
        case .featureDisabled:
            return "Devcontainer support is disabled globally. Re-enable it in Settings to inspect or control containers."
        case .dockerMissing:
            return "Stackriot needs the `docker` command to inspect, stop, remove, and attach to devcontainers."
        case .dockerUnreachable:
            return state.detailsErrorMessage?.nonEmpty ?? "Docker is installed but not reachable."
        case .cliUnavailable:
            return "No supported devcontainer CLI is currently available for the configured strategy."
        case .containerUnreachable:
            return state.detailsErrorMessage?.nonEmpty ?? "The container could not be inspected."
        case .noConfiguration:
            return "This worktree does not contain a devcontainer configuration."
        case nil:
            return state.detailsErrorMessage?.nonEmpty ?? "No diagnostics available."
        }
    }

    private var installHelpText: String? {
        switch state.diagnosticIssue {
        case .dockerMissing:
            return "Install Docker Desktop or another Docker engine so the `docker` CLI is available in your shell."
        case .cliUnavailable:
            return "Either install the Dev Containers CLI so `devcontainer` exists, or use Node.js so Stackriot can fall back to `npx @devcontainers/cli`."
        case .featureDisabled:
            return "Settings > Devcontainers controls whether Stackriot monitors and exposes devcontainer workflows."
        default:
            return nil
        }
    }
}

struct DevContainerLogsTabView: View {
    @Environment(AppModel.self) private var appModel

    let worktree: WorktreeRecord

    private var state: DevContainerWorkspaceState {
        appModel.devContainerState(for: worktree)
    }

    var body: some View {
        DevContainerLogView(
            text: state.logs,
            isStreaming: state.isLogStreaming,
            emptyMessage: logPlaceholder
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: worktree.id) {
            await appModel.startDevContainerLogStreaming(for: worktree)
        }
        .onChange(of: state.containerID) { _, _ in
            Task {
                appModel.stopDevContainerLogStreaming(for: worktree.id)
                await appModel.startDevContainerLogStreaming(for: worktree)
            }
        }
        .onDisappear {
            appModel.stopDevContainerLogStreaming(for: worktree.id)
        }
    }

    private var logPlaceholder: String {
        if state.isRunning {
            return "No logs have been received from the container yet."
        }
        if state.hasContainer {
            return "Start the container to stream logs here."
        }
        return "No devcontainer container exists for this workspace yet."
    }
}

struct DevContainerLogView: View {
    let text: String
    let isStreaming: Bool
    let emptyMessage: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Container Logs")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isStreaming {
                            Label("Streaming", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(text.nonEmpty ?? emptyMessage)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}
