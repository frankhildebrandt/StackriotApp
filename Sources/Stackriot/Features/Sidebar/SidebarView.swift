import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

private struct SidebarRepositoryLayout {
    let projectsInNamespace: [RepositoryProject]
    let repositoriesByProjectID: [UUID: [ManagedRepository]]
    let ungroupedRepositories: [ManagedRepository]

    init(
        currentNamespace: RepositoryNamespace?,
        projects: [RepositoryProject],
        repositories: [ManagedRepository]
    ) {
        guard let currentNamespace else {
            projectsInNamespace = []
            repositoriesByProjectID = [:]
            ungroupedRepositories = []
            return
        }

        let projectSort: (RepositoryProject, RepositoryProject) -> Bool = { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let repositorySort: (ManagedRepository, ManagedRepository) -> Bool = {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        projectsInNamespace = projects
            .filter { $0.namespace?.id == currentNamespace.id }
            .sorted(by: projectSort)

        let allowedProjectIDs = Set(projectsInNamespace.map(\.id))
        var groupedRepositories: [UUID: [ManagedRepository]] = [:]
        var rootRepositories: [ManagedRepository] = []
        groupedRepositories.reserveCapacity(projectsInNamespace.count)
        rootRepositories.reserveCapacity(repositories.count)

        for repository in repositories {
            if let projectID = repository.project?.id, allowedProjectIDs.contains(projectID) {
                groupedRepositories[projectID, default: []].append(repository)
            } else if repository.project == nil {
                rootRepositories.append(repository)
            }
        }

        repositoriesByProjectID = groupedRepositories.mapValues { $0.sorted(by: repositorySort) }
        ungroupedRepositories = rootRepositories.sorted(by: repositorySort)
    }
}

struct SidebarView: View {
    let namespaces: [RepositoryNamespace]
    let projects: [RepositoryProject]
    let currentNamespace: RepositoryNamespace?
    let repositories: [ManagedRepository]
    let sidebarSnapshotsByRepositoryID: [UUID: RepositorySidebarSnapshot]
    @Binding var selectedNamespaceID: UUID?
    @Binding var selectedRepositoryID: UUID?
    let onSelectNamespace: (RepositoryNamespace) -> Void
    let onCreateNamespace: () -> Void
    let onEditNamespace: (RepositoryNamespace) -> Void
    let onDeleteNamespace: (RepositoryNamespace) -> Void
    let onCreateProject: (RepositoryNamespace) -> Void
    let onEditProject: (RepositoryProject) -> Void
    let onMoveProject: (RepositoryProject, RepositoryNamespace) -> Void
    let onDeleteProject: (RepositoryProject) -> Void
    let onConfigureProjectDocumentation: (RepositoryProject) -> Void
    let onOpenProjectDocumentation: (RepositoryProject) -> Void
    let onRemoveProjectDocumentation: (RepositoryProject) -> Void
    let onAssignRepository: (ManagedRepository, RepositoryNamespace, RepositoryProject?) -> Void
    let onAddRepository: () -> Void
    let onRefreshRepository: (ManagedRepository) -> Void
    let onRevealRepository: (ManagedRepository) -> Void
    let availableDevTools: (ManagedRepository) -> [SupportedDevTool]
    let availableExternalTerminals: [SupportedExternalTerminal]
    let onOpenRepositoryInDevTool: (ManagedRepository, SupportedDevTool) -> Void
    let onOpenRepositoryInTerminal: (ManagedRepository, SupportedExternalTerminal) -> Void
    let onManageRemotes: (ManagedRepository) -> Void
    let onDeleteRepository: (ManagedRepository) -> Void

    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var showNamespacePicker = false

    var body: some View {
        let layout = SidebarRepositoryLayout(
            currentNamespace: currentNamespace,
            projects: projects,
            repositories: repositories
        )

        List(selection: $selectedRepositoryID) {
            if let currentNamespace {
                let namespaceProjects = layout.projectsInNamespace
                let rootRepositories = layout.ungroupedRepositories

                if !currentNamespace.isDefault {
                    Section {
                        ForEach(namespaceProjects) { project in
                            let isExpanded = expandedProjectIDs.contains(project.id)
                            ProjectHeaderRow(
                                project: project,
                                repositoryCount: layout.repositoriesByProjectID[project.id, default: []].count,
                                documentationConfigured: project.documentationRepository != nil,
                                isExpanded: isExpanded,
                                onToggle: {
                                    toggleProject(project)
                                }
                            )
                            .contextMenu {
                                projectContextMenu(project)
                            }
                            .dropDestination(for: SidebarDragItem.self) { items, _ in
                                handleProjectDrop(items, onto: project)
                            }
                            .draggable(SidebarDragItem(kind: .project, id: project.id))

                            if isExpanded {
                                ForEach(layout.repositoriesByProjectID[project.id, default: []]) { repository in
                                    RepositoryRow(
                                        repository: repository,
                                        isRefreshing: sidebarSnapshotsByRepositoryID[repository.id]?.isRefreshing == true,
                                        isAgentRunning: sidebarSnapshotsByRepositoryID[repository.id]?.isAgentRunning == true,
                                        activeDevContainerCount: AppPreferences.devContainerGlobalVisibilityEnabled
                                            ? (sidebarSnapshotsByRepositoryID[repository.id]?.activeDevContainerCount ?? 0)
                                            : 0
                                    )
                                    .padding(.leading, 18)
                                    .tag(repository.id)
                                    .draggable(SidebarDragItem(kind: .repository, id: repository.id))
                                    .contextMenu {
                                        repositoryContextMenu(repository)
                                    }
                                }
                            }
                        }
                    } header: {
                        SidebarSectionHeader(
                            title: "Projects",
                            systemImage: "folder"
                        )
                    }
                }

                Section {
                    ForEach(rootRepositories) { repository in
                        RepositoryRow(
                            repository: repository,
                            isRefreshing: sidebarSnapshotsByRepositoryID[repository.id]?.isRefreshing == true,
                            isAgentRunning: sidebarSnapshotsByRepositoryID[repository.id]?.isAgentRunning == true,
                            activeDevContainerCount: AppPreferences.devContainerGlobalVisibilityEnabled
                                ? (sidebarSnapshotsByRepositoryID[repository.id]?.activeDevContainerCount ?? 0)
                                : 0
                        )
                        .tag(repository.id)
                        .draggable(SidebarDragItem(kind: .repository, id: repository.id))
                        .contextMenu {
                            repositoryContextMenu(repository)
                        }
                    }
                } header: {
                    SidebarSectionHeader(
                        title: currentNamespace.isDefault ? "Repositories" : "Namespace Repositories",
                        systemImage: "shippingbox"
                    )
                    .dropDestination(for: SidebarDragItem.self) { items, _ in
                        handleNamespaceRootDrop(items, in: currentNamespace)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            header
        }
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .navigationTitle("Stackriot")
        .task(id: layout.projectsInNamespace.map(\.id)) {
            expandedProjectIDs.formUnion(layout.projectsInNamespace.map(\.id))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
/*            HStack {
                Text("Stackriot")
                    .font(.title3.weight(.semibold))
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)
*/
            Button {
                showNamespacePicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("NAMESPACE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(currentNamespace?.name ?? "—")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .popover(isPresented: $showNamespacePicker, arrowEdge: .bottom) {
                NamespacePickerPopover(
                    namespaces: namespaces,
                    selectedNamespaceID: selectedNamespaceID,
                    onSelect: { namespace in
                        onSelectNamespace(namespace)
                        showNamespacePicker = false
                    },
                    onRename: { namespace in
                        showNamespacePicker = false
                        onEditNamespace(namespace)
                    },
                    onDelete: { namespace in
                        showNamespacePicker = false
                        onDeleteNamespace(namespace)
                    },
                    onCreateNamespace: {
                        showNamespacePicker = false
                        onCreateNamespace()
                    }
                )
            }
        }
        .background(.ultraThinMaterial)
    }

    private var footer: some View {
        HStack {
            Button {
                onAddRepository()
            } label: {
                Label("Create Repository", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

            if let currentNamespace, !currentNamespace.isDefault {
                Button {
                    onCreateProject(currentNamespace)
                } label: {
                    Label("Add Project", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func repositoryContextMenu(_ repository: ManagedRepository) -> some View {
        let repositoryDevTools = availableDevTools(repository)
        if !repositoryDevTools.isEmpty || !availableExternalTerminals.isEmpty {
            Menu("Open In") {
                ForEach(repositoryDevTools) { tool in
                    Button("Open in \(tool.displayName)") {
                        onOpenRepositoryInDevTool(repository, tool)
                    }
                }
                if !repositoryDevTools.isEmpty && !availableExternalTerminals.isEmpty {
                    Divider()
                }
                ForEach(availableExternalTerminals) { terminal in
                    Button("Open in \(terminal.displayName)") {
                        onOpenRepositoryInTerminal(repository, terminal)
                    }
                }
            }

            Divider()
        }

        Button("Show in Finder") {
            onRevealRepository(repository)
        }
        Button("Refresh") {
            onRefreshRepository(repository)
        }
        Button("Manage Remotes") {
            onManageRemotes(repository)
        }

        Menu("Assign To") {
            ForEach(namespaces) { namespace in
                if namespace.isDefault {
                    Button(namespace.name) {
                        onAssignRepository(repository, namespace, nil)
                    }
                } else {
                    Menu(namespace.name) {
                        Button("No Project") {
                            onAssignRepository(repository, namespace, nil)
                        }
                        ForEach(projects.filter { $0.namespace?.id == namespace.id }.sorted(by: projectSort)) { project in
                            Button(project.name) {
                                onAssignRepository(repository, namespace, project)
                            }
                        }
                    }
                }
            }
        }

        if repository.project != nil, let currentNamespace = currentNamespace {
            Button("Remove From Project") {
                onAssignRepository(repository, currentNamespace, nil)
            }
        }

        Divider()

        Button("Delete Repository", role: .destructive) {
            onDeleteRepository(repository)
        }
    }

    @ViewBuilder
    private func projectContextMenu(_ project: RepositoryProject) -> some View {
        Button("Rename Project") {
            onEditProject(project)
        }

        Divider()

        Button(project.documentationRepository == nil ? "Dokumentationsquelle einrichten" : "Dokumentationsquelle verwalten") {
            onConfigureProjectDocumentation(project)
        }

        if project.documentationRepository != nil {
            Button("Dokumentations-Repository oeffnen") {
                onOpenProjectDocumentation(project)
            }

            Button("Dokumentationsquelle entfernen", role: .destructive) {
                onRemoveProjectDocumentation(project)
            }
        }

        Menu("Move To Namespace") {
            ForEach(namespaces.filter { !$0.isDefault }) { namespace in
                Button(namespace.name) {
                    onMoveProject(project, namespace)
                }
            }
        }

        Button("Delete Project", role: .destructive) {
            onDeleteProject(project)
        }
    }

    private func handleNamespaceRootDrop(_ items: [SidebarDragItem], in namespace: RepositoryNamespace) -> Bool {
        var handled = false

        for item in items where item.kind == .repository {
            guard let repository = repositories.first(where: { $0.id == item.id }) ?? currentRepository(with: item.id) else {
                continue
            }
            onAssignRepository(repository, namespace, nil)
            handled = true
        }

        return handled
    }

    private func handleProjectDrop(_ items: [SidebarDragItem], onto project: RepositoryProject) -> Bool {
        var handled = false

        for item in items where item.kind == .repository {
            guard
                let namespace = project.namespace,
                let repository = repositories.first(where: { $0.id == item.id }) ?? currentRepository(with: item.id)
            else {
                continue
            }
            onAssignRepository(repository, namespace, project)
            handled = true
        }

        return handled
    }

    private func toggleProject(_ project: RepositoryProject) {
        if expandedProjectIDs.contains(project.id) {
            expandedProjectIDs.remove(project.id)
        } else {
            expandedProjectIDs.insert(project.id)
        }
    }

    private func currentProject(with id: UUID) -> RepositoryProject? {
        projects.first(where: { $0.id == id })
    }

    private func currentRepository(with id: UUID) -> ManagedRepository? {
        repositories.first(where: { $0.id == id })
    }

    private func projectSort(_ lhs: RepositoryProject, _ rhs: RepositoryProject) -> Bool {
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct RepositoryRow: View {
    let repository: ManagedRepository
    let isRefreshing: Bool
    let isAgentRunning: Bool
    let activeDevContainerCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(repository.displayName)
                    .font(.headline)
                if repository.isDocumentationRepository {
                    Label("Docs", systemImage: "book.closed.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                if isAgentRunning {
                    AgentActivityDot()
                }
                if activeDevContainerCount > 0 {
                    Label("\(activeDevContainerCount)", systemImage: "shippingbox.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            Text(repository.defaultRemote?.url ?? repository.remoteURL ?? "No remote configured")
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
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
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

private struct SidebarSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

private struct ProjectHeaderRow: View {
    let project: RepositoryProject
    let repositoryCount: Int
    let documentationConfigured: Bool
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                if documentationConfigured {
                    Image(systemName: "book.closed.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .help("Dokumentationsquelle konfiguriert")
                }
                Spacer()
                Text("\(repositoryCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

private struct NamespacePickerPopover: View {
    let namespaces: [RepositoryNamespace]
    let selectedNamespaceID: UUID?
    let onSelect: (RepositoryNamespace) -> Void
    let onRename: (RepositoryNamespace) -> Void
    let onDelete: (RepositoryNamespace) -> Void
    let onCreateNamespace: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(namespaces) { namespace in
                        NamespacePickerRow(
                            namespace: namespace,
                            isSelected: namespace.id == selectedNamespaceID,
                            onSelect: { onSelect(namespace) },
                            onRename: namespace.isDefault ? nil : { onRename(namespace) },
                            onDelete: namespace.isDefault ? nil : { onDelete(namespace) }
                        )
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)

            Divider()

            Button(action: onCreateNamespace) {
                Label("New Namespace…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .frame(minWidth: 260)
    }
}

private struct NamespacePickerRow: View {
    let namespace: RepositoryNamespace
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (() -> Void)?
    let onDelete: (() -> Void)?

    private var repoCount: Int { namespace.repositories.count }
    private var projectCount: Int { namespace.projects.count }
    private var worktreeCount: Int { namespace.repositories.reduce(0) { $0 + $1.worktrees.count } }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 3) {
                    Text(namespace.name)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(.primary)

                    HStack(spacing: 10) {
                        if projectCount > 0 {
                            Label("\(projectCount)", systemImage: "folder")
                        }
                        Label("\(repoCount)", systemImage: "shippingbox")
                        if worktreeCount > 0 {
                            Label("\(worktreeCount)", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onRename {
                Button("Rename…") { onRename() }
            }
            if let onDelete {
                Divider()
                Button("Delete", role: .destructive) { onDelete() }
            }
        }
    }
}

private struct SidebarDragItem: Codable, Transferable {
    enum Kind: String, Codable {
        case project
        case repository
    }

    let kind: Kind
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .stackriotSidebarItem)
    }
}

private extension UTType {
    static let stackriotSidebarItem = UTType(exportedAs: "io.hildebrandt.stackriot.sidebar-item")
}
