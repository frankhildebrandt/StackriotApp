import Foundation
import SwiftData

@Model
final class RepositoryNamespace {
    var id: UUID
    var name: String
    var isDefault: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \RepositoryProject.namespace)
    var projects: [RepositoryProject]
    @Relationship(deleteRule: .nullify, inverse: \ManagedRepository.namespace)
    var repositories: [ManagedRepository]

    init(
        id: UUID = UUID(),
        name: String,
        isDefault: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projects = []
        self.repositories = []
    }
}
