import Foundation
import SwiftData

extension AppModel {
    func saveRemote(
        name: String,
        url: String,
        fetchEnabled: Bool,
        isDefaultRemote: Bool,
        sshKey: StoredSSHKey?,
        for repository: ManagedRepository,
        editing remote: RepositoryRemote?,
        in modelContext: ModelContext
    ) async {
        do {
            let canonicalURL = try canonicalRemoteURL(from: url)
            try ensureRemoteURLIsUnique(canonicalURL, excluding: remote?.id, modelContext: modelContext)

            if let remote {
                let previousName = remote.name
                try await services.repositoryManager.updateRemote(
                    previousName: previousName,
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
                if repository.defaultRemoteName == previousName {
                    repository.defaultRemoteName = remote.name
                }
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

            if isDefaultRemote {
                repository.defaultRemoteName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                ensureDefaultRemoteSelection(for: repository)
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
            if repository.defaultRemoteName == remote.name {
                repository.defaultRemoteName = repository.remotes
                    .filter { $0.id != remote.id }
                    .sorted {
                        if $0.name == "origin" { return true }
                        if $1.name == "origin" { return false }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    .first?
                    .name
            }
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
                throw StackriotError.worktreeUnavailable
            }

            guard let remote = repository.remotes.first(where: { $0.name == publishDraft.remoteName }) else {
                throw StackriotError.remoteNameRequired
            }
            guard await materializeIdeaTreeIfNeeded(worktree, in: repository, modelContext: modelContext) != nil,
                  let worktreeURL = worktree.materializedURL
            else {
                return
            }

            let branch = try await services.repositoryManager.publishCurrentBranch(
                worktreePath: worktreeURL,
                remote: remoteExecutionContext(for: remote)
            )
            pendingErrorMessage = "Published \(branch) to \(remote.name)."
            dismissPublishSheet()
            _ = modelContext
            notifyOperationSuccess(
                title: "Branch published",
                subtitle: repository.displayName,
                body: "\(branch) was pushed to \(remote.name).",
                userInfo: [
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "Branch publish failed",
                subtitle: publishDraft.remoteName.nonEmpty,
                body: error.localizedDescription
            )
        }
    }
}
