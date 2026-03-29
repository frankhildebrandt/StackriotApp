import Foundation
import SwiftData

@Model
final class RepositoryProject {
    var id: UUID
    var name: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var namespace: RepositoryNamespace?
    @Relationship(deleteRule: .nullify, inverse: \ManagedRepository.project)
    var repositories: [ManagedRepository]

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        namespace: RepositoryNamespace? = nil
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.namespace = namespace
        self.repositories = []
    }
}
