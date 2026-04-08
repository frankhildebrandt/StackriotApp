import Foundation

enum ProjectDocumentationArchiveArtifact: String, Codable, Sendable, Equatable {
    case intent
    case implementationPlan

    var destinationFileName: String {
        switch self {
        case .intent:
            "intent.md"
        case .implementationPlan:
            "implementation-plan.md"
        }
    }
}

struct ProjectDocumentationArchiveFileRecord: Codable, Sendable, Equatable {
    let artifact: ProjectDocumentationArchiveArtifact
    let sourcePath: String
    let archivedRelativePath: String
    let exists: Bool
}

struct ProjectDocumentationArchiveMetadata: Codable, Sendable, Equatable {
    let archivedAt: Date
    let branchName: String
    let branchDirectoryName: String
    let targetBranchName: String?
    let repositoryID: UUID
    let repositoryDisplayName: String
    let repositoryRemoteURL: String?
    let projectID: UUID
    let projectName: String
    let worktreeID: UUID
    let pullRequestNumber: Int?
    let pullRequestURL: String?
    let files: [ProjectDocumentationArchiveFileRecord]
}

struct ProjectDocumentationArchiveResult: Sendable, Equatable {
    let destinationDirectory: URL
    let metadataURL: URL
    let archivedFiles: [ProjectDocumentationArchiveFileRecord]
}

struct ProjectDocumentationArchiveService {
    var currentDate: @Sendable () -> Date = { .now }
    var fileManagerProvider: @Sendable () -> FileManager = { .default }

    func archiveWorktreeArtifacts(
        documentationWorktreeURL: URL,
        worktree: WorktreeRecord,
        repository: ManagedRepository,
        project: RepositoryProject,
        targetBranchName: String?
    ) throws -> ProjectDocumentationArchiveResult {
        let fileManager = fileManagerProvider()
        let branchDirectoryName = archiveDirectoryName(for: worktree.branchName)
        let destinationDirectory = documentationWorktreeURL
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(branchDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let sourceFiles: [(ProjectDocumentationArchiveArtifact, URL)] = [
            (.intent, AppPaths.intentFile(for: worktree.id)),
            (.implementationPlan, AppPaths.implementationPlanFile(for: worktree.id)),
        ]

        let archivedFiles = try sourceFiles.map { artifact, sourceURL in
            let destinationURL = destinationDirectory.appendingPathComponent(artifact.destinationFileName, isDirectory: false)
            let relativePath = "archive/worktrees/\(branchDirectoryName)/\(artifact.destinationFileName)"
            let exists = fileManager.fileExists(atPath: sourceURL.path)
            if exists {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }

            return ProjectDocumentationArchiveFileRecord(
                artifact: artifact,
                sourcePath: sourceURL.path,
                archivedRelativePath: relativePath,
                exists: exists
            )
        }

        let metadata = ProjectDocumentationArchiveMetadata(
            archivedAt: currentDate(),
            branchName: worktree.branchName,
            branchDirectoryName: branchDirectoryName,
            targetBranchName: targetBranchName?.nilIfBlank,
            repositoryID: repository.id,
            repositoryDisplayName: repository.displayName,
            repositoryRemoteURL: repository.defaultRemote?.url ?? repository.remoteURL,
            projectID: project.id,
            projectName: project.name,
            worktreeID: worktree.id,
            pullRequestNumber: worktree.prNumber,
            pullRequestURL: worktree.prURL?.nilIfBlank,
            files: archivedFiles
        )

        let metadataURL = destinationDirectory.appendingPathComponent("metadata.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)

        return ProjectDocumentationArchiveResult(
            destinationDirectory: destinationDirectory,
            metadataURL: metadataURL,
            archivedFiles: archivedFiles
        )
    }

    func archiveDirectoryRelativePath(for branchName: String) -> String {
        "archive/worktrees/\(archiveDirectoryName(for: branchName))"
    }

    func archiveDirectoryName(for branchName: String) -> String {
        AppPaths.sanitizedPathComponent(branchName.replacingOccurrences(of: "/", with: "--"))
    }
}
