import Foundation

struct CloneRepositoryDraft {
    var remoteURLString = ""
    var displayName = ""
}

struct WorktreeDraft {
    var branchName = ""
    var issueContext = ""
    var sourceBranch = ""

    init(sourceBranch: String = "") {
        self.sourceBranch = sourceBranch
    }
}

struct PublishBranchDraft {
    var repositoryID: UUID?
    var worktreeID: UUID?
    var remoteName = ""
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
