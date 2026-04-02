import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case repositories
    case shortcuts
    case terminal
    case devContainers
    case node
    case aiProvider
    case browserSessions
    case jira
    case mcp
    case sshKeys
    case about

    static let defaultCategory: Self = .repositories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .repositories:
            "Repositories"
        case .shortcuts:
            "Shortcuts"
        case .terminal:
            "Terminal"
        case .devContainers:
            "Devcontainers"
        case .node:
            "Node"
        case .aiProvider:
            "AI & Providers"
        case .browserSessions:
            "Browser Sessions"
        case .jira:
            "Jira Cloud"
        case .mcp:
            "MCP Server"
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
        case .shortcuts:
            "keyboard"
        case .terminal:
            "terminal"
        case .devContainers:
            "shippingbox.fill"
        case .node:
            "cpu"
        case .aiProvider:
            "sparkles"
        case .browserSessions:
            "globe"
        case .jira:
            "link.badge.plus"
        case .mcp:
            "server.rack"
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
        case .shortcuts:
            "Global quick-intent shortcut, recorder, and accessibility hints."
        case .terminal:
            "How finished terminal tabs are kept and presented."
        case .devContainers:
            "CLI detection, container monitoring, and global devcontainer visibility."
        case .node:
            "Managed runtime defaults, status, and maintenance actions."
        case .aiProvider:
            "Provider selection, authentication, and effective model settings."
        case .browserSessions:
            "Persistent embedded-browser sessions for GitHub and Jira contexts."
        case .jira:
            "Cloud URL, Atlassian account, and API token used for ticket-backed worktrees."
        case .mcp:
            "Local MCP endpoint, diagnostics, and copy-paste client configuration."
        case .sshKeys:
            "Import, generate, and manage SSH keys used across remotes."
        case .about:
            "Version details, app scope, and platform assumptions."
        }
    }
}
