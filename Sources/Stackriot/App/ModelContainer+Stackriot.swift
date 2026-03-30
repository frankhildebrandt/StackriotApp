import SwiftData

enum StackriotModelContainer {
    static let persistentModelTypes: [any PersistentModel.Type] = [
        RepositoryNamespace.self,
        RepositoryProject.self,
        ManagedRepository.self,
        RepositoryRemote.self,
        StoredSSHKey.self,
        WorktreeRecord.self,
        ActionTemplateRecord.self,
        RunRecord.self,
        AgentRawLogRecord.self,
    ]
}
