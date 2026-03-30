import Foundation

struct MCPToolRegistry: Sendable {
    typealias RepositoriesHandler = @Sendable () async throws -> MCPRepositoryListPayload
    typealias WorktreesHandler = @Sendable (UUID) async throws -> MCPWorktreeListPayload
    typealias WorktreeContextHandler = @Sendable (UUID) async throws -> MCPWorktreeContextPayload
    typealias RunsHandler = @Sendable (UUID, Int) async throws -> MCPRunListPayload
    typealias PlanHandler = @Sendable (UUID) async throws -> MCPPlanPayload

    let listRepositoriesHandler: RepositoriesHandler
    let listWorktreesHandler: WorktreesHandler
    let getWorktreeContextHandler: WorktreeContextHandler
    let listRunsHandler: RunsHandler
    let openPlanHandler: PlanHandler

    var tools: [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "list_repositories",
                description: "List Stackriot repositories with namespace, project, default branch, and status metadata.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false),
                ])
            ),
            MCPToolDefinition(
                name: "list_worktrees",
                description: "List worktrees for a repository, including branch, path, lifecycle state, and primary context.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "repositoryId": .object([
                            "type": .string("string"),
                            "description": .string("UUID of the Stackriot repository."),
                        ]),
                    ]),
                    "required": .array([.string("repositoryId")]),
                    "additionalProperties": .bool(false),
                ])
            ),
            MCPToolDefinition(
                name: "get_worktree_context",
                description: "Load the assigned agent, primary context, plan text, and latest runs for a worktree.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "worktreeId": .object([
                            "type": .string("string"),
                            "description": .string("UUID of the Stackriot worktree."),
                        ]),
                    ]),
                    "required": .array([.string("worktreeId")]),
                    "additionalProperties": .bool(false),
                ])
            ),
            MCPToolDefinition(
                name: "list_runs",
                description: "List recent runs for a worktree, including exit code, command line, and AI summaries.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "worktreeId": .object([
                            "type": .string("string"),
                            "description": .string("UUID of the Stackriot worktree."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of runs to return. Defaults to 10."),
                            "minimum": .number(1),
                            "maximum": .number(50),
                        ]),
                    ]),
                    "required": .array([.string("worktreeId")]),
                    "additionalProperties": .bool(false),
                ])
            ),
            MCPToolDefinition(
                name: "open_plan",
                description: "Return the current plan markdown for a worktree.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "worktreeId": .object([
                            "type": .string("string"),
                            "description": .string("UUID of the Stackriot worktree."),
                        ]),
                    ]),
                    "required": .array([.string("worktreeId")]),
                    "additionalProperties": .bool(false),
                ])
            ),
        ]
    }

    func listTools(cursor: String?) throws -> [MCPToolDefinition] {
        guard cursor?.nonEmpty == nil else {
            throw MCPToolRegistryError.invalidParams("Cursor pagination is not supported for this tool list.")
        }
        return tools
    }

    func callTool(named name: String, arguments: [String: JSONValue]) async throws -> MCPToolCallResult {
        do {
            switch name {
            case "list_repositories":
                guard arguments.isEmpty else {
                    throw MCPToolRegistryError.invalidParams("list_repositories does not accept arguments.")
                }
                let payload = try await listRepositoriesHandler()
                return try successResult(payload)
            case "list_worktrees":
                let repositoryID = try requiredUUID(named: "repositoryId", in: arguments)
                let payload = try await listWorktreesHandler(repositoryID)
                return try successResult(payload)
            case "get_worktree_context":
                let worktreeID = try requiredUUID(named: "worktreeId", in: arguments)
                let payload = try await getWorktreeContextHandler(worktreeID)
                return try successResult(payload)
            case "list_runs":
                let worktreeID = try requiredUUID(named: "worktreeId", in: arguments)
                let limit = try optionalInt(named: "limit", in: arguments) ?? 10
                guard (1 ... 50).contains(limit) else {
                    throw MCPToolRegistryError.invalidParams("limit must be between 1 and 50.")
                }
                let payload = try await listRunsHandler(worktreeID, limit)
                return try successResult(payload)
            case "open_plan":
                let worktreeID = try requiredUUID(named: "worktreeId", in: arguments)
                let payload = try await openPlanHandler(worktreeID)
                return try successResult(payload)
            default:
                throw MCPToolRegistryError.unknownTool(name)
            }
        } catch let error as MCPToolRegistryError {
            switch error {
            case .invalidParams, .unknownTool:
                throw error
            case let .toolFailed(message):
                return failureResult(message)
            }
        } catch {
            return failureResult(error.localizedDescription)
        }
    }

    private func successResult<T: Encodable>(_ payload: T) throws -> MCPToolCallResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let text = String(decoding: data, as: UTF8.self)
        return MCPToolCallResult(content: [MCPToolContent(type: "text", text: text)], isError: false)
    }

    private func failureResult(_ message: String) -> MCPToolCallResult {
        MCPToolCallResult(content: [MCPToolContent(type: "text", text: message)], isError: true)
    }

    private func requiredUUID(named name: String, in arguments: [String: JSONValue]) throws -> UUID {
        guard let rawValue = arguments[name]?.stringValue?.nonEmpty else {
            throw MCPToolRegistryError.invalidParams("Missing required string argument: \(name).")
        }
        guard let uuid = UUID(uuidString: rawValue) else {
            throw MCPToolRegistryError.invalidParams("Argument \(name) must be a valid UUID.")
        }
        return uuid
    }

    private func optionalInt(named name: String, in arguments: [String: JSONValue]) throws -> Int? {
        guard let value = arguments[name] else { return nil }
        guard let int = value.intValue else {
            throw MCPToolRegistryError.invalidParams("Argument \(name) must be an integer.")
        }
        return int
    }
}
