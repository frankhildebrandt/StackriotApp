import Foundation

struct CodexRunSegment: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case agentMessage
        case reasoning
        case commandExecution
        case mcpToolCall
        case collabToolCall
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
                case "in_progress", "running", "started":
                    self = .running
                    return
                case "completed", "succeeded", "success":
                    self = .completed
                    return
                case "failed", "error":
                    self = .failed
                    return
                case "cancelled", "canceled":
                    self = .cancelled
                    return
                default:
                    break
                }
            }

            switch eventType {
            case "item.started":
                self = .running
            case "item.completed":
                self = .completed
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
                case "add", "added":
                    self = .added
                case "delete", "deleted":
                    self = .deleted
                case "rename", "renamed":
                    self = .renamed
                case "copy", "copied":
                    self = .copied
                case "update", "updated", "modify", "modified":
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
    var revision: Int
    var kind: Kind
    var title: String
    var subtitle: String?
    var bodyText: String?
    var status: Status?
    var exitCode: Int?
    var aggregatedOutput: String?
    var detailText: String?
    var fileChanges: [ChangedFile]
    var todoItems: [TodoItem]

    init(
        id: String,
        revision: Int = 1,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        bodyText: String? = nil,
        status: Status? = nil,
        exitCode: Int? = nil,
        aggregatedOutput: String? = nil,
        detailText: String? = nil,
        fileChanges: [ChangedFile] = [],
        todoItems: [TodoItem] = []
    ) {
        self.id = id
        self.revision = revision
        self.kind = kind
        self.title = title
        self.subtitle = subtitle?.nonEmpty
        self.bodyText = bodyText?.nonEmpty
        self.status = status
        self.exitCode = exitCode
        self.aggregatedOutput = aggregatedOutput?.nonEmpty
        self.detailText = detailText?.nonEmpty
        self.fileChanges = fileChanges
        self.todoItems = todoItems
    }
}
