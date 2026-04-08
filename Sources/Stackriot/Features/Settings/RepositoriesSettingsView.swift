import AppKit
import SwiftUI

struct RepositoriesSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppPreferences.autoRefreshEnabledKey) private var autoRefreshEnabled = AppPreferences.defaultAutoRefreshEnabled
    @AppStorage(AppPreferences.autoRefreshIntervalKey) private var autoRefreshInterval = AppPreferences.defaultAutoRefreshInterval
    @AppStorage(AppPreferences.worktreeStatusPollingEnabledKey) private var worktreeStatusPollingEnabled =
        AppPreferences.defaultWorktreeStatusPollingEnabled
    @AppStorage(AppPreferences.worktreeStatusPollingIntervalKey) private var worktreeStatusPollingInterval =
        AppPreferences.defaultWorktreeStatusPollingInterval
    @AppStorage(AppPreferences.performanceDebugModeEnabledKey) private var performanceDebugModeEnabled =
        AppPreferences.defaultPerformanceDebugModeEnabled
    @AppStorage(AppPreferences.repositoriesRootLocationKey) private var repositoriesRootLocationRawValue =
        AppPreferences.defaultPathLocation.rawValue
    @AppStorage(AppPreferences.repositoriesRootCustomPathKey) private var repositoriesRootCustomPath = ""
    @AppStorage(AppPreferences.worktreesRootLocationKey) private var worktreesRootLocationRawValue =
        AppPreferences.defaultPathLocation.rawValue
    @AppStorage(AppPreferences.worktreesRootCustomPathKey) private var worktreesRootCustomPath = ""
    @State private var repositoriesRootLocationDraft = AppPreferences.repositoriesRootLocation
    @State private var repositoriesRootCustomPathDraft = AppPreferences.repositoriesRootCustomPath ?? ""
    @State private var worktreesRootLocationDraft = AppPreferences.worktreesRootLocation
    @State private var worktreesRootCustomPathDraft = AppPreferences.worktreesRootCustomPath ?? ""
    @State private var pendingPathRelocationRequest: PathRelocationRequest?

    var body: some View {
        SettingsFormPage(category: .repositories) {
            Section {
                Toggle("Automatically refresh repositories", isOn: $autoRefreshEnabled)
                Picker("Refresh interval", selection: $autoRefreshInterval) {
                    Text("Every 5 minutes").tag(300.0)
                    Text("Every 15 minutes").tag(900.0)
                    Text("Every hour").tag(3600.0)
                }
            } header: {
                Text("Remote refresh")
            } footer: {
                Text("Fetches from remotes and syncs default-branch worktrees. Runs in the background on the interval above.")
            }

            Section {
                Toggle("Poll worktree status for selected repository", isOn: $worktreeStatusPollingEnabled)
                Picker("Status interval", selection: $worktreeStatusPollingInterval) {
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every minute").tag(60.0)
                    Text("Every 2 minutes").tag(120.0)
                    Text("Every 5 minutes").tag(300.0)
                    Text("Every 15 minutes").tag(900.0)
                }
                .disabled(!worktreeStatusPollingEnabled)
            } header: {
                Text("Worktree status (local)")
            } footer: {
                Text("Updates ahead/behind, uncommitted line counts, and PR upstream for the currently selected repository only. Does not run git fetch; use Remote refresh for that.")
            }

            Section {
                LabeledContent("Working mode", value: "Bare repositories + worktrees")
            } header: {
                Text("Repository workflow")
            } footer: {
                Text("Stackriot stores shared Git data in a bare repository and creates worktrees for active tasks.")
            }

            Section {
                Picker("Repositories", selection: repositoriesRootLocationBinding) {
                    ForEach(AppPathLocation.allCases) { location in
                        Text(location.displayName).tag(location)
                    }
                }

                LabeledContent("Effective path") {
                    settingsPathValue(repositoriesEffectiveRoot.path)
                }

                if repositoriesRootLocationDraft == .custom {
                    LabeledContent("Custom folder") {
                        settingsPathValue(repositoriesRootCustomPathDraft.nonEmpty ?? "No folder selected")
                    }

                    HStack {
                        Button("Choose folder") {
                            chooseRepositoriesRoot()
                        }

                        Button("Show in Finder") {
                            revealInFinder(repositoriesEffectiveRoot)
                        }
                    }
                }
            } header: {
                Text("Default repository path")
            } footer: {
                Text("New bare repositories are created under the effective path above. Stackriot keeps them inside a `Repositories` subfolder in the selected base folder.")
            }

            Section {
                Picker("Worktrees", selection: worktreesRootLocationBinding) {
                    ForEach(AppPathLocation.allCases) { location in
                        Text(location.displayName).tag(location)
                    }
                }

                LabeledContent("Effective path") {
                    settingsPathValue(worktreesEffectiveRoot.path)
                }

                if worktreesRootLocationDraft == .custom {
                    LabeledContent("Custom folder") {
                        settingsPathValue(worktreesRootCustomPathDraft.nonEmpty ?? "No folder selected")
                    }

                    HStack {
                        Button("Choose folder") {
                            chooseWorktreesRoot()
                        }

                        Button("Show in Finder") {
                            revealInFinder(worktreesEffectiveRoot)
                        }
                    }
                }
            } header: {
                Text("Default worktree path")
            } footer: {
                Text("New default-branch workspaces and new worktrees use this location unless you override the destination for an individual worktree.")
            }

            Section {
                Toggle("Enable performance debug artifact", isOn: $performanceDebugModeEnabled)
                LabeledContent("Artifact file") {
                    Text(appModel.performanceDebugArtifactURL().path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Show in Finder") {
                        Task {
                            await appModel.revealPerformanceDebugArtifact()
                        }
                    }

                    Button("Copy artifact") {
                        appModel.copyPerformanceDebugArtifactToPasteboard()
                    }

                    Button("Clear artifact") {
                        appModel.clearPerformanceDebugArtifact()
                    }
                }
            } header: {
                Text("Performance debug")
            } footer: {
                Text("Enable this, reproduce the slow repository or worktree switch, then send the JSONL artifact file for analysis.")
            }
        }
        .disabled(appModel.pathRelocationProgress != nil)
        .onAppear {
            syncDraftsFromPreferences()
        }
        .sheet(item: $pendingPathRelocationRequest) { request in
            PathRelocationDecisionSheet(
                request: request,
                moveDisabled: !appModel.activeRunIDs.isEmpty,
                onCancel: {
                    pendingPathRelocationRequest = nil
                    syncDraftsFromPreferences()
                },
                onKeepExisting: {
                    pendingPathRelocationRequest = nil
                    Task {
                        await appModel.applyPathRelocationRequest(request, moveExistingItems: false, modelContext: modelContext)
                        syncDraftsFromPreferences()
                    }
                },
                onMoveExisting: {
                    pendingPathRelocationRequest = nil
                    Task {
                        await appModel.applyPathRelocationRequest(request, moveExistingItems: true, modelContext: modelContext)
                        syncDraftsFromPreferences()
                    }
                }
            )
        }
        .overlay {
            if let progress = appModel.pathRelocationProgress {
                PathRelocationProgressOverlay(progress: progress)
            }
        }
    }

    private var repositoriesRootLocation: AppPathLocation {
        AppPathLocation(rawValue: repositoriesRootLocationRawValue) ?? AppPreferences.defaultPathLocation
    }

    private var worktreesRootLocation: AppPathLocation {
        AppPathLocation(rawValue: worktreesRootLocationRawValue) ?? AppPreferences.defaultPathLocation
    }

    private var repositoriesRootLocationBinding: Binding<AppPathLocation> {
        Binding(
            get: { repositoriesRootLocationDraft },
            set: { updateRepositoriesRootLocation(to: $0) }
        )
    }

    private var worktreesRootLocationBinding: Binding<AppPathLocation> {
        Binding(
            get: { worktreesRootLocationDraft },
            set: { updateWorktreesRootLocation(to: $0) }
        )
    }

    private var repositoriesEffectiveRoot: URL {
        let base = AppPaths.baseDirectory(
            location: repositoriesRootLocationDraft,
            customPath: repositoriesRootCustomPathDraft.nonEmpty
        )
        return AppPaths.repositoriesRoot(in: base)
    }

    private var worktreesEffectiveRoot: URL {
        let base = AppPaths.baseDirectory(
            location: worktreesRootLocationDraft,
            customPath: worktreesRootCustomPathDraft.nonEmpty
        )
        return AppPaths.worktreesRoot(in: base)
    }

    @ViewBuilder
    private func settingsPathValue(_ value: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private func chooseRepositoriesRoot() {
        let initialDirectory = AppPreferences.repositoriesRootCustomPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppPaths.repositoriesBaseDirectory
        guard let selectedDirectory = IDEManager.chooseDirectory(
            title: "Choose repository base folder",
            message: "Stackriot creates the Repositories subfolder inside this location.",
            prompt: "Choose",
            initialDirectory: initialDirectory
        ) else {
            return
        }
        repositoriesRootLocationDraft = .custom
        repositoriesRootCustomPathDraft = selectedDirectory.path
        requestPathUpdate(
            scope: .repositories,
            newLocation: .custom,
            newCustomPath: selectedDirectory.path
        )
    }

    private func chooseWorktreesRoot() {
        let initialDirectory = worktreesRootCustomPathDraft.nonEmpty.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppPaths.worktreesBaseDirectory
        guard let selectedDirectory = IDEManager.chooseDirectory(
            title: "Choose worktree base folder",
            message: "Stackriot creates the Worktrees subfolder inside this location.",
            prompt: "Choose",
            initialDirectory: initialDirectory
        ) else {
            return
        }
        worktreesRootLocationDraft = .custom
        worktreesRootCustomPathDraft = selectedDirectory.path
        requestPathUpdate(
            scope: .worktrees,
            newLocation: .custom,
            newCustomPath: selectedDirectory.path
        )
    }

    private func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func syncDraftsFromPreferences() {
        repositoriesRootLocationDraft = repositoriesRootLocation
        repositoriesRootCustomPathDraft = repositoriesRootCustomPath
        worktreesRootLocationDraft = worktreesRootLocation
        worktreesRootCustomPathDraft = worktreesRootCustomPath
    }

    private func updateRepositoriesRootLocation(to newLocation: AppPathLocation) {
        if newLocation == .custom, repositoriesRootCustomPathDraft.nilIfBlank == nil {
            chooseRepositoriesRoot()
            return
        }
        repositoriesRootLocationDraft = newLocation
        requestPathUpdate(
            scope: .repositories,
            newLocation: newLocation,
            newCustomPath: newLocation == .custom ? repositoriesRootCustomPathDraft : nil
        )
    }

    private func updateWorktreesRootLocation(to newLocation: AppPathLocation) {
        if newLocation == .custom, worktreesRootCustomPathDraft.nilIfBlank == nil {
            chooseWorktreesRoot()
            return
        }
        worktreesRootLocationDraft = newLocation
        requestPathUpdate(
            scope: .worktrees,
            newLocation: newLocation,
            newCustomPath: newLocation == .custom ? worktreesRootCustomPathDraft : nil
        )
    }

    private func requestPathUpdate(
        scope: PathRelocationScope,
        newLocation: AppPathLocation,
        newCustomPath: String?
    ) {
        let currentLocation: AppPathLocation
        let currentCustomPath: String?
        switch scope {
        case .repositories:
            currentLocation = repositoriesRootLocation
            currentCustomPath = repositoriesRootCustomPath.nonEmpty
        case .worktrees:
            currentLocation = worktreesRootLocation
            currentCustomPath = worktreesRootCustomPath.nonEmpty
        }

        guard let request = appModel.preparePathRelocationRequest(
            scope: scope,
            currentLocation: currentLocation,
            currentCustomPath: currentCustomPath,
            newLocation: newLocation,
            newCustomPath: newCustomPath,
            modelContext: modelContext
        ) else {
            Task {
                await appModel.applyPathRelocationRequest(
                    PathRelocationRequest(
                        scope: scope,
                        oldLocation: currentLocation,
                        oldCustomPath: currentCustomPath,
                        newLocation: newLocation,
                        newCustomPath: newCustomPath,
                        oldRoot: scope == .repositories ? AppPaths.bareRepositoriesRoot : AppPaths.worktreesRoot,
                        newRoot: scope == .repositories ? repositoriesEffectiveRoot : worktreesEffectiveRoot,
                        affectedCount: 0
                    ),
                    moveExistingItems: false,
                    modelContext: modelContext
                )
                syncDraftsFromPreferences()
            }
            return
        }

        if request.affectedCount == 0 {
            Task {
                await appModel.applyPathRelocationRequest(request, moveExistingItems: false, modelContext: modelContext)
                syncDraftsFromPreferences()
            }
            return
        }

        pendingPathRelocationRequest = request
    }
}

