import Foundation

struct AgentRunSegment: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case agentMessage
        case reasoning
        case commandExecution
        case toolCall
        case fileChange
        case todoList
        case error
        case fallbackText
    }

    enum Status: String, Sendable {
        case pending
        case running
        case completed
        case failed
        case cancelled
        case unknown

        init(rawValue: String?, eventType: String) {
            if let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                switch normalized {
                case "pending":
                    self = .pending
                    return
                case "in_progress", "running", "started", "start":
                    self = .running
                    return
                case "completed", "complete", "succeeded", "success", "done", "finished":
                    self = .completed
                    return
                case "failed", "error", "errored":
                    self = .failed
                    return
                case "cancelled", "canceled":
                    self = .cancelled
                    return
                default:
                    break
                }
            }

            let normalizedEvent = eventType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalizedEvent {
            case let value where value.contains("start"):
                self = .running
            case let value where value.contains("complete") || value.contains("finish") || value.contains("result") || value.contains("success") || value.contains("stop"):
                self = .completed
            case let value where value.contains("fail") || value.contains("error"):
                self = .failed
            case let value where value.contains("cancel"):
                self = .cancelled
            default:
                self = .unknown
            }
        }

        var displayText: String {
            switch self {
            case .pending:
                "Pending"
            case .running:
                "Running"
            case .completed:
                "Completed"
            case .failed:
                "Failed"
            case .cancelled:
                "Cancelled"
            case .unknown:
                "Unknown"
            }
        }
    }

    struct ChangedFile: Equatable, Sendable {
        enum Kind: String, Sendable {
            case added
            case deleted
            case updated
            case renamed
            case copied
            case unknown

            init(rawValue: String?) {
                switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "add", "added", "create", "created", "new":
                    self = .added
                case "delete", "deleted", "remove", "removed":
                    self = .deleted
                case "rename", "renamed":
                    self = .renamed
                case "copy", "copied":
                    self = .copied
                case "update", "updated", "modify", "modified", "edit", "edited":
                    self = .updated
                default:
                    self = .unknown
                }
            }

            var displayText: String {
                switch self {
                case .added:
                    "Added"
                case .deleted:
                    "Deleted"
                case .updated:
                    "Updated"
                case .renamed:
                    "Renamed"
                case .copied:
                    "Copied"
                case .unknown:
                    "Changed"
                }
            }
        }

        let path: String
        let kind: Kind
    }

    struct TodoItem: Equatable, Sendable {
        let text: String
        let isCompleted: Bool
    }

    let id: String
    let sourceAgent: AIAgentTool
    var revision: Int
    var kind: Kind
    var title: String
    var subtitle: String?
    var bodyText: String?
    var status: Status?
    var exitCode: Int?
    var detailText: String?
    var aggregatedOutput: String?
    var fileChanges: [ChangedFile]
    var todoItems: [TodoItem]
    var groupID: String?

    init(
        id: String,
        sourceAgent: AIAgentTool,
        revision: Int = 1,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        bodyText: String? = nil,
        status: Status? = nil,
        exitCode: Int? = nil,
        detailText: String? = nil,
        aggregatedOutput: String? = nil,
        fileChanges: [ChangedFile] = [],
        todoItems: [TodoItem] = [],
        groupID: String? = nil
    ) {
        self.id = id
        self.sourceAgent = sourceAgent
        self.revision = revision
        self.kind = kind
        self.title = title
        self.subtitle = subtitle?.nonEmpty
        self.bodyText = bodyText?.nonEmpty
        self.status = status
        self.exitCode = exitCode
        self.detailText = detailText?.nonEmpty
        self.aggregatedOutput = aggregatedOutput?.nonEmpty
        self.fileChanges = fileChanges
        self.todoItems = todoItems
        self.groupID = groupID?.nonEmpty
    }
}
