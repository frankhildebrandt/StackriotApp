import Foundation
import Network

actor MCPServerManager {
    typealias StatusHandler = @Sendable (MCPServerStatus) async -> Void
    typealias LogHandler = @Sendable (MCPLogEntry) async -> Void

    private struct SessionState: Sendable {
        let id: String
        let clientName: String?
        let protocolVersion: String
        var initializedAt: Date?
        let createdAt: Date
    }

    private struct HTTPRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct HTTPResponse {
        let statusCode: Int
        let statusText: String
        let headers: [String: String]
        let body: Data

        func serialized() -> Data {
            var lines = ["HTTP/1.1 \(statusCode) \(statusText)"]
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                lines.append("\(key): \(value)")
            }
            lines.append("Content-Length: \(body.count)")
            lines.append("Connection: close")
            lines.append("")
            let headerData = lines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
            return headerData + Data("\r\n".utf8) + body
        }
    }

    private struct JSONRPCErrorPayload: Encodable, Sendable {
        let code: Int
        let message: String
        let data: JSONValue?
    }

    private struct JSONRPCResponseEnvelope: Encodable, Sendable {
        let jsonrpc = "2.0"
        let id: JSONValue?
        let result: JSONValue?
        let error: JSONRPCErrorPayload?
    }

    private let configurationProvider: @Sendable () -> MCPServerConfiguration
    private var toolRegistry: MCPToolRegistry?
    private var statusHandler: StatusHandler?
    private var logHandler: LogHandler?
    private let queue = DispatchQueue(label: "Stackriot.MCPServer")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var sessions: [String: SessionState] = [:]
    private var status = MCPServerStatus.idle()
    private var lastIssuedSessionID: String?

    init(configurationProvider: @escaping @Sendable () -> MCPServerConfiguration = { AppPreferences.mcpConfiguration }) {
        self.configurationProvider = configurationProvider
        status = MCPServerStatus.idle(configuration: configurationProvider())
    }

    func configure(
        toolRegistry: MCPToolRegistry,
        statusHandler: StatusHandler?,
        logHandler: LogHandler?
    ) async {
        self.toolRegistry = toolRegistry
        self.statusHandler = statusHandler
        self.logHandler = logHandler
        await publishStatus()
    }

    func refreshConfiguration() async {
        let configuration = configurationProvider()
        if configuration.enabled {
            await restart()
        } else {
            await stop(message: "MCP server stopped.")
        }
    }

    func start() async {
        let configuration = configurationProvider()
        guard configuration.enabled else {
            await stop(message: "MCP server is disabled in settings.")
            return
        }
        guard let registry = toolRegistry else {
            await updateStatus(
                state: .error,
                configuration: configuration,
                lastErrorMessage: "MCP tool registry is not configured yet.",
                lastEventMessage: "Cannot start MCP server."
            )
            return
        }
        _ = registry
        guard let token = configuration.apiToken?.nonEmpty else {
            await updateStatus(
                state: .error,
                configuration: configuration,
                lastErrorMessage: "API token missing.",
                lastEventMessage: "Configure an API token before starting the MCP server."
            )
            await emitLog(.error, category: "server", message: "Refused to start MCP server without an API token.")
            return
        }
        _ = token

        if listener != nil {
            await stop(message: "Restarting MCP server.")
        }

        await updateStatus(state: .starting, configuration: configuration, lastErrorMessage: nil, lastEventMessage: "Starting MCP server …")

        do {
            let port = try nwPort(for: configuration.port)
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .init(configuration.listenAddress), port: port)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.handleListenerState(state, configuration: configuration) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.accept(connection: connection) }
            }
            self.listener = listener
            listener.start(queue: queue)
            await emitLog(.info, category: "server", message: "Starting MCP server.", metadata: [
                "address": configuration.listenAddress,
                "port": "\(configuration.port)",
            ])
        } catch {
            listener = nil
            await updateStatus(
                state: .error,
                configuration: configuration,
                lastErrorMessage: error.localizedDescription,
                lastEventMessage: "Failed to bind MCP server."
            )
            await emitLog(.error, category: "server", message: "Failed to start MCP server.", metadata: [
                "error": error.localizedDescription,
            ])
        }
    }

    func restart() async {
        await stop(message: "Restarting MCP server.")
        await start()
    }

    func stop(message: String = "MCP server stopped.") async {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        sessions.removeAll()
        lastIssuedSessionID = nil
        let configuration = configurationProvider()
        await updateStatus(
            state: .stopped,
            configuration: configuration,
            lastErrorMessage: nil,
            lastEventMessage: message
        )
        await emitLog(.info, category: "server", message: message)
    }

    func statusSnapshot() -> MCPServerStatus {
        status
    }

    private func accept(connection: NWConnection) async {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleConnectionState(state, connectionID: id) }
        }
        connection.start(queue: queue)

        do {
            let request = try await readRequest(from: connection)
            let response = await handle(request: request)
            try await send(response.serialized(), on: connection)
        } catch {
            let response = makePlainResponse(
                statusCode: 400,
                statusText: "Bad Request",
                body: "Invalid MCP request: \(error.localizedDescription)"
            )
            try? await send(response.serialized(), on: connection)
            await emitLog(.warning, category: "request", message: "Rejected malformed MCP request.", metadata: [
                "error": error.localizedDescription,
            ])
        }

        connection.cancel()
        connections.removeValue(forKey: id)
    }

    private func handleConnectionState(_ state: NWConnection.State, connectionID: UUID) async {
        switch state {
        case .failed(let error):
            connections.removeValue(forKey: connectionID)
            await emitLog(.warning, category: "connection", message: "MCP connection failed.", metadata: [
                "error": error.localizedDescription,
            ])
        case .cancelled:
            connections.removeValue(forKey: connectionID)
        default:
            break
        }
    }

    private func handleListenerState(_ state: NWListener.State, configuration: MCPServerConfiguration) async {
        switch state {
        case .ready:
            await updateStatus(
                state: .running,
                configuration: configuration,
                lastErrorMessage: nil,
                lastEventMessage: "MCP server listening on \(configuration.endpointURLString)."
            )
            await emitLog(.info, category: "server", message: "MCP server is ready.", metadata: [
                "endpoint": configuration.endpointURLString,
            ])
        case .failed(let error):
            listener?.cancel()
            listener = nil
            await updateStatus(
                state: .error,
                configuration: configuration,
                lastErrorMessage: error.localizedDescription,
                lastEventMessage: "MCP server listener failed."
            )
            await emitLog(.error, category: "server", message: "MCP server listener failed.", metadata: [
                "error": error.localizedDescription,
            ])
        case .waiting(let error):
            await emitLog(.warning, category: "server", message: "MCP server waiting for network resources.", metadata: [
                "error": error.localizedDescription,
            ])
        case .cancelled:
            break
        default:
            break
        }
    }

    private func handle(request: HTTPRequest) async -> HTTPResponse {
        let configuration = configurationProvider()

        guard request.path == MCPServerConfiguration.endpointPath else {
            return makePlainResponse(statusCode: 404, statusText: "Not Found", body: "Unknown MCP endpoint.")
        }

        guard validateOrigin(request.headers["origin"], listenAddress: configuration.listenAddress) else {
            return makePlainResponse(statusCode: 403, statusText: "Forbidden", body: "Origin not allowed.")
        }

        guard authorize(headers: request.headers, expectedToken: configuration.apiToken) else {
            return makePlainResponse(statusCode: 401, statusText: "Unauthorized", body: "Missing or invalid bearer token.")
        }

        switch request.method {
        case "DELETE":
            return await handleDelete(headers: request.headers, configuration: configuration)
        case "GET":
            return makePlainResponse(
                statusCode: 405,
                statusText: "Method Not Allowed",
                body: "Stackriot MCP does not expose an SSE stream. Use POST requests on the MCP endpoint."
            )
        case "POST":
            return await handlePost(body: request.body, headers: request.headers, configuration: configuration)
        default:
            return makePlainResponse(statusCode: 405, statusText: "Method Not Allowed", body: "Unsupported HTTP method.")
        }
    }

    private func handleDelete(headers: [String: String], configuration: MCPServerConfiguration) async -> HTTPResponse {
        guard let sessionID = headers["mcp-session-id"]?.nonEmpty else {
            return makePlainResponse(statusCode: 400, statusText: "Bad Request", body: "Missing Mcp-Session-Id header.")
        }
        sessions.removeValue(forKey: sessionID)
        await updateStatus(
            state: status.state,
            configuration: configuration,
            lastErrorMessage: status.lastErrorMessage,
            lastEventMessage: "Closed MCP session \(sessionID)."
        )
        await emitLog(.info, category: "session", message: "Closed MCP session.", metadata: ["sessionId": sessionID])
        return HTTPResponse(statusCode: 204, statusText: "No Content", headers: [:], body: Data())
    }

    private func handlePost(body: Data, headers: [String: String], configuration: MCPServerConfiguration) async -> HTTPResponse {
        do {
            let payload = try JSONDecoder().decode(JSONValue.self, from: body)
            if let messages = payload.arrayValue {
                let containsInitialize = messages.contains { value in
                    value.objectValue?["method"]?.stringValue == "initialize"
                }
                if containsInitialize {
                    return jsonRPCErrorResponse(id: nil, code: -32600, message: "initialize must not be sent in a batch.")
                }
                var responses: [JSONRPCResponseEnvelope] = []
                for message in messages {
                    if let response = try await process(jsonrpcObject: message, headers: headers, configuration: configuration) {
                        responses.append(response)
                    }
                }
                return encodeJSONBody(responses.isEmpty ? nil : .array(try responses.map(JSONValue.fromEncodable)))
            }
            let method = payload.objectValue?["method"]?.stringValue
            guard let response = try await process(jsonrpcObject: payload, headers: headers, configuration: configuration) else {
                return HTTPResponse(statusCode: 202, statusText: "Accepted", headers: [:], body: Data())
            }
            let bodyValue = try JSONValue.fromEncodable(response)
            var extraHeaders: [String: String] = [:]
            if method == "initialize", let sessionID = lastIssuedSessionID {
                extraHeaders["Mcp-Session-Id"] = sessionID
            }
            return encodeJSONBody(bodyValue, extraHeaders: extraHeaders)
        } catch let error as MCPToolRegistryError {
            switch error {
            case let .invalidParams(message):
                return jsonRPCErrorResponse(id: nil, code: -32602, message: message)
            case let .unknownTool(name):
                return jsonRPCErrorResponse(id: nil, code: -32602, message: "Unknown tool: \(name)")
            case let .toolFailed(message):
                return jsonRPCErrorResponse(id: nil, code: -32603, message: message)
            }
        } catch {
            return jsonRPCErrorResponse(id: nil, code: -32700, message: "Failed to decode JSON body: \(error.localizedDescription)")
        }
    }

    private func process(
        jsonrpcObject value: JSONValue,
        headers: [String: String],
        configuration: MCPServerConfiguration
    ) async throws -> JSONRPCResponseEnvelope? {
        guard let object = value.objectValue else {
            return JSONRPCResponseEnvelope(id: nil, result: nil, error: .init(code: -32600, message: "Invalid JSON-RPC payload.", data: nil))
        }

        let id = object["id"]
        guard object["jsonrpc"]?.stringValue == "2.0" else {
            return JSONRPCResponseEnvelope(id: id, result: nil, error: .init(code: -32600, message: "jsonrpc must be 2.0.", data: nil))
        }

        guard let method = object["method"]?.stringValue else {
            return nil
        }

        let params = object["params"]?.objectValue ?? [:]

        switch method {
        case "initialize":
            let sessionID = UUID().uuidString
            let protocolVersion = params["protocolVersion"]?.stringValue ?? "2025-03-26"
            let clientName = params["clientInfo"]?.objectValue?["name"]?.stringValue
            sessions[sessionID] = SessionState(
                id: sessionID,
                clientName: clientName,
                protocolVersion: protocolVersion,
                initializedAt: nil,
                createdAt: .now
            )
            lastIssuedSessionID = sessionID
            await updateStatus(
                state: .running,
                configuration: configuration,
                lastErrorMessage: nil,
                lastEventMessage: "Initialized MCP session \(sessionID)."
            )
            await emitLog(.info, category: "session", message: "Initialized MCP session.", metadata: [
                "sessionId": sessionID,
                "client": clientName ?? "unknown",
            ])
            let result = JSONValue.object([
                "protocolVersion": .string("2025-03-26"),
                "capabilities": .object([
                    "tools": .object([
                        "listChanged": .bool(false),
                    ]),
                ]),
                "serverInfo": .object([
                    "name": .string("Stackriot MCP"),
                    "version": .string(Self.stackriotVersionString),
                ]),
                "instructions": .string("Stackriot exposes read-only repository, worktree, plan, and run context over MCP."),
            ])
            return JSONRPCResponseEnvelope(id: id, result: result, error: nil)
        case "notifications/initialized":
            guard let sessionID = headers["mcp-session-id"]?.nonEmpty else { return nil }
            if var session = sessions[sessionID] {
                session.initializedAt = .now
                sessions[sessionID] = session
                await updateStatus(
                    state: status.state,
                    configuration: configuration,
                    lastErrorMessage: status.lastErrorMessage,
                    lastEventMessage: "Client finished MCP initialization."
                )
            }
            return nil
        case "ping":
            try requireValidSessionIfPresent(headers: headers)
            return JSONRPCResponseEnvelope(id: id, result: .object([:]), error: nil)
        case "tools/list":
            try requireValidSession(headers: headers)
            let cursor = params["cursor"]?.stringValue
            guard let toolRegistry else {
                throw MCPToolRegistryError.toolFailed("MCP tool registry is unavailable.")
            }
            let tools = try toolRegistry.listTools(cursor: cursor)
            return JSONRPCResponseEnvelope(
                id: id,
                result: .object([
                    "tools": try .fromEncodable(tools),
                ]),
                error: nil
            )
        case "tools/call":
            try requireValidSession(headers: headers)
            guard let toolName = params["name"]?.stringValue?.nonEmpty else {
                throw MCPToolRegistryError.invalidParams("tools/call requires a tool name.")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            let startedAt = Date.now
            guard let toolRegistry else {
                throw MCPToolRegistryError.toolFailed("MCP tool registry is unavailable.")
            }
            let result = try await toolRegistry.callTool(named: toolName, arguments: arguments)
            let durationMS = Int(Date.now.timeIntervalSince(startedAt) * 1_000)
            await emitLog(result.isError ? .warning : .info, category: "tool", message: "Handled MCP tool call.", metadata: [
                "tool": toolName,
                "durationMs": "\(durationMS)",
                "isError": "\(result.isError)",
            ])
            return JSONRPCResponseEnvelope(id: id, result: try JSONValue.fromEncodable(result), error: nil)
        default:
            return JSONRPCResponseEnvelope(
                id: id,
                result: nil,
                error: .init(code: -32601, message: "Method not found: \(method)", data: nil)
            )
        }
    }

    private func requireValidSession(headers: [String: String]) throws {
        guard let sessionID = headers["mcp-session-id"]?.nonEmpty else {
            throw MCPToolRegistryError.invalidParams("Missing Mcp-Session-Id header. Call initialize first.")
        }
        guard sessions[sessionID] != nil else {
            throw MCPToolRegistryError.invalidParams("Unknown MCP session. Call initialize again.")
        }
    }

    private func requireValidSessionIfPresent(headers: [String: String]) throws {
        guard let sessionID = headers["mcp-session-id"]?.nonEmpty else { return }
        guard sessions[sessionID] != nil else {
            throw MCPToolRegistryError.invalidParams("Unknown MCP session. Call initialize again.")
        }
    }

    private func authorize(headers: [String: String], expectedToken: String?) -> Bool {
        guard let token = expectedToken?.nonEmpty else { return false }
        guard let authorization = headers["authorization"]?.nonEmpty else { return false }
        return authorization == "Bearer \(token)"
    }

    private func validateOrigin(_ origin: String?, listenAddress: String) -> Bool {
        guard let origin = origin?.nonEmpty else { return true }
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        let allowedHosts: Set<String> = [listenAddress.lowercased(), "localhost", "127.0.0.1", "::1"]
        return allowedHosts.contains(host)
    }

    private func readRequest(from connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()
        while true {
            let (chunk, isComplete) = try await receive(on: connection)
            buffer.append(chunk)
            if let request = try parseRequest(from: buffer) {
                return request
            }
            if isComplete {
                throw MCPToolRegistryError.toolFailed("Connection closed before the HTTP request completed.")
            }
            if buffer.count > 1_048_576 {
                throw MCPToolRegistryError.toolFailed("MCP request exceeded the maximum supported size.")
            }
        }
    }

    private func parseRequest(from data: Data) throws -> HTTPRequest? {
        guard let headerBoundary = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerBoundary.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw MCPToolRegistryError.toolFailed("Could not decode HTTP request headers.")
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw MCPToolRegistryError.toolFailed("Missing HTTP request line.")
        }
        let requestLineParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLineParts.count >= 2 else {
            throw MCPToolRegistryError.toolFailed("Malformed HTTP request line.")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerBoundary.upperBound
        let totalLength = data.distance(from: data.startIndex, to: bodyStart) + contentLength
        guard data.count >= totalLength else { return nil }
        let body = contentLength == 0 ? Data() : data[bodyStart ..< data.index(bodyStart, offsetBy: contentLength)]
        let rawPath = String(requestLineParts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        return HTTPRequest(
            method: String(requestLineParts[0]).uppercased(),
            path: path,
            headers: headers,
            body: Data(body)
        )
    }

    private func encodeJSONBody(_ value: JSONValue?, extraHeaders: [String: String] = [:]) -> HTTPResponse {
        guard let value else {
            return HTTPResponse(statusCode: 202, statusText: "Accepted", headers: [:], body: Data())
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(value)
            var headers = extraHeaders
            headers["Content-Type"] = "application/json"
            return HTTPResponse(statusCode: 200, statusText: "OK", headers: headers, body: body)
        } catch {
            return makePlainResponse(statusCode: 500, statusText: "Internal Server Error", body: error.localizedDescription)
        }
    }

    private func jsonRPCErrorResponse(id: JSONValue?, code: Int, message: String) -> HTTPResponse {
        let response = JSONRPCResponseEnvelope(id: id, result: nil, error: .init(code: code, message: message, data: nil))
        do {
            return encodeJSONBody(try JSONValue.fromEncodable(response))
        } catch {
            return makePlainResponse(statusCode: 500, statusText: "Internal Server Error", body: error.localizedDescription)
        }
    }

    private func makePlainResponse(statusCode: Int, statusText: String, body: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            statusText: statusText,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(body.utf8)
        )
    }

    private func updateStatus(
        state: MCPServerLifecycleState,
        configuration: MCPServerConfiguration,
        lastErrorMessage: String?,
        lastEventMessage: String?
    ) async {
        status = MCPServerStatus(
            state: state,
            listenAddress: configuration.listenAddress,
            port: configuration.port,
            endpointPath: MCPServerConfiguration.endpointPath,
            activeSessionCount: sessions.count,
            startedAt: state == .running ? (status.startedAt ?? .now) : nil,
            lastErrorMessage: lastErrorMessage,
            lastEventMessage: lastEventMessage
        )
        await publishStatus()
    }

    private func publishStatus() async {
        await statusHandler?(status)
    }

    private func emitLog(
        _ level: MCPLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) async {
        await logHandler?(MCPLogEntry(level: level, category: category, message: message, metadata: metadata))
    }

    private func nwPort(for value: Int) throws -> NWEndpoint.Port {
        guard (1 ... 65_535).contains(value), let port = NWEndpoint.Port(rawValue: UInt16(value)) else {
            throw MCPToolRegistryError.toolFailed("Port must be between 1 and 65535.")
        }
        return port
    }

    private func receive(on connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static var stackriotVersionString: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (shortVersion?.nonEmpty, buildNumber?.nonEmpty) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        case let (nil, build?):
            return build
        default:
            return "dev"
        }
    }
}
