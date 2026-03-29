import Foundation
import SwiftData

@Model
final class StoredSSHKey {
    var id: UUID
    var displayName: String
    var kindRawValue: String
    var publicKey: String
    var privateKeyRef: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .nullify, inverse: \RepositoryRemote.sshKey)
    var remotes: [RepositoryRemote]

    init(
        id: UUID = UUID(),
        displayName: String,
        kind: SSHKeyKind,
        publicKey: String,
        privateKeyRef: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.kindRawValue = kind.rawValue
        self.publicKey = publicKey
        self.privateKeyRef = privateKeyRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.remotes = []
    }

    var kind: SSHKeyKind {
        get { SSHKeyKind(rawValue: kindRawValue) ?? .imported }
        set { kindRawValue = newValue.rawValue }
    }
}

