import Foundation

struct ACPAgentRunService {
    func makeSession(
        runID: UUID,
        descriptor: ACPExecutionDescriptor,
        environment: [String: String],
        onOutput: @escaping ACPAgentRunSession.OutputHandler,
        onPermissionRequest: @escaping ACPAgentRunSession.PermissionHandler,
        onTermination: @escaping ACPAgentRunSession.TerminationHandler
    ) -> ACPAgentRunSession {
        ACPAgentRunSession(
            runID: runID,
            descriptor: descriptor,
            environment: environment,
            onOutput: onOutput,
            onPermissionRequest: onPermissionRequest,
            onTermination: onTermination
        )
    }
}

final class ACPAgentRunSession: @unchecked Sendable {
    typealias OutputHandler = @Sendable (String) -> Void
    typealias PermissionHandler = @MainActor @Sendable (ACPPermissionRequestState) -> Void
    typealias TerminationHandler = @Sendable (Int32, Bool) -> Void

    private let core: ACPAgentRunSessionCore

    init(
        runID: UUID,
        descriptor: ACPExecutionDescriptor,
        environment: [String: String],
        onOutput: @escaping OutputHandler,
        onPermissionRequest: @escaping PermissionHandler,
        onTermination: @escaping TerminationHandler
    ) {
        core = ACPAgentRunSessionCore(
            runID: runID,
            descriptor: descriptor,
            environment: environment,
            onOutput: onOutput,
            onPermissionRequest: onPermissionRequest,
            onTermination: onTermination
        )
    }

    func start() {
        Task {
            await core.start()
        }
    }

    func cancel() {
        Task {
            await core.cancel()
        }
    }

    func terminate() {
        Task {
            await core.terminate(forceCancelled: false)
        }
    }

    func respondToPermissionRequest(requestID: String, optionID: String) {
        Task {
            await core.respondToPermissionRequest(requestID: requestID, optionID: optionID)
        }
    }
}

