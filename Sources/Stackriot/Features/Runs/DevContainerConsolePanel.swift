import SwiftUI

struct DevContainerConsolePanel: View {
    @Environment(AppModel.self) private var appModel

    let worktree: WorktreeRecord

    @State private var showLogs = false

    private var state: DevContainerWorkspaceState {
        appModel.devContainerState(for: worktree)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    StatChip(title: "Status", value: statusValue)
                    StatChip(title: "Container", value: containerValue)
                    StatChip(title: "Image", value: imageValue)
                    StatChip(title: "CPU", value: cpuValue)
                    StatChip(title: "Memory", value: memoryValue)
                }
                .padding(.vertical, 1)
            }

            if let message = state.detailsErrorMessage?.nonEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if showLogs {
                DevContainerLogView(
                    text: state.logs,
                    isStreaming: state.isLogStreaming,
                    emptyMessage: logPlaceholder
                )
                .frame(maxWidth: .infinity)
                .frame(height: 220)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
        .onChange(of: showLogs) { _, newValue in
            Task {
                if newValue {
                    await appModel.startDevContainerLogStreaming(for: worktree)
                } else {
                    appModel.stopDevContainerLogStreaming(for: worktree.id)
                }
            }
        }
        .onChange(of: state.containerID) { _, _ in
            guard showLogs else { return }
            Task {
                appModel.stopDevContainerLogStreaming(for: worktree.id)
                await appModel.startDevContainerLogStreaming(for: worktree)
            }
        }
        .onDisappear {
            appModel.stopDevContainerLogStreaming(for: worktree.id)
        }
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

            Button(showLogs ? "Hide Logs" : "Show Logs") {
                showLogs.toggle()
            }
            .buttonStyle(.bordered)
            .disabled(!state.hasContainer && !showLogs)
        }
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

private struct DevContainerLogView: View {
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
