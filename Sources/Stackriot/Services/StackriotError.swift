import Foundation

enum StackriotError: LocalizedError {
    case invalidRemoteURL
    case duplicateRepository(String)
    case unsupportedRepositoryPath
    case executableNotFound(String)
    case branchNameRequired
    case worktreeUnavailable
    case remoteNameRequired
    case noBranchToPublish
    case commandFailed(String)
    case keyMaterialInvalid
    case devToolUnavailable(String)
    case runConfigurationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidRemoteURL:
            "The repository URL is invalid."
        case let .duplicateRepository(url):
            "A repository for \(url) already exists."
        case .unsupportedRepositoryPath:
            "The repository path is missing or invalid."
        case let .executableNotFound(name):
            "\(name) is not installed or cannot be launched."
        case .branchNameRequired:
            "A branch name is required."
        case .worktreeUnavailable:
            "A worktree is required for this action."
        case .remoteNameRequired:
            "A remote name and URL are required."
        case .noBranchToPublish:
            "The selected worktree has no active branch to publish."
        case .keyMaterialInvalid:
            "The SSH key could not be read or generated."
        case let .devToolUnavailable(name):
            "\(name) is not installed or is not relevant for this repository."
        case let .runConfigurationUnavailable(name):
            "The run configuration \(name) cannot be executed directly here."
        case let .commandFailed(message):
            message
        }
    }
}
