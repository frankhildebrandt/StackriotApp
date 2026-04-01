import SwiftData
import SwiftUI

private struct WorktreeBuckets {
    var defaultWorktree: WorktreeRecord?
    var pinnedWorktrees: [WorktreeRecord] = []
    var ideaTrees: [WorktreeRecord] = []
    var regularWorktrees: [WorktreeRecord] = []
    var featureWorktrees: [WorktreeRecord] = []

    init(worktrees: [WorktreeRecord]) {
        pinnedWorktrees.reserveCapacity(worktrees.count)
        ideaTrees.reserveCapacity(worktrees.count)
        regularWorktrees.reserveCapacity(worktrees.count)
        featureWorktrees.reserveCapacity(worktrees.count)

        for worktree in worktrees {
            if worktree.isDefaultBranchWorkspace {
                defaultWorktree = worktree
                continue
            }

            if !worktree.isIdeaTree {
                featureWorktrees.append(worktree)
            }

            if worktree.isPinned {
                pinnedWorktrees.append(worktree)
            } else if worktree.isIdeaTree {
                ideaTrees.append(worktree)
            } else {
                regularWorktrees.append(worktree)
            }
        }
    }
}

struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let repository: ManagedRepository
    @State private var worktreePendingRemoval: WorktreeRemovalDraft?
    @State private var worktreePendingMove: WorktreeMoveDraft?
    @State private var removingWorktreeIDs: Set<UUID> = []
    @State private var movingWorktreeIDs: Set<UUID> = []
    @State private var isRefreshingStatuses = false
    @State private var isPushingDefaultBranch = false
    @State private var hoveredWorktreeID: UUID?
    @State private var isIntegrationSheetPresented = false
    @State private var integrationTargetWorktreeID: UUID?
    @State private var integrationTargetBranchName = ""
    @AppStorage("hasSeenWorktreeOnboarding") private var hasSeenWorktreeOnboarding = false

    var body: some View {
        let worktrees = appModel.worktrees(for: repository)
        let worktreeBuckets = WorktreeBuckets(worktrees: worktrees)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                worktreeSection(worktrees: worktrees, buckets: worktreeBuckets)

                if selectedWorktree == nil {
                    emptyWorktreeState
                }
            }
            .padding(24)
        }
        .navigationTitle(repository.displayName)
        .task(id: repository.id) {
            _ = await appModel.ensureDefaultBranchWorkspace(for: repository, in: modelContext)
            appModel.ensureSelectedWorktree(in: repository)
            appModel.restoreAllPRMonitoring(in: modelContext)
        }
        .sheet(isPresented: $isIntegrationSheetPresented) {
            if let worktreeID = integrationTargetWorktreeID {
                IntegrateWorktreeSheet(
                    worktreeID: worktreeID,
                    repository: repository,
                    initialBranchName: integrationTargetBranchName
                )
            }
        }
        .confirmationDialog("Remove worktree?", item: $worktreePendingRemoval) { worktree in
            Button("Remove", role: .destructive) {
                worktreePendingRemoval = nil
                if let record = appModel.worktreeRecord(with: worktree.id) {
                    removeWorktree(record)
                }
            }
        } message: { worktree in
            Text("""
            This removes the local worktree at \(worktree.path).
            Open tabs and local run history for this worktree will be cleaned up, while the bare repository and remote branch stay untouched.
            """)
        }
        .confirmationDialog("Worktree verschieben?", item: $worktreePendingMove) { draft in
            Button("Verschieben") {
                worktreePendingMove = nil
                if let record = appModel.worktreeRecord(with: draft.id) {
                    moveWorktree(record, to: draft.destinationRoot)
                }
            }
            Button("Abbrechen", role: .cancel) {
                worktreePendingMove = nil
            }
        } message: { draft in
            Text("""
            \(draft.branchName) wird nach \(draft.destinationPath) verschoben.
            Branch, Run-Historie und Zuordnung bleiben erhalten, nur der lokale Pfad wird aktualisiert.
            """)
        }
        .alert("Rebase fehlgeschlagen", isPresented: Binding(
            get: { appModel.worktreePendingMergeOfferID != nil },
            set: { newValue in
                if !newValue {
                    appModel.worktreePendingMergeOfferID = nil
                }
            }
        )) {
            Button("Merge versuchen") {
                if
                    let worktreeID = appModel.worktreePendingMergeOfferID,
                    let worktree = appModel.worktreeRecord(with: worktreeID)
                {
                    Task {
                        await appModel.syncWorktreeFromMain(
                            worktree,
                            repository: repository,
                            strategy: .merge,
                            modelContext: modelContext
                        )
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {
                appModel.worktreePendingMergeOfferID = nil
            }
        } message: {
            Text("Der Rebase von \(repository.defaultBranch) konnte nicht abgeschlossen werden. Möchtest du stattdessen einen Merge versuchen?")
        }
        .confirmationDialog("Merge-Konflikte auflösen", isPresented: Binding(
            get: { appModel.pendingIntegrationConflict != nil },
            set: { newValue in
                if !newValue {
                    appModel.pendingIntegrationConflict = nil
                }
            }
        ), presenting: appModel.pendingIntegrationConflict) { draft in
            ForEach(availableAgents) { tool in
                Button("Mit \(tool.displayName)") {
                    Task {
                        await appModel.launchConflictResolutionAgent(tool, for: draft, in: modelContext)
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {
                appModel.pendingIntegrationConflict = nil
            }
        } message: { draft in
            Text("""
            Beim Integrieren von \(draft.sourceBranch) in \(draft.defaultBranch) sind Konflikte entstanden.
            Wähle einen Agenten, der die Konflikte löst und den Commit `\(draft.commitMessage)` erstellt.
            """)
        }
    }

    private func worktreeSection(worktrees: [WorktreeRecord], buckets: WorktreeBuckets) -> some View {
        let defaultWorktree = buckets.defaultWorktree
        let pinnedWorktrees = buckets.pinnedWorktrees
        let ideaTrees = buckets.ideaTrees
        let regularWorktrees = buckets.regularWorktrees
        let featureWorktrees = buckets.featureWorktrees

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Worktrees")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    isRefreshingStatuses = true
                    Task {
                        await appModel.refreshWorktreeStatuses(for: repository)
                        isRefreshingStatuses = false
                    }
                } label: {
                    if isRefreshingStatuses {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshingStatuses)
                Button {
                    appModel.presentPullRequestCheckoutSheet(for: repository)
                } label: {
                    Label("Checkout PR", systemImage: "arrow.down.doc")
                }
                Button {
                    appModel.presentWorktreeSheet(for: repository)
                } label: {
                    Label("Create IdeaTree", systemImage: "plus")
                }
            }

            // Einmaliger Onboarding-Hinweis
            if !hasSeenWorktreeOnboarding {
                onboardingBanner
            }

            if worktrees.isEmpty {
                Text("No worktrees yet. Create one from the bare repository to start development.")
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if let defaultWorktree {
                        worktreeGroup(
                            title: "Main / Default",
                            subtitle: "Die geschützte Haupt-Workspace für \(repository.defaultBranch).",
                            worktrees: [defaultWorktree]
                        )
                    }

                    if !pinnedWorktrees.isEmpty {
                        worktreeGroup(
                            title: "Angepinnt",
                            subtitle: "Bleiben bei der Integration erhalten und liegen über den normalen Worktrees.",
                            worktrees: pinnedWorktrees
                        )
                    }

                    if !ideaTrees.isEmpty {
                        worktreeGroup(
                            title: "IdeaTrees",
                            subtitle: "Leichte Worktree-Entwuerfe ohne lokalen Checkout. Materialisieren erst bei Plan/Agent/Terminal.",
                            worktrees: ideaTrees
                        )
                    }

                    worktreeGroup(
                        title: (defaultWorktree != nil || !pinnedWorktrees.isEmpty || !ideaTrees.isEmpty) ? "Weitere Worktrees" : nil,
                        worktrees: regularWorktrees
                    )
                }

                if featureWorktrees.isEmpty {
                    featureWorktreeMotivationCard
                }
            }
        }
    }

    private var emptyWorktreeState: some View {
        ContentUnavailableView("Select a Worktree", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Choose or create a worktree to launch editors and run discovered configurations from native tools and supported IDEs."))
            .frame(maxWidth: .infinity, minHeight: 280)
    }

    private var selectedWorktree: WorktreeRecord? {
        appModel.selectedWorktree(for: repository)
    }

    private var availableAgents: [AIAgentTool] {
        AIAgentTool.allCases.filter { tool in
            tool != .none && appModel.availableAgents.contains(tool)
        }
    }

    private func autoSyncAvailable(for worktree: WorktreeRecord) -> Bool {
        guard !worktree.isDefaultBranchWorkspace else { return false }
        guard worktree.allowsSyncFromDefaultBranch else { return false }
        let status = appModel.worktreeStatuses[worktree.id]
        return (status?.behindCount ?? 0) > 0
            && !(status?.hasUncommittedChanges ?? false)
            && !(status?.hasConflicts ?? false)
    }

    private func isRemovingWorktree(_ worktree: WorktreeRecord) -> Bool {
        removingWorktreeIDs.contains(worktree.id)
    }

    private func isMovingWorktree(_ worktree: WorktreeRecord) -> Bool {
        movingWorktreeIDs.contains(worktree.id)
    }

    @ViewBuilder
    private func worktreeGroup(
        title: String?,
        subtitle: String? = nil,
        worktrees: [WorktreeRecord]
    ) -> some View {
        if !worktrees.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let title {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(spacing: 10) {
                    ForEach(worktrees) { worktree in
                        worktreeCard(worktree)
                    }
                }
            }
        }
    }

    private func worktreeCard(_ worktree: WorktreeRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if autoSyncAvailable(for: worktree) {
                    Button {
                        Task {
                            await appModel.syncWorktreeFromMain(
                                worktree,
                                repository: repository,
                                strategy: .rebase,
                                modelContext: modelContext
                            )
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.orange)
                            .imageScale(.medium)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRemovingWorktree(worktree))
                    .help("\(worktree.branchName) jetzt mit \(repository.defaultBranch) synchronisieren")
                }

                Rectangle()
                    .fill(selectedWorktree?.id == worktree.id ? worktreeAccentColor(for: worktree) : Color.clear)
                    .frame(width: 2)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(worktreeTitle(for: worktree))
                            .font(.headline)
                        if worktree.isIdeaTree {
                            Image(systemName: "lightbulb.fill")
                                .imageScale(.small)
                                .foregroundStyle(.yellow)
                                .help("IdeaTree")
                        }
                        if worktree.isPinned {
                            Image(systemName: "pin.fill")
                                .imageScale(.small)
                                .foregroundStyle(worktreeAccentColor(for: worktree))
                                .help("Angepinnt")
                        }
                        if worktree.cardColor != .none {
                            Circle()
                                .fill(worktreeAccentColor(for: worktree))
                                .frame(width: 10, height: 10)
                                .help("Kartenfarbe: \(worktree.cardColor.displayName)")
                        }
                        if worktree.isDefaultBranchWorkspace {
                            Text(repository.defaultBranch)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                            if let defaultRemote = appModel.resolvedDefaultRemote(for: repository) {
                                Text(defaultRemote.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.blue.opacity(0.12), in: Capsule())
                            }
                        }
                        if appModel.isAgentRunning(for: worktree) {
                            AgentActivityDot()
                        }
                    }

                    worktreeStatusRow(for: worktree)
                    worktreeLifecycleIndicator(for: worktree)

                    if let context = worktree.resolvedPrimaryContext {
                        HStack(spacing: 8) {
                            Label(context.label, systemImage: context.kind == .pullRequest ? "arrow.triangle.merge" : (context.provider == .jira ? "link" : "number.square"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let prStatus = appModel.pullRequestUpstreamStatuses[worktree.id],
                               context.kind == .pullRequest,
                               prStatus.hasRemoteUpdate
                            {
                                Label("Update verfuegbar", systemImage: "arrow.down.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else if let issueContext = worktree.issueContext {
                        Label(issueContext, systemImage: "number")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let displayPath = worktree.displayPath {
                        Label(displayPath, systemImage: worktree.isIdeaTree ? "clock.badge.sparkles" : "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if worktree.isIdeaTree {
                        Label("Noch nicht materialisiert", systemImage: "lightbulb")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isRemovingWorktree(worktree) || isMovingWorktree(worktree) {
                    ProgressView()
                        .controlSize(.small)
                        .help(isRemovingWorktree(worktree) ? "Worktree wird entfernt" : "Worktree wird verschoben")
                } else {
                    HStack(spacing: 10) {
                        if let prStatus = appModel.pullRequestUpstreamStatuses[worktree.id],
                           worktree.resolvedPrimaryContext?.kind == .pullRequest,
                           prStatus.hasRemoteUpdate
                        {
                            Button {
                                Task {
                                    await appModel.updateCheckedOutPullRequest(worktree, repository: repository, modelContext: modelContext)
                                }
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.orange)
                                    .imageScale(.large)
                            }
                            .buttonStyle(.plain)
                            .help("PR-Head aktualisieren")
                        }

                        if !worktree.isDefaultBranchWorkspace {
                            Button {
                                togglePinned(worktree)
                            } label: {
                                Image(systemName: worktree.isPinned ? "pin.fill" : "pin")
                                    .foregroundStyle(worktree.isPinned ? worktreeAccentColor(for: worktree) : .secondary)
                                    .imageScale(.large)
                            }
                            .buttonStyle(.plain)
                            .help(worktree.isPinned ? "Worktree entpinnen" : "Worktree anpinnen")
                        }

                        if showsIntegrationButton(for: worktree) {
                            Button {
                                appModel.integrationDraft = IntegrationDraft(
                                    prTitle: worktree.branchName
                                )
                                integrationTargetWorktreeID = worktree.id
                                integrationTargetBranchName = worktree.branchName
                                isIntegrationSheetPresented = true
                            } label: {
                                Image(systemName: worktree.lifecycleState == .integrating
                                    ? "arrow.up.circle"
                                    : "arrow.up.circle.fill")
                                    .foregroundStyle(worktree.lifecycleState == .integrating ? .orange : .secondary)
                                    .imageScale(.large)
                            }
                            .buttonStyle(.plain)
                            .disabled(worktree.lifecycleState == .integrating)
                            .help("In \(repository.defaultBranch) integrieren")
                        }
                    }
                }
            }

            if worktree.isDefaultBranchWorkspace {
                defaultBranchIndicatorRow(for: worktree)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(worktreeCardTint(for: worktree))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    worktreeCardBorder(for: worktree),
                    lineWidth: selectedWorktree?.id == worktree.id ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            appModel.selectWorktree(worktree, in: repository)
        }
        .onHover { isHovering in
            hoveredWorktreeID = isHovering ? worktree.id : nil
        }
        .contextMenu {
            ForEach(appModel.availableDevTools(for: worktree)) { tool in
                Button("Open in \(tool.displayName)") {
                    Task {
                        await appModel.openDevTool(tool, for: worktree, in: modelContext)
                    }
                }
            }
            Button("In Finder zeigen") {
                Task {
                    await appModel.revealWorktreeInFinder(worktree)
                }
            }
            .disabled(worktree.isIdeaTree)
            Menu("Kartenfarbe") {
                ForEach(WorktreeCardColor.allCases) { color in
                    Button {
                        appModel.setCardColor(color, for: worktree, in: repository, modelContext: modelContext)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(worktreeAccentColor(for: color))
                                .frame(width: 10, height: 10)
                            Text(color.displayName)
                            if worktree.cardColor == color {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            if !worktree.isDefaultBranchWorkspace {
                Divider()
                Button(worktree.isPinned ? "Worktree entpinnen" : "Worktree anpinnen") {
                    togglePinned(worktree)
                }
                Button("Worktree verschieben") {
                    presentMoveDialog(for: worktree)
                }
                .disabled(isMovingWorktree(worktree) || isRemovingWorktree(worktree))
                Button("Mit \(repository.defaultBranch) synchronisieren") {
                    Task {
                        await appModel.syncWorktreeFromMain(
                            worktree,
                            repository: repository,
                            strategy: .rebase,
                            modelContext: modelContext
                        )
                    }
                }
                Button("In Main/Default integrieren") {
                    appModel.integrationDraft = IntegrationDraft(
                        prTitle: worktree.branchName
                    )
                    integrationTargetWorktreeID = worktree.id
                    integrationTargetBranchName = worktree.branchName
                    isIntegrationSheetPresented = true
                }
                Button("Publish Branch") {
                    appModel.presentPublishSheet(for: repository, worktree: worktree)
                }
                Divider()
                Button("Remove Worktree", role: .destructive) {
                    worktreePendingRemoval = WorktreeRemovalDraft(id: worktree.id, path: worktree.displayPath ?? worktree.branchName)
                }
                .disabled(isRemovingWorktree(worktree))
            }
        }
    }

    private func togglePinned(_ worktree: WorktreeRecord) {
        appModel.setPinned(!worktree.isPinned, for: worktree, in: repository, modelContext: modelContext)
    }

    private func removeWorktree(_ worktree: WorktreeRecord) {
        removingWorktreeIDs.insert(worktree.id)
        Task {
            await appModel.removeWorktree(worktree, in: modelContext)
            removingWorktreeIDs.remove(worktree.id)
        }
    }

    private func moveWorktree(_ worktree: WorktreeRecord, to destinationRoot: URL) {
        movingWorktreeIDs.insert(worktree.id)
        Task {
            await appModel.moveWorktree(worktree, in: repository, to: destinationRoot, modelContext: modelContext)
            movingWorktreeIDs.remove(worktree.id)
        }
    }

    private func presentMoveDialog(for worktree: WorktreeRecord) {
        let currentDirectory = worktree.materializedURL?.deletingLastPathComponent()
            ?? worktree.destinationRootURL
            ?? AppPaths.worktreesRoot.appendingPathComponent(repository.displayName, isDirectory: true)
        guard let destinationRoot = IDEManager.chooseDirectory(
            title: "Worktree verschieben",
            message: "Stackriot erstellt darunter einen Unterordner fuer den Worktree.",
            prompt: "Verschieben",
            initialDirectory: currentDirectory
        ) else {
            return
        }

        let destinationPath = destinationRoot.appendingPathComponent(worktree.branchName, isDirectory: true).path
        worktreePendingMove = WorktreeMoveDraft(
            id: worktree.id,
            branchName: worktree.branchName,
            destinationRoot: destinationRoot,
            destinationPath: destinationPath
        )
    }

    private func showsIntegrationButton(for worktree: WorktreeRecord) -> Bool {
        guard !worktree.isDefaultBranchWorkspace else { return false }
        guard !worktree.isIdeaTree else { return false }
        guard worktree.resolvedPrimaryContext?.kind != .pullRequest else { return false }
        if worktree.lifecycleState == .integrating {
            return true
        }
        let status = appModel.worktreeStatuses[worktree.id]
        return (status?.aheadCount ?? 0) > 0
    }

    private func worktreeTitle(for worktree: WorktreeRecord) -> String {
        worktree.isDefaultBranchWorkspace ? "Main/Default" : worktree.branchName
    }

    private func worktreeAccentColor(for worktree: WorktreeRecord) -> Color {
        worktreeAccentColor(for: worktree.cardColor)
    }

    private func worktreeAccentColor(for color: WorktreeCardColor) -> Color {
        switch color {
        case .none:
            .accentColor
        case .blue:
            .blue
        case .green:
            .green
        case .orange:
            .orange
        case .purple:
            .purple
        case .pink:
            .pink
        case .slate:
            .gray
        }
    }

    private func worktreeCardTint(for worktree: WorktreeRecord) -> Color {
        let isSelected = selectedWorktree?.id == worktree.id
        let isHovered = hoveredWorktreeID == worktree.id

        if worktree.cardColor == .none {
            if isSelected {
                return Color.accentColor.opacity(0.10)
            }
            if isHovered {
                return Color.primary.opacity(0.04)
            }
            return .clear
        }

        let accent = worktreeAccentColor(for: worktree)
        if isSelected {
            return accent.opacity(0.22)
        }
        if isHovered {
            return accent.opacity(0.18)
        }
        return accent.opacity(0.12)
    }

    private func worktreeCardBorder(for worktree: WorktreeRecord) -> Color {
        if worktree.cardColor == .none {
            return selectedWorktree?.id == worktree.id
                ? Color.accentColor.opacity(0.30)
                : Color.primary.opacity(0.07)
        }

        return worktreeAccentColor(for: worktree).opacity(selectedWorktree?.id == worktree.id ? 0.42 : 0.24)
    }

    // MARK: - Lifecycle Indicator

    @ViewBuilder
    private func worktreeLifecycleIndicator(for worktree: WorktreeRecord) -> some View {
        switch worktree.lifecycleState {
        case .active:
            if worktree.isIdeaTree {
                Label("IdeaTree", systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            } else if worktree.resolvedPrimaryContext?.kind == .pullRequest {
                HStack(spacing: 6) {
                    Label("PR Worktree", systemImage: "arrow.triangle.merge")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    if let prStatus = appModel.pullRequestUpstreamStatuses[worktree.id], prStatus.hasRemoteUpdate {
                        Label("Update verfuegbar", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                EmptyView()
            }
        case .integrating:
            HStack(spacing: 6) {
                Label("PR offen", systemImage: "arrow.triangle.merge")
                    .font(.caption)
                    .foregroundStyle(.blue)
                if let prStatus = appModel.pullRequestUpstreamStatuses[worktree.id], prStatus.hasRemoteUpdate {
                    Label("Update verfuegbar", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let urlString = worktree.prURL ?? worktree.resolvedPrimaryContext?.canonicalURL, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
        case .merged:
            Label("Merged", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    // MARK: - Motivational UX

    private var featureWorktreeMotivationCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Einen Worktree pro Feature")
                    .font(.subheadline.weight(.medium))
                Text("Paralleles Arbeiten, saubere Isolation. Starte einen neuen Worktree für den nächsten Task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                appModel.presentWorktreeSheet(for: repository)
            } label: {
                Label("Neuer Worktree", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var onboardingBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 3) {
                Text("Feature-Workflow mit Worktrees")
                    .font(.caption.weight(.semibold))
                Text("Erstelle für jedes Feature einen eigenen Worktree. Der ↑-Button auf jeder Karte startet den Integrations-Workflow — lokal oder als GitHub PR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Verstanden") {
                hasSeenWorktreeOnboarding = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.yellow.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func defaultBranchIndicatorRow(for worktree: WorktreeRecord) -> some View {
        let status = appModel.worktreeStatuses[worktree.id]
        let ahead = status?.aheadCount ?? 0
        let behind = status?.behindCount ?? 0

        HStack(spacing: 10) {
            if let defaultRemote = appModel.resolvedDefaultRemote(for: repository) {
                Text("Basis von \(defaultRemote.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Keine Default-Remote-Konfiguration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isRefreshingStatuses = true
                Task {
                    await appModel.refresh(repository, in: modelContext)
                    isRefreshingStatuses = false
                }
            } label: {
                if isRefreshingStatuses {
                    Label("Sync…", systemImage: "arrow.down.to.line")
                } else {
                    Label(behind == 0 ? "Sync" : "Sync (\(behind))", systemImage: "arrow.down.to.line")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRefreshingStatuses)
            .help("Den periodischen Fetch- und Sync-Ablauf für \(repository.defaultBranch) sofort ausführen")

            Button {
                isPushingDefaultBranch = true
                Task {
                    await appModel.runGitPush(in: worktree, repository: repository, modelContext: modelContext)
                    await appModel.refresh(repository, in: modelContext)
                    isPushingDefaultBranch = false
                }
            } label: {
                if isPushingDefaultBranch {
                    Label("Push…", systemImage: "arrow.up.to.line")
                } else {
                    Label(ahead == 0 ? "Push" : "Push \(ahead)", systemImage: "arrow.up.to.line")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(ahead == 0 || isPushingDefaultBranch || isRefreshingStatuses)
            .opacity(ahead > 0 ? 1 : 0.6)
            .help(
                ahead == 0
                    ? "Keine lokalen Commits zum Pushen."
                    : "Lokale Commits auf \(repository.defaultBranch) zum Remote pushen."
            )
        }
        Group {
            if let log = appModel.syncLogs[repository.id] {
                Text(log)
                    .font(.caption.monospaced())
                    .foregroundStyle(log.contains("⚠") ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func worktreeStatusRow(for worktree: WorktreeRecord) -> some View {
        if worktree.isIdeaTree {
            Label("Materialisiert bei Bedarf", systemImage: "wand.and.stars")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let status = appModel.worktreeStatuses[worktree.id]
            let ahead = worktree.isDefaultBranchWorkspace ? 0 : (status?.aheadCount ?? 0)
            let behind = worktree.isDefaultBranchWorkspace ? 0 : (status?.behindCount ?? 0)
            let added = status?.addedLines ?? 0
            let deleted = status?.deletedLines ?? 0
            let hasChanges = status?.hasUncommittedChanges ?? false

            if ahead > 0 || behind > 0 || hasChanges {
                HStack(spacing: 8) {
                    if behind > 0 {
                        Label("\(behind)", systemImage: "arrow.down")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    if ahead > 0 {
                        Label("\(ahead)", systemImage: "arrow.up")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if hasChanges {
                        if ahead > 0 || behind > 0 {
                            Divider()
                                .frame(height: 10)
                        }
                        Text("+\(added)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.green)
                        Text("-\(deleted)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

private struct WorktreeMoveDraft: Identifiable {
    let id: UUID
    let branchName: String
    let destinationRoot: URL
    let destinationPath: String
}
