import AppKit
import SwiftUI

struct MCPSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(AppPreferences.mcpEnabledKey) private var storedEnabled = AppPreferences.defaultMCPEnabled
    @AppStorage(AppPreferences.mcpListenAddressKey) private var storedListenAddress = AppPreferences.defaultMCPListenAddress
    @AppStorage(AppPreferences.mcpPortKey) private var storedPort = AppPreferences.defaultMCPPort
    @AppStorage(AppPreferences.mcpExposeReadOnlyToolsOnlyKey) private var storedReadOnlyOnly = AppPreferences.defaultMCPExposeReadOnlyToolsOnly

    @State private var listenAddress = AppPreferences.mcpListenAddress
    @State private var portText = String(AppPreferences.mcpPort)
    @State private var apiToken = AppPreferences.mcpAPIToken ?? ""
    @State private var exposeReadOnlyToolsOnly = AppPreferences.mcpExposeReadOnlyToolsOnly
    @State private var copiedSnippetKind: MCPClientSnippetKind?
    @State private var inlineMessage: String?

    var body: some View {
        SettingsScrollPage(category: .mcp) {
            VStack(alignment: .leading, spacing: 24) {
                statusCard
                configurationCard
                snippetsCard
                diagnosticsCard
            }
        }
        .task {
            syncDraftsFromPreferences()
            appModel.refreshMCPServerConfiguration()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(statusTitle, systemImage: statusSymbolName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(statusColor)
                    Text(appModel.mcpServerStatus.lastEventMessage ?? "Configure the local MCP endpoint and expose Stackriot context to external clients.")
                        .foregroundStyle(.secondary)
                    Text(appModel.mcpServerStatus.endpointURLString)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Text("Sessions: \(appModel.mcpServerStatus.activeSessionCount)")
                        .foregroundStyle(.secondary)
                    if let startedAt = appModel.mcpServerStatus.startedAt {
                        Text(startedAt, format: .dateTime.year().month().day().hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = appModel.mcpServerStatus.lastErrorMessage?.nonEmpty {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button(appModel.mcpServerStatus.isRunning ? "Stop Server" : "Start Server") {
                    persistDraftConfiguration()
                    appModel.mcpServerStatus.isRunning ? appModel.stopMCPServer() : appModel.startMCPServer()
                }
                .keyboardShortcut(.defaultAction)

                Button("Restart") {
                    persistDraftConfiguration()
                    appModel.restartMCPServer()
                }
                .disabled(!storedEnabled)

                Spacer()

                Text(storedEnabled ? "Enabled" : "Disabled")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configuration")
                .font(.headline)

            Toggle("Enable local MCP server", isOn: $storedEnabled)
                .onChange(of: storedEnabled) { _, _ in
                    persistDraftConfiguration()
                    appModel.refreshMCPServerConfiguration()
                }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Listen address")
                        .font(.subheadline.weight(.medium))
                    TextField("127.0.0.1", text: $listenAddress)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Port")
                        .font(.subheadline.weight(.medium))
                    TextField("8765", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API token")
                    .font(.subheadline.weight(.medium))
                SecureField("Bearer token required by MCP clients", text: $apiToken)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Generate Token") {
                        apiToken = randomToken()
                    }
                    Button("Copy Token") {
                        copyToPasteboard(apiToken)
                        inlineMessage = "API token copied."
                    }
                    .disabled(apiToken.isEmpty)
                }
            }

            Toggle("Expose read-only tools only", isOn: $exposeReadOnlyToolsOnly)
                .help("V1 keeps the server strictly read-only. Leave this enabled.")

            HStack {
                Button("Apply Configuration") {
                    persistDraftConfiguration()
                    appModel.refreshMCPServerConfiguration()
                    inlineMessage = "MCP configuration applied."
                }

                Spacer()

                if let inlineMessage {
                    Text(inlineMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var snippetsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Client snippets")
                .font(.headline)
            Text("Paste one of these snippets into your preferred MCP client and keep the bearer token with the copied configuration.")
                .foregroundStyle(.secondary)

            ForEach(MCPClientSnippetKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .font(.subheadline.weight(.semibold))
                            Text(kind.fileHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(copiedSnippetKind == kind ? "Copied" : "Copy") {
                            copyToPasteboard(snippet(for: kind))
                            copiedSnippetKind = kind
                        }
                    }

                    ScrollView(.horizontal) {
                        Text(snippet(for: kind))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Diagnostics")
                    .font(.headline)
                Spacer()
                Button("Clear Logs") {
                    appModel.clearMCPLogs()
                }
                .disabled(appModel.mcpLogEntries.isEmpty)
            }

            if appModel.mcpLogEntries.isEmpty {
                Text("No MCP activity yet. Start the server and connect with an MCP client or Inspector to populate request logs.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(appModel.mcpLogEntries.prefix(40)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(entry.category.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.level.rawValue.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(levelColor(entry.level))
                            }

                            Text(entry.message)
                                .font(.callout)

                            if !entry.metadata.isEmpty {
                                Text(entry.metadata.keys.sorted().map { "\($0)=\(entry.metadata[$0] ?? "")" }.joined(separator: "  "))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(12)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusTitle: String {
        switch appModel.mcpServerStatus.state {
        case .running:
            "Running"
        case .starting:
            "Starting"
        case .error:
            "Needs attention"
        case .stopped:
            "Stopped"
        }
    }

    private var statusSymbolName: String {
        switch appModel.mcpServerStatus.state {
        case .running:
            "checkmark.circle.fill"
        case .starting:
            "arrow.triangle.2.circlepath.circle.fill"
        case .error:
            "exclamationmark.triangle.fill"
        case .stopped:
            "pause.circle.fill"
        }
    }

    private var statusColor: Color {
        switch appModel.mcpServerStatus.state {
        case .running:
            .green
        case .starting:
            .orange
        case .error:
            .red
        case .stopped:
            .secondary
        }
    }

    private func syncDraftsFromPreferences() {
        listenAddress = AppPreferences.mcpListenAddress
        portText = String(AppPreferences.mcpPort)
        apiToken = AppPreferences.mcpAPIToken ?? ""
        exposeReadOnlyToolsOnly = AppPreferences.mcpExposeReadOnlyToolsOnly
    }

    private func persistDraftConfiguration() {
        storedListenAddress = listenAddress.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? AppPreferences.defaultMCPListenAddress
        storedPort = Int(portText) ?? AppPreferences.defaultMCPPort
        storedReadOnlyOnly = exposeReadOnlyToolsOnly
        persistToken(apiToken)
    }

    private func persistToken(_ token: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            KeychainSecretStore.delete(service: KeychainSecretStore.mcpService, account: KeychainSecretStore.mcpTokenAccount)
            return
        }

        do {
            try KeychainSecretStore.storeString(trimmedToken, service: KeychainSecretStore.mcpService, account: KeychainSecretStore.mcpTokenAccount)
        } catch {
            inlineMessage = "Failed to store MCP token in Keychain: \(error.localizedDescription)"
        }
    }

    private func snippet(for kind: MCPClientSnippetKind) -> String {
        let configuration = MCPServerConfiguration(
            enabled: storedEnabled,
            listenAddress: storedListenAddress.nonEmpty ?? AppPreferences.defaultMCPListenAddress,
            port: storedPort,
            apiToken: apiToken.nonEmpty,
            exposeReadOnlyToolsOnly: storedReadOnlyOnly
        )
        let endpoint = configuration.endpointURLString
        let token = apiToken.nonEmpty ?? "PASTE_STACKRIOT_TOKEN"

        switch kind {
        case .codex:
            return """
            [mcp_servers.stackriot]
            url = "\(endpoint)"
            http_headers = { Authorization = "Bearer \(token)" }
            startup_timeout_sec = 20
            tool_timeout_sec = 60
            """
        case .cursor:
            return """
            {
              "mcpServers": {
                "stackriot": {
                  "type": "streamable-http",
                  "url": "\(endpoint)",
                  "headers": {
                    "Authorization": "Bearer \(token)"
                  }
                }
              }
            }
            """
        case .claudeDesktop:
            return """
            {
              "mcpServers": {
                "stackriot": {
                  "type": "http",
                  "url": "\(endpoint)",
                  "authorization": "Bearer \(token)"
                }
              }
            }
            """
        case .generic:
            return """
            {
              "name": "stackriot",
              "transport": {
                "type": "streamable-http",
                "url": "\(endpoint)",
                "headers": {
                  "Authorization": "Bearer \(token)",
                  "Accept": "application/json, text/event-stream"
                }
              }
            }
            """
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func levelColor(_ level: MCPLogLevel) -> Color {
        switch level {
        case .debug:
            .secondary
        case .info, .notice:
            .blue
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    private func randomToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