private actor ACPAgentRunSessionCore {
    private enum JSONRPCID: Sendable {
        case int(Int)
        case string(String)

        var jsonValue: Any {
            switch self {
            case .int(let value):
                value
            case .string(let value):
                value
            }
        }

        var requestKey: String {
            switch self {
            case .int(let value):
                "i:\(value)"
            case .string(let value):
                "s:\(value)"
            }
        }

        init?(_ raw: Any?) {
            switch raw {
            case let value as Int:
                self = .int(value)
            case let value as NSNumber:
                self = .int(value.intValue)
            case let value as String:
                self = .string(value)
            default:
                return nil
            }
        }
    }

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<Data, Error>
    }

    private let runID: UUID
    private let descriptor: ACPExecutionDescriptor
    private let environment: [String: String]
    private let onOutput: ACPAgentRunSession.OutputHandler
    private let onPermissionRequest: ACPAgentRunSession.PermissionHandler
    private let onTermination: ACPAgentRunSession.TerminationHandler

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var bufferedData = Data()
    private var nextRequestID = 1
    private var pendingRequests: [String: PendingRequest] = [:]
    private var pendingPermissionIDs: Set<String> = []
    private var didFinish = false
    private var wasCancelled = false
    private var processTerminationStatus: Int32?
    private var sessionID: String?
    private var readLoopTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    init(
        runID: UUID,
        descriptor: ACPExecutionDescriptor,
        environment: [String: String],
        onOutput: @escaping ACPAgentRunSession.OutputHandler,
        onPermissionRequest: @escaping ACPAgentRunSession.PermissionHandler,
        onTermination: @escaping ACPAgentRunSession.TerminationHandler
    ) {
        self.runID = runID
        self.descriptor = descriptor
        self.environment = environment
        self.onOutput = onOutput
        self.onPermissionRequest = onPermissionRequest
        self.onTermination = onTermination
    }

    func start() async {
        do {
            try launchProcess()
            try await initializeSession()
            try await configureSession()
            try await prompt()
            emit(event: [
                "event": "prompt_finished",
                "tool": descriptor.tool.rawValue,
                "sessionId": sessionID ?? "",
                "stopReason": "completed",
            ])
            await terminate(forceCancelled: false)
        } catch {
            emit(
                event: [
                    "event": "error",
                    "tool": descriptor.tool.rawValue,
                    "sessionId": sessionID ?? "",
                    "message": error.localizedDescription,
                ]
            )
            await terminate(forceCancelled: wasCancelled, forcedExitCode: 1)
        }
    }

    func cancel() async {
        wasCancelled = true
        if let sessionID {
            _ = try? await sendNotification(
                method: "session/cancel",
                params: ["sessionId": sessionID]
            )
        }
        await terminate(forceCancelled: true)
    }

    func terminate(forceCancelled: Bool, forcedExitCode: Int32? = nil) async {
        guard !didFinish else { return }
        didFinish = true
        wasCancelled = wasCancelled || forceCancelled
        readLoopTask?.cancel()
        stderrTask?.cancel()
        pendingPermissionIDs.removeAll()
        failPendingRequests(message: "ACP session terminated.")
        if let process, process.isRunning {
            process.terminate()
        }
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        let exitCode = forcedExitCode ?? processTerminationStatus ?? 0
        onTermination(exitCode, wasCancelled)
    }

    func respondToPermissionRequest(requestID: String, optionID: String) async {
        guard pendingPermissionIDs.remove(requestID) != nil else { return }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID.hasPrefix("i:") ? Int(requestID.dropFirst(2)) ?? 0 : String(requestID.dropFirst(2)),
            "result": [
                "outcome": "selected",
                "optionId": optionID,
            ],
        ]
        try? writeMessage(response)
        emit(event: [
            "event": "permission_resolved",
            "tool": descriptor.tool.rawValue,
            "sessionId": sessionID ?? "",
            "requestId": requestID,
            "selectedOptionID": optionID,
            "selectedOptionName": optionID,
        ])
    }

    private func launchProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [descriptor.tool.acpExecutableName ?? descriptor.tool.executableName ?? ""]
            + (descriptor.tool.acpLaunchArguments ?? [])
        process.currentDirectoryURL = descriptor.workingDirectoryURL
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task {
                await self.recordTerminationStatus(proc.terminationStatus)
            }
        }

        try process.run()

        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading

        readLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.readLoop(handle: stdoutPipe.fileHandleForReading)
        }
        stderrTask = Task { [weak self] in
            guard let self else { return }
            await self.stderrLoop(handle: stderrPipe.fileHandleForReading)
        }
    }

    private func initializeSession() async throws {
        let initializeResponse = try await sendRequest(
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": [
                        "readTextFile": false,
                        "writeTextFile": false,
                    ],
                    "terminal": false,
                ],
                "clientInfo": [
                    "name": "Stackriot",
                    "version": "1.0.21",
                ],
            ]
        )

        _ = initializeResponse["result"] as? [String: Any]

        let sessionResponse: [String: Any]
        if let existingSessionID = descriptor.existingSessionID {
            sessionResponse = try await sendRequest(
                method: "session/load",
                params: [
                    "sessionId": existingSessionID,
                    "cwd": descriptor.workingDirectoryURL.path,
                    "mcpServers": [],
                ]
            )
            sessionID = existingSessionID
            emit(event: [
                "event": "session_started",
                "tool": descriptor.tool.rawValue,
                "sessionId": existingSessionID,
                "loadedExistingSession": true,
            ])
        } else {
            sessionResponse = try await sendRequest(
                method: "session/new",
                params: [
                    "cwd": descriptor.workingDirectoryURL.path,
                    "mcpServers": [],
                ]
            )
            let result = sessionResponse["result"] as? [String: Any]
            sessionID = StructuredAgentOutputParserSupport.firstString(in: result ?? [:], keys: ["sessionId"])
            emit(event: [
                "event": "session_started",
                "tool": descriptor.tool.rawValue,
                "sessionId": sessionID ?? "",
                "loadedExistingSession": false,
            ])
        }
    }

    private func configureSession() async throws {
        guard let sessionID else {
            throw StackriotError.commandFailed("ACP session did not return a session ID.")
        }

        if let modeID = descriptor.modeID {
            _ = try await sendRequest(
                method: "session/set_mode",
                params: [
                    "sessionId": sessionID,
                    "modeId": modeID,
                ]
            )
        }

        for (configID, value) in descriptor.configOverrides.sorted(by: { $0.key < $1.key }) {
            _ = try await sendRequest(
                method: "session/set_config_option",
                params: [
                    "sessionId": sessionID,
                    "configId": configID,
                    "value": value,
                ]
            )
        }
    }

    private func prompt() async throws {
        guard let sessionID else {
            throw StackriotError.commandFailed("ACP prompt attempted without a session.")
        }
        _ = try await sendRequest(
            method: "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": [
                    [
                        "type": "text",
                        "text": descriptor.prompt,
                    ]
                ],
            ]
        )
    }

    private func recordTerminationStatus(_ status: Int32) async {
        processTerminationStatus = status
        if !didFinish {
            await terminate(forceCancelled: wasCancelled, forcedExitCode: status)
        }
    }

    private func readLoop(handle: FileHandle) async {
        var iterator = handle.bytes.makeAsyncIterator()
        while !Task.isCancelled {
            do {
                guard let byte = try await iterator.next() else { break }
                bufferedData.append(byte)
                while let newlineRange = bufferedData.firstRange(of: Data([0x0A])) {
                    let lineData = bufferedData[..<newlineRange.lowerBound]
                    bufferedData.removeSubrange(..<newlineRange.upperBound)
                    guard !lineData.isEmpty else { continue }
                    if let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                        await handleIncomingMessage(object)
                    }
                }
            } catch {
                emit(
                    event: [
                        "event": "error",
                        "tool": descriptor.tool.rawValue,
                        "sessionId": sessionID ?? "",
                        "message": error.localizedDescription,
                    ]
                )
                break
            }
        }
    }

    private func stderrLoop(handle: FileHandle) async {
        var iterator = handle.bytes.makeAsyncIterator()
        var buffer = Data()
        while !Task.isCancelled {
            do {
                guard let byte = try await iterator.next() else { break }
                buffer.append(byte)
                if byte == 0x0A {
                    if let line = String(data: buffer, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nonEmpty
                    {
                        emit(
                            event: [
                                "event": "error",
                                "tool": descriptor.tool.rawValue,
                                "sessionId": sessionID ?? "",
                                "message": line,
                            ]
                        )
                    }
                    buffer.removeAll(keepingCapacity: true)
                }
            } catch {
                break
            }
        }
    }

    private func handleIncomingMessage(_ message: [String: Any]) async {
        if let id = JSONRPCID(message["id"]),
           let pending = pendingRequests.removeValue(forKey: id.requestKey)
        {
            if let error = message["error"] as? [String: Any] {
                pending.continuation.resume(throwing: StackriotError.commandFailed(
                    StructuredAgentOutputParserSupport.firstString(in: error, keys: ["message"]) ?? pending.method
                ))
            } else if let result = message["result"] as? [String: Any] {
                do {
                    let data = try JSONSerialization.data(withJSONObject: result)
                    pending.continuation.resume(returning: data)
                } catch {
                    pending.continuation.resume(throwing: error)
                }
            } else {
                pending.continuation.resume(returning: Data("{}".utf8))
            }
            return
        }

        guard let method = StructuredAgentOutputParserSupport.firstString(in: message, keys: ["method"]) else {
            return
        }

        switch method {
        case "session/update":
            if let params = message["params"] as? [String: Any] {
                emit(updateParams: params)
            }
        case "session/request_permission":
            guard
                let id = JSONRPCID(message["id"]),
                let params = message["params"] as? [String: Any]
            else {
                return
            }
            pendingPermissionIDs.insert(id.requestKey)
            await emitPermissionRequest(params: params, requestID: id.requestKey)
        default:
            break
        }
    }

    private func emit(updateParams params: [String: Any]) {
        let sessionID = StructuredAgentOutputParserSupport.firstString(in: params, keys: ["sessionId"]) ?? self.sessionID ?? ""
        let update = (params["update"] as? [String: Any]) ?? [:]
        let sessionUpdate = StructuredAgentOutputParserSupport.firstString(in: update, keys: ["sessionUpdate"]) ?? "update"
        let base: [String: Any] = [
            "tool": descriptor.tool.rawValue,
            "sessionId": sessionID,
        ]

        switch sessionUpdate {
        case "agent_message_chunk":
            let content = (update["content"] as? [String: Any]) ?? [:]
            emit(event: base.merging([
                "event": "agent_message_chunk",
                "text": StructuredAgentOutputParserSupport.firstString(in: content, keys: ["text"]) ?? "",
                "messageId": StructuredAgentOutputParserSupport.firstString(in: update, keys: ["messageId"]) ?? "\(sessionID)-assistant",
                "isDelta": true,
            ]) { _, new in new })
        case "thought_chunk":
            let content = (update["content"] as? [String: Any]) ?? [:]
            emit(event: base.merging([
                "event": "agent_thought_chunk",
                "text": StructuredAgentOutputParserSupport.firstString(in: content, keys: ["text"]) ?? "",
                "messageId": StructuredAgentOutputParserSupport.firstString(in: update, keys: ["messageId"]) ?? "\(sessionID)-reasoning",
                "isDelta": true,
            ]) { _, new in new })
        case "tool_call", "tool_call_update":
            emit(event: base.merging([
                "event": sessionUpdate == "tool_call" ? "tool_call" : "tool_call_update",
                "toolCallId": StructuredAgentOutputParserSupport.firstString(in: update, keys: ["toolCallId"]) ?? UUID().uuidString,
                "title": StructuredAgentOutputParserSupport.firstString(in: update, keys: ["title"]) ?? "Tool",
                "kind": StructuredAgentOutputParserSupport.firstString(in: update, keys: ["kind"]) as Any,
                "status": StructuredAgentOutputParserSupport.firstString(in: update, keys: ["status"]) as Any,
                "input": update["input"] as Any,
                "output": update["output"] as Any,
            ]) { _, new in new })
        case "plan":
            emit(event: base.merging([
                "event": "plan",
                "entries": update["entries"] as Any,
            ]) { _, new in new })
        default:
            break
        }
    }

    private func emitPermissionRequest(params: [String: Any], requestID: String) async {
        let sessionID = StructuredAgentOutputParserSupport.firstString(in: params, keys: ["sessionId"]) ?? self.sessionID ?? ""
        let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> ACPPermissionOption? in
            guard
                let optionID = StructuredAgentOutputParserSupport.firstString(in: option, keys: ["optionId"]),
                let name = StructuredAgentOutputParserSupport.firstString(in: option, keys: ["name"])
            else {
                return nil
            }
            let kind = ACPPermissionOptionKind(rawValue: StructuredAgentOutputParserSupport.firstString(in: option, keys: ["kind"]) ?? "")
            return ACPPermissionOption(optionID: optionID, name: name, kind: kind)
        }
        let title = StructuredAgentOutputParserSupport.firstString(in: params, keys: ["title"])
            ?? StructuredAgentOutputParserSupport.firstString(in: params, keys: ["toolTitle", "toolName"])
            ?? "Permission required"
        let message = StructuredAgentOutputParserSupport.firstString(in: params, keys: ["message", "reason"])

        emit(event: [
            "event": "permission_request",
            "tool": descriptor.tool.rawValue,
            "sessionId": sessionID,
            "requestId": requestID,
            "title": title,
            "message": message as Any,
            "options": options.map { ["optionId": $0.optionID, "name": $0.name, "kind": $0.kind.rawValue] },
        ])

        await onPermissionRequest(
            ACPPermissionRequestState(
                runID: runID,
                requestID: requestID,
                sessionID: sessionID,
                tool: descriptor.tool,
                title: title,
                message: message,
                options: options,
                createdAt: .now
            )
        )
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestID = JSONRPCID.int(nextRequestID)
        nextRequestID += 1

        let resultData = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID.requestKey] = PendingRequest(method: method, continuation: continuation)
            do {
                try writeMessage([
                    "jsonrpc": "2.0",
                    "id": requestID.jsonValue,
                    "method": method,
                    "params": params,
                ])
            } catch {
                pendingRequests.removeValue(forKey: requestID.requestKey)
                continuation.resume(throwing: error)
            }
        }

        guard let object = try JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        try writeMessage([
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ])
    }

    private func writeMessage(_ object: [String: Any]) throws {
        guard let stdinHandle else {
            throw StackriotError.commandFailed("ACP process stdin is unavailable.")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        stdinHandle.write(data)
        stdinHandle.write(Data("\n".utf8))
    }

    private func failPendingRequests(message: String) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for request in requests {
            request.continuation.resume(throwing: StackriotError.commandFailed(message))
        }
    }

    private func emit(event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else {
            return
        }
        onOutput(line + "\n")
    }
}
