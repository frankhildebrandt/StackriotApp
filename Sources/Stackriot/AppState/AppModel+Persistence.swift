import Foundation
import SwiftData

extension AppModel {
    func save(_ modelContext: ModelContext) {
        do {
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func runRecord(with id: UUID) -> RunRecord? {
        if let draftRun = codexPlanDraftsByWorktreeID.values.first(where: { $0.run.id == id })?.run {
            return draftRun
        }

        guard let modelContext = storedModelContext else { return nil }
        let descriptor = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    func remoteExecutionContext(for remote: RepositoryRemote) -> RemoteExecutionContext {
        RemoteExecutionContext(
            name: remote.name,
            url: remote.url,
            fetchEnabled: remote.fetchEnabled,
            privateKeyRef: remote.sshKey?.privateKeyRef
        )
    }

    func resolvedDefaultRemote(for repository: ManagedRepository) -> RepositoryRemote? {
        if let configured = repository.defaultRemote {
            return configured
        }

        return repository.remotes.sorted {
            if $0.name == "origin" { return true }
            if $1.name == "origin" { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.first
    }

    func ensureDefaultRemoteSelection(for repository: ManagedRepository) {
        let nextName = resolvedDefaultRemote(for: repository)?.name
        if repository.defaultRemoteName != nextName {
            repository.defaultRemoteName = nextName
            repository.updatedAt = .now
        }
    }

    func canonicalRemoteURL(from url: String) throws -> String {
        guard let canonicalURL = RepositoryManager.canonicalRemoteURL(from: url) else {
            throw StackriotError.invalidRemoteURL
        }
        return canonicalURL
    }

    func ensureRemoteURLIsUnique(_ canonicalURL: String, excluding remoteID: UUID?, modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<RepositoryRemote>(predicate: #Predicate { $0.canonicalURL == canonicalURL })
        let remotes = try modelContext.fetch(descriptor)
        if remotes.contains(where: { $0.id != remoteID }) {
            throw StackriotError.duplicateRepository(canonicalURL)
        }
    }

    func repository(withCanonicalRemoteURL canonicalURL: String, in modelContext: ModelContext) -> ManagedRepository? {
        let descriptor = FetchDescriptor<RepositoryRemote>(predicate: #Predicate { $0.canonicalURL == canonicalURL })
        return try? modelContext.fetch(descriptor).first?.repository
    }

    func storeSSHKey(_ material: SSHKeyMaterial, in modelContext: ModelContext) throws {
        let reference = UUID().uuidString
        try KeychainSSHKeyStore.store(privateKeyData: material.privateKeyData, reference: reference)
        let key = StoredSSHKey(
            displayName: material.displayName,
            kind: material.kind,
            publicKey: material.publicKey,
            privateKeyRef: reference
        )
        modelContext.insert(key)
        save(modelContext)
    }
}
