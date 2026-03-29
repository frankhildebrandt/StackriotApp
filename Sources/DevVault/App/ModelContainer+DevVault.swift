import SwiftData

enum DevVaultModelContainer {
    static let persistentModelTypes: [any PersistentModel.Type] = [
        ManagedRepository.self,
        RepositoryRemote.self,
        StoredSSHKey.self,
        WorktreeRecord.self,
        ActionTemplateRecord.self,
        RunRecord.self,
    ]
}
