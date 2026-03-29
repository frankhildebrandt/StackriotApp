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

enum NameEditorMode {
    case create
    case rename
}

struct NamespaceEditorDraft: Identifiable {
    var id = UUID()
    var mode: NameEditorMode = .create
    var namespaceID: UUID?
    var name = ""
}

struct ProjectEditorDraft: Identifiable {
    var id = UUID()
    var mode: NameEditorMode = .create
    var namespaceID: UUID?
    var projectID: UUID?
    var name = ""
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
