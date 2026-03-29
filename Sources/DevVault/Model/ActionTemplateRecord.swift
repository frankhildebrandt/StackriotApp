import Foundation
import SwiftData

@Model
final class ActionTemplateRecord {
    var id: UUID
    var kindRawValue: String
    var title: String
    var payload: String?
    var createdAt: Date
    var repository: ManagedRepository?

    init(
        id: UUID = UUID(),
        kind: ActionKind,
        title: String,
        payload: String? = nil,
        createdAt: Date = .now,
        repository: ManagedRepository? = nil
    ) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.title = title
        self.payload = payload
        self.createdAt = createdAt
        self.repository = repository
    }

    var kind: ActionKind {
        get { ActionKind(rawValue: kindRawValue) ?? .openIDE }
        set { kindRawValue = newValue.rawValue }
    }
}

