import Foundation
@testable import Stackriot
import Testing

struct MCPServerTests {
    @Test
    func toolRegistryListsExpectedToolNames() throws {
        let registry = makeRegistry()

        let names = try registry.listTools(cursor: nil).map(\.name)

        #expect(names == [
            "list_repositories",
            "list_worktrees",
            "get_worktree_context",
            "list_runs",
            "open_plan",
        ])
    }

    @Test
    func toolRegistryRendersPrettyJSONResults() async throws {
        let registry = makeRegistry()

        let result = try await registry.callTool(named: "list_repositories", arguments: [:])

        #expect(result.isError == false)
        #expect(result.content.count == 1)
        #expect(result.content[0].text.contains("\"repositories\""))
        #expect(result.content[0].text.contains("Demo"))
    }

    @Test
    func toolRegistryValidatesArguments() async {
        let registry = makeRegistry()

        await #expect(throws: MCPToolRegistryError.invalidParams("Argument repositoryId must be a valid UUID.")) {
            try await registry.callTool(named: "list_worktrees", arguments: [
                "repositoryId": .string("not-a-uuid"),
            ])
        }
    }

    @Test
    func mcpConfigurationBuildsEndpointURL() {
        let ipv4 = MCPServerConfiguration(
            enabled: true,
            listenAddress: "127.0.0.1",
            port: 8765,
            apiToken: nil,
            exposeReadOnlyToolsOnly: true
        )
        let ipv6 = MCPServerConfiguration(
            enabled: true,
            listenAddress: "::1",
            port: 8765,
            apiToken: nil,
            exposeReadOnlyToolsOnly: true
        )

        #expect(ipv4.endpointURLString == "http://127.0.0.1:8765/mcp")
        #expect(ipv6.endpointURLString == "http://[::1]:8765/mcp")
        #expect(ipv4.sseEndpointURLString == "http://127.0.0.1:8765/sse")
        #expect(ipv6.sseEndpointURLString == "http://[::1]:8765/sse")
    }

    @Test
    func serverHandlesInitializeAndToolCallsOverHTTP() async throws {
        let port = 38765
        let token = "test-token"
        let configuration = MCPServerConfiguration(
            enabled: true,
            listenAddress: "127.0.0.1",
            port: port,
            apiToken: token,
            exposeReadOnlyToolsOnly: true
        )
        let manager = MCPServerManager(configurationProvider: { configuration })
        let registry = makeRegistry()

        await manager.configure(toolRegistry: registry, statusHandler: nil, logHandler: nil)
        await manager.start()
        defer {
            Task {
                await manager.stop()
            }
        }

        try await waitUntilRunning(manager)

        let endpoint = URL(string: configuration.endpointURLString)!
        let initializeResponse = try await postJSON(
            to: endpoint,
            token: token,
            sessionID: nil,
            payload: """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"tests","version":"1.0"}}}
            """
        )

        #expect(initializeResponse.statusCode == 200)
        let sessionID = initializeResponse.headers["Mcp-Session-Id"]
        #expect(sessionID?.isEmpty == false)
        #expect(initializeResponse.body.contains("\"protocolVersion\":\"2025-03-26\""))

        let initializedResponse = try await postJSON(
            to: endpoint,
            token: token,
            sessionID: sessionID,
            payload: """
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            """
        )
        #expect(initializedResponse.statusCode == 202)

        let toolsResponse = try await postJSON(
            to: endpoint,
            token: token,
            sessionID: sessionID,
            payload: """
            {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
            """
        )
        #expect(toolsResponse.statusCode == 200)
        #expect(toolsResponse.body.contains("\"list_repositories\""))

        let callResponse = try await postJSON(
            to: endpoint,
            token: token,
            sessionID: sessionID,
            payload: """
            {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_repositories","arguments":{}}}
            """
        )
        #expect(callResponse.statusCode == 200)
        #expect(callResponse.body.contains("Demo"))
    }

    @Test
    func serverDeliversToolResponsesOverSSE() async throws {
        let port = 38766
        let token = "test-token"
        let configuration = MCPServerConfiguration(
            enabled: true,
            listenAddress: "127.0.0.1",
            port: port,
            apiToken: token,
            exposeReadOnlyToolsOnly: true
        )
        let manager = MCPServerManager(configurationProvider: { configuration })
        let registry = makeRegistry()

        await manager.configure(toolRegistry: registry, statusHandler: nil, logHandler: nil)
        await manager.start()
        defer {
            Task {
                await manager.stop()
            }
        }

        try await waitUntilRunning(manager)

        let endpoint = URL(string: configuration.endpointURLString)!
        let sseEndpoint = URL(string: configuration.sseEndpointURLString)!
        let initializeResponse = try await postJSON(
            to: endpoint,
            token: token,
            sessionID: nil,
            payload: """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"tests","version":"1.0"}}}
            """
        )

        let sessionID = try #require(initializeResponse.headers["Mcp-Session-Id"])

        let streamTask = Task { () throws -> (statusCode: Int, contentType: String?, payload: String) in
            var request = URLRequest(url: sseEndpoint)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpResponse = try #require(response as? HTTPURLResponse)
            for try await line in bytes.lines {
                if line.hasPrefix("data: ") {
                    return (
                        statusCode: httpResponse.statusCode,
                        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                        payload: String(line.dropFirst(6))
                    )
                }
            }

            struct MissingSSEPayload: Error {}
            throw MissingSSEPayload()
        }

        try await Task.sleep(for: .milliseconds(150))

        let toolsResponse = try await postJSON(
            to: endpoint,
            token: token,
            sessionID: sessionID,
            payload: """
            {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
            """
        )

        #expect(toolsResponse.statusCode == 202)
        #expect(toolsResponse.body.isEmpty)

        let streamResponse = try await streamTask.value
        #expect(streamResponse.statusCode == 200)
        #expect(streamResponse.contentType?.contains("text/event-stream") == true)
        #expect(streamResponse.payload.contains("\"list_repositories\""))
    }

    private func makeRegistry() -> MCPToolRegistry {
        MCPToolRegistry(
            listRepositoriesHandler: {
                MCPRepositoryListPayload(repositories: [
                    MCPRepositorySummary(
                        id: UUID().uuidString,
                        displayName: "Demo",
                        namespaceName: "Default",
                        projectName: nil,
                        defaultBranch: "main",
                        defaultRemoteName: "origin",
                        remoteURL: "https://github.com/example/demo.git",
                        bareRepositoryPath: "/tmp/demo.git",
                        status: "ready",
                        lastFetchedAt: nil,
                        updatedAt: .now,
                        worktreeCount: 1
                    )
                ])
            },
            listWorktreesHandler: { repositoryID in
                MCPWorktreeListPayload(
                    repositoryID: repositoryID.uuidString,
                    worktrees: []
                )
            },
            getWorktreeContextHandler: { worktreeID in
                MCPWorktreeContextPayload(
                    worktree: MCPWorktreeSummary(
                        id: worktreeID.uuidString,
                        repositoryID: UUID().uuidString,
                        repositoryName: "Demo",
                        branchName: "feature/demo",
                        path: "/tmp/demo",
                        issueContext: nil,
                        isDefaultBranchWorkspace: false,
                        isPinned: false,
                        lifecycleState: "active",
                        assignedAgent: "none",
                        ticketProvider: nil,
                        ticketIdentifier: nil,
                        ticketURL: nil,
                        prNumber: nil,
                        prURL: nil,
                        createdAt: .now,
                        lastOpenedAt: nil,
                        primaryContext: nil
                    ),
                    intentText: "# Intent",
                    planText: "# Plan",
                    latestRuns: []
                )
            },
            listRunsHandler: { worktreeID, _ in
                MCPRunListPayload(worktreeID: worktreeID.uuidString, runs: [])
            },
            openPlanHandler: { worktreeID in
                MCPPlanPayload(
                    worktreeID: worktreeID.uuidString,
                    branchName: "feature/demo",
                    path: "/tmp/demo",
                    planText: "# Plan",
                    intentText: "# Intent",
                    lastModifiedAt: .now
                )
            }
        )
    }

    private func waitUntilRunning(_ manager: MCPServerManager) async throws {
        for _ in 0 ..< 40 {
            let status = await manager.statusSnapshot()
            if status.isRunning {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("MCP server did not reach the running state in time.")
    }

    private func postJSON(
        to url: URL,
        token: String,
        sessionID: String?,
        payload: String
    ) async throws -> (statusCode: Int, headers: [String: String], body: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = Data(payload.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        let headers: [String: String] = Dictionary(uniqueKeysWithValues: httpResponse.allHeaderFields.compactMap { key, value in
            guard let key = key as? String, let value = value as? String else { return nil }
            return (key, value)
        })
        return (
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: String(decoding: data, as: UTF8.self)
        )
    }
}
