import Foundation
import SwiftData


@Model
final class RepositoryRemote {
    var id: UUID
    var name: String
    var url: String
    var canonicalURL: String
    var fetchEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var repository: ManagedRepository?
    var sshKey: StoredSSHKey?

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        canonicalURL: String,
        fetchEnabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        repository: ManagedRepository? = nil,
        sshKey: StoredSSHKey? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.canonicalURL = canonicalURL
        self.fetchEnabled = fetchEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.repository = repository
        self.sshKey = sshKey
    }
}

