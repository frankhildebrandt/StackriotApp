import Foundation
import SwiftData

extension AppModel {
    func saveRemote(
        name: String,
        url: String,
        fetchEnabled: Bool,
        sshKey: StoredSSHKey?,
        for repository: ManagedRepository,
        editing remote: RepositoryRemote?,
        in modelContext: ModelContext
    ) async {
        do {
            let canonicalURL = try canonicalRemoteURL(from: url)
            try ensureRemoteURLIsUnique(canonicalURL, excluding: remote?.id, modelContext: modelContext)

            if let remote {
                try await services.repositoryManager.updateRemote(
                    previousName: remote.name,
                    newName: name,
                    url: url,
                    bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath)
                )
                remote.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                remote.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
                remote.canonicalURL = canonicalURL
                remote.fetchEnabled = fetchEnabled
                remote.sshKey = sshKey
                remote.updatedAt = .now
            } else {
                try await services.repositoryManager.addRemote(
                    name: name,
                    url: url,
                    bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath)
                )
                let newRemote = RepositoryRemote(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                    canonicalURL: canonicalURL,
                    fetchEnabled: fetchEnabled,
                    repository: repository,
                    sshKey: sshKey
                )
                repository.remotes.append(newRemote)
                modelContext.insert(newRemote)
            }

            repository.updatedAt = .now
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func removeRemote(_ remote: RepositoryRemote, from repository: ManagedRepository, in modelContext: ModelContext) async {
        do {
            try await services.repositoryManager.removeRemote(
                name: remote.name,
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath)
            )
            modelContext.delete(remote)
            repository.updatedAt = .now
            try modelContext.save()
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func importSSHKey(from sourceURL: URL, in modelContext: ModelContext) async {
        do {
            let material = try await services.sshKeyManager.importKey(from: sourceURL, displayName: nil)
            try storeSSHKey(material, in: modelContext)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func generateSSHKey(displayName: String, comment: String, in modelContext: ModelContext) async {
        do {
            let material = try await services.sshKeyManager.generateKey(displayName: displayName, comment: comment)
            try storeSSHKey(material, in: modelContext)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func removeSSHKey(_ key: StoredSSHKey, in modelContext: ModelContext) {
        for remote in key.remotes {
            remote.sshKey = nil
            remote.updatedAt = .now
        }
        KeychainSSHKeyStore.delete(reference: key.privateKeyRef)
        modelContext.delete(key)
        save(modelContext)
    }

    func publishSelectedBranch(in modelContext: ModelContext) async {
        do {
            guard
                let repositoryID = publishDraft.repositoryID,
                let worktreeID = publishDraft.worktreeID,
                let repository = repositoryRecord(with: repositoryID),
                let worktree = worktreeRecord(with: worktreeID)
            else {
                throw DevVaultError.worktreeUnavailable
            }

            guard let remote = repository.remotes.first(where: { $0.name == publishDraft.remoteName }) else {
                throw DevVaultError.remoteNameRequired
            }

            let branch = try await services.repositoryManager.publishCurrentBranch(
                worktreePath: URL(fileURLWithPath: worktree.path),
                remote: remoteExecutionContext(for: remote)
            )
            pendingErrorMessage = "Published \(branch) to \(remote.name)."
            dismissPublishSheet()
            _ = modelContext
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }
}
