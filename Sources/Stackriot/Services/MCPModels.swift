import Foundation

enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .number(Double(int))
        } else if let double = try? container.decode(Double.self) {
            self = .number(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            if value.rounded() == value {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case let .number(value) = self, value.rounded() == value {
            return Int(value)
        }
        return nil
    }

    static func fromEncodable<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        let data = try encoder.encode(EncodableBox(value))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private struct EncodableBox<T: Encodable>: Encodable {
        let value: T

        init(_ value: T) {
            self.value = value
        }

        func encode(to encoder: any Encoder) throws {
            try value.encode(to: encoder)
        }
    }
}

struct MCPToolDefinition: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

struct MCPToolContent: Codable, Sendable, Equatable {
    let type: String
    let text: String
}

struct MCPToolCallResult: Codable, Sendable, Equatable {
    let content: [MCPToolContent]
    let isError: Bool
}

struct MCPRepositorySummary: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    let namespaceName: String?
    let projectName: String?
    let defaultBranch: String
    let defaultRemoteName: String?
    let remoteURL: String?
    let bareRepositoryPath: String
    let status: String
    let lastFetchedAt: Date?
    let updatedAt: Date
    let worktreeCount: Int
}

struct MCPRepositoryListPayload: Codable, Sendable, Equatable {
    let repositories: [MCPRepositorySummary]
}

struct MCPPrimaryContextSummary: Codable, Sendable, Equatable {
    let kind: String
    let provider: String
    let canonicalURL: String
    let title: String
    let label: String
    let prNumber: Int?
    let ticketID: String?
    let upstreamReference: String?
    let upstreamSHA: String?
}

struct MCPWorktreeSummary: Codable, Sendable, Equatable {
    let id: String
    let repositoryID: String
    let repositoryName: String
    let branchName: String
    let path: String
    let issueContext: String?
    let isDefaultBranchWorkspace: Bool
    let isPinned: Bool
    let lifecycleState: String
    let assignedAgent: String
    let ticketProvider: String?
    let ticketIdentifier: String?
    let ticketURL: String?
    let prNumber: Int?
    let prURL: String?
    let createdAt: Date
    let lastOpenedAt: Date?
    let primaryContext: MCPPrimaryContextSummary?
}

struct MCPWorktreeListPayload: Codable, Sendable, Equatable {
    let repositoryID: String
    let worktrees: [MCPWorktreeSummary]
}

struct MCPRunSummary: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let actionKind: String
    let status: String
    let commandLine: String
    let startedAt: Date
    let endedAt: Date?
    let exitCode: Int?
    let summaryTitle: String?
    let summaryText: String?
}

struct MCPRunListPayload: Codable, Sendable, Equatable {
    let worktreeID: String
    let runs: [MCPRunSummary]
}

struct MCPPlanPayload: Codable, Sendable, Equatable {
    let worktreeID: String
    let branchName: String
    let path: String
    /// Agent-produced implementation plan markdown (executable plan).
    let planText: String
    /// Editable intent / draft description (prompt foundation).
    let intentText: String
    let lastModifiedAt: Date?
}

struct MCPWorktreeContextPayload: Codable, Sendable, Equatable {
    let worktree: MCPWorktreeSummary
    let intentText: String
    let planText: String
    let latestRuns: [MCPRunSummary]
}

enum MCPToolRegistryError: LocalizedError, Sendable, Equatable {
    case invalidParams(String)
    case unknownTool(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidParams(message), let .toolFailed(message):
            message
        case let .unknownTool(name):
            "Unknown tool: \(name)"
        }
    }
}
