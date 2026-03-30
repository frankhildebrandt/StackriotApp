import Foundation
import SwiftData

extension AppModel {
    func presentPullRequestCheckoutSheet(for repository: ManagedRepository) {
        pullRequestCheckoutDraft = PullRequestCheckoutDraft(repositoryID: repository.id)
        isPullRequestCheckoutSheetPresented = true
    }

    func dismissPullRequestCheckoutSheet() {
        pullRequestCheckoutDraft = PullRequestCheckoutDraft()
        isPullRequestCheckoutSheetPresented = false
    }

    func searchPullRequests(for repository: ManagedRepository) async {
        let query = pullRequestCheckoutDraft.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            pullRequestCheckoutDraft.searchResults = []
            pullRequestCheckoutDraft.selectedPullRequest = nil
            pullRequestCheckoutDraft.isLoading = false
            return
        }

        pullRequestCheckoutDraft.isLoading = true
        defer { pullRequestCheckoutDraft.isLoading = false }

        do {
            let results = try await services.gitHubCLIService.searchPullRequests(query: query, in: repository)
            pullRequestCheckoutDraft.searchResults = results
            if let selected = pullRequestCheckoutDraft.selectedPullRequest,
               results.contains(where: { $0.number == selected.number })
            {
                pullRequestCheckoutDraft.selectedPullRequest = try await services.gitHubCLIService.loadPullRequest(
                    number: selected.number,
                    in: repository
                )
            }
        } catch {
            pullRequestCheckoutDraft.searchResults = []
            pendingErrorMessage = error.localizedDescription
        }
    }

    func selectPullRequest(_ result: PullRequestSearchResult, for repository: ManagedRepository) async {
        pullRequestCheckoutDraft.isLoading = true
        defer { pullRequestCheckoutDraft.isLoading = false }

        do {
            pullRequestCheckoutDraft.selectedPullRequest = try await services.gitHubCLIService.loadPullRequest(
                number: result.number,
                in: repository
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func checkoutSelectedPullRequest(for repository: ManagedRepository, in modelContext: ModelContext) async {
        guard let pr = pullRequestCheckoutDraft.selectedPullRequest else {
            pendingErrorMessage = "Select a pull request to check out."
            return
        }

        do {
            let info = try await services.worktreeManager.checkoutPullRequest(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                repositoryName: repository.displayName,
                prNumber: pr.number,
                title: pr.title,
                destinationRoot: pullRequestCheckoutDraft.destinationRootURL
            )
            let worktree = repository.worktrees.first(where: { $0.path == info.path.path }) ?? WorktreeRecord(
                branchName: info.branchName,
                path: info.path.path,
                repository: repository,
                prNumber: pr.number,
                prURL: pr.url,
                lifecycleStateRaw: pr.status == .merged ? WorktreeLifecycle.merged.rawValue : WorktreeLifecycle.active.rawValue
            )
            worktree.branchName = info.branchName
            worktree.prNumber = pr.number
            worktree.prURL = pr.url
            worktree.lifecycleState = pr.status == .merged ? .merged : .active
            worktree.primaryContext = WorktreePrimaryContext(
                kind: .pullRequest,
                canonicalURL: pr.url,
                title: pr.title,
                label: "PR",
                provider: .github,
                prNumber: pr.number,
                ticketID: nil,
                upstreamReference: pr.headRefName,
                upstreamSHA: pr.headRefOID
            )
            if repository.worktrees.contains(where: { $0.id == worktree.id }) == false {
                repository.worktrees.append(worktree)
                modelContext.insert(worktree)
            }
            repository.updatedAt = .now
            try modelContext.save()
            finishCreatedWorktree(worktree, in: repository)
            startPRMonitoring(for: worktree, repository: repository, in: modelContext)
            await refreshWorktreeStatuses(for: repository)
            notifyOperationSuccess(
                title: "Pull request checked out",
                subtitle: repository.displayName,
                body: "#\(pr.number) is ready in \(worktree.branchName).",
                userInfo: [
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "Pull request checkout failed",
                subtitle: repository.displayName,
                body: error.localizedDescription,
                userInfo: ["repositoryID": repository.id.uuidString]
            )
        }
    }

    func updateCheckedOutPullRequest(
        _ worktree: WorktreeRecord,
        repository: ManagedRepository,
        modelContext: ModelContext
    ) async {
        guard let prNumber = worktree.resolvedPrimaryContext?.prNumber ?? worktree.prNumber else {
            pendingErrorMessage = "This worktree is not linked to a pull request."
            return
        }

        do {
            try await services.worktreeManager.updateCheckedOutPullRequest(
                bareRepositoryPath: URL(fileURLWithPath: repository.bareRepositoryPath),
                worktreePath: URL(fileURLWithPath: worktree.path),
                localBranchName: worktree.branchName,
                prNumber: prNumber
            )
            let localHead = try await services.worktreeManager.currentRevision(
                worktreePath: URL(fileURLWithPath: worktree.path)
            )
            if var context = worktree.primaryContext ?? worktree.resolvedPrimaryContext {
                context = WorktreePrimaryContext(
                    kind: context.kind,
                    canonicalURL: context.canonicalURL,
                    title: context.title,
                    label: context.label,
                    provider: context.provider,
                    prNumber: context.prNumber,
                    ticketID: context.ticketID,
                    upstreamReference: context.upstreamReference,
                    upstreamSHA: localHead
                )
                worktree.primaryContext = context
            }
            save(modelContext)
            await refreshWorktreeStatuses(for: repository)
            notifyOperationSuccess(
                title: "Pull request updated",
                subtitle: repository.displayName,
                body: "\(worktree.branchName) now tracks the latest PR head.",
                userInfo: [
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
        } catch {
            pendingErrorMessage = error.localizedDescription
            notifyOperationFailure(
                title: "Pull request update failed",
                subtitle: repository.displayName,
                body: error.localizedDescription,
                userInfo: [
                    "repositoryID": repository.id.uuidString,
                    "worktreeID": worktree.id.uuidString,
                ]
            )
        }
    }

    func migrateWorktreePrimaryContextsIfNeeded(in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<WorktreeRecord>()
        guard let worktrees = try? modelContext.fetch(descriptor) else { return }
        var didChange = false
        for worktree in worktrees {
            if worktree.migratePrimaryContextFromLegacyFieldsIfNeeded() {
                didChange = true
            }
        }
        if didChange {
            save(modelContext)
        }
    }

    func refreshPullRequestUpstreamStatuses(for repository: ManagedRepository) async {
        let prWorktrees = repository.worktrees.filter { $0.resolvedPrimaryContext?.kind == .pullRequest || $0.prNumber != nil }
        guard !prWorktrees.isEmpty else {
            for worktree in repository.worktrees {
                pullRequestUpstreamStatuses.removeValue(forKey: worktree.id)
            }
            return
        }

        for worktree in prWorktrees {
            guard let prNumber = worktree.resolvedPrimaryContext?.prNumber ?? worktree.prNumber else { continue }
            let storedHead = worktree.resolvedPrimaryContext?.upstreamSHA
            do {
                let pr = try await services.gitHubCLIService.loadPullRequest(number: prNumber, in: repository)
                let localHead = try? await services.worktreeManager.currentRevision(
                    worktreePath: URL(fileURLWithPath: worktree.path)
                )
                pullRequestUpstreamStatuses[worktree.id] = PullRequestUpstreamStatus(
                    state: pr.status,
                    remoteHeadSHA: pr.headRefOID,
                    localHeadSHA: localHead,
                    storedHeadSHA: storedHead,
                    errorMessage: nil
                )
            } catch {
                pullRequestUpstreamStatuses[worktree.id] = PullRequestUpstreamStatus(
                    state: .open,
                    remoteHeadSHA: storedHead ?? "",
                    localHeadSHA: nil,
                    storedHeadSHA: storedHead,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }
}
