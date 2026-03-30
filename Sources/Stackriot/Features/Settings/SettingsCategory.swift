import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case repositories
    case terminal
    case node
    case aiProvider
    case browserSessions
    case jira
    case sshKeys
    case about

    static let defaultCategory: Self = .repositories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .repositories:
            "Repositories"
        case .terminal:
            "Terminal"
        case .node:
            "Node"
        case .aiProvider:
            "AI & Providers"
        case .browserSessions:
            "Browser Sessions"
        case .jira:
            "Jira Cloud"
        case .sshKeys:
            "SSH Keys"
        case .about:
            "About Stackriot"
        }
    }

    var symbolName: String {
        switch self {
        case .repositories:
            "shippingbox"
        case .terminal:
            "terminal"
        case .node:
            "cpu"
        case .aiProvider:
            "sparkles"
        case .browserSessions:
            "globe"
        case .jira:
            "link.badge.plus"
        case .sshKeys:
            "key"
        case .about:
            "info.circle"
        }
    }

    var shortDescription: String {
        switch self {
        case .repositories:
            "Refresh behavior and repository workflow defaults."
        case .terminal:
            "How finished terminal tabs are kept and presented."
        case .node:
            "Managed runtime defaults, status, and maintenance actions."
        case .aiProvider:
            "Provider selection, authentication, and effective model settings."
        case .browserSessions:
            "Persistent embedded-browser sessions for GitHub and Jira contexts."
        case .jira:
            "Cloud URL, Atlassian account, and API token used for ticket-backed worktrees."
        case .sshKeys:
            "Import, generate, and manage SSH keys used across remotes."
        case .about:
            "Version details, app scope, and platform assumptions."
        }
    }
}