private struct PathRelocationDecisionSheet: View {
    let request: PathRelocationRequest
    let moveDisabled: Bool
    let onCancel: () -> Void
    let onKeepExisting: () -> Void
    let onMoveExisting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Move existing \(request.scope.title)?")
                .font(.title2.weight(.semibold))

            Text("The default \(request.scope.singularTitle) path changed. Stackriot can leave existing items where they are, or move everything to the new root one-by-one.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                labeledPath("Current root", request.oldRoot.path)
                labeledPath("New root", request.newRoot.path)
                Text("\(request.affectedCount) existing \(request.scope.title) will be affected.")
                    .font(.subheadline.weight(.medium))
            }

            if moveDisabled {
                Label("Moving is disabled while jobs are running. Wait for the active jobs to finish, or keep the existing items where they are.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Only future \(request.scope.title)") {
                    onKeepExisting()
                }
                Button("Move existing \(request.scope.title)") {
                    onMoveExisting()
                }
                .buttonStyle(.borderedProminent)
                .disabled(moveDisabled)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder
    private func labeledPath(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

private struct PathRelocationProgressOverlay: View {
    let progress: PathRelocationProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("Moving \(progress.scope.title)...")
                    .font(.title3.weight(.semibold))

                TimelineView(.animation(minimumInterval: 0.2)) { context in
                    let phase = Int(context.date.timeIntervalSince(progress.startedAt) * 6) % 8
                    HStack(spacing: 10) {
                        ForEach(0..<8, id: \.self) { index in
                            Image(systemName: index == phase ? "shippingbox.fill" : "shippingbox")
                                .foregroundStyle(index == phase ? .orange : .secondary.opacity(0.35))
                                .offset(y: index == phase ? -4 : 0)
                                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: phase)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                ProgressView(
                    value: Double(progress.completedCount),
                    total: Double(max(progress.totalCount, 1))
                )

                Text(progress.progressLabel)
                    .font(.subheadline.weight(.medium))

                if let currentItemName = progress.currentItemName {
                    Text(currentItemName)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(width: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            )
            .shadow(color: .black.opacity(0.18), radius: 24, y: 16)
        }
    }
}
