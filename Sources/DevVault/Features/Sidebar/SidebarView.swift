import SwiftData
import SwiftUI

struct SidebarView: View {
    let repositories: [ManagedRepository]
    @Binding var selectedRepositoryID: UUID?
    let refreshingRepositoryIDs: Set<UUID>
    let isAgentRunningForRepository: (ManagedRepository) -> Bool
    let onAddRepository: () -> Void
    let onRefreshRepository: (ManagedRepository) -> Void
    let onRevealRepository: (ManagedRepository) -> Void
    let onManageRemotes: (ManagedRepository) -> Void
    let onDeleteRepository: (ManagedRepository) -> Void

    var body: some View {
        List(selection: $selectedRepositoryID) {
            Section("Repositories") {
                ForEach(repositories) { repository in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(repository.displayName)
                                .font(.headline)
                            if isAgentRunningForRepository(repository) {
                                AgentActivityDot()
                            }
                        }
                        Text(repository.primaryRemote?.url ?? repository.remoteURL ?? "No remote configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(repository.bareRepositoryPath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Label(repository.status.rawValue.capitalized, systemImage: statusSymbol(for: repository.status))
                                .font(.caption)
                                .foregroundStyle(repository.status == .ready ? .green : .orange)
                            if refreshingRepositoryIDs.contains(repository.id) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .tag(repository.id)
                    .contextMenu {
                        Button("Show in Finder") {
                            onRevealRepository(repository)
                        }
                        Button("Refresh") {
                            onRefreshRepository(repository)
                        }
                        Button("Manage Remotes") {
                            onManageRemotes(repository)
                        }
                        Button("Delete Repository", role: .destructive) {
                            onDeleteRepository(repository)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    onAddRepository()
                } label: {
                    Label("Clone Bare Repo", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .navigationTitle("DevVault")
    }

    private func statusSymbol(for status: RepositoryHealth) -> String {
        switch status {
        case .ready:
            "checkmark.circle.fill"
        case .missing:
            "exclamationmark.triangle.fill"
        case .broken:
            "xmark.octagon.fill"
        }
    }
}

