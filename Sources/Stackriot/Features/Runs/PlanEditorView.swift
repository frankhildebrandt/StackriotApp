import Foundation
import SwiftData
import SwiftUI

struct PlanEditorView: View {
    enum Role {
        case intent
        case implementationPlan
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let role: Role
    let worktree: WorktreeRecord
    let repository: ManagedRepository

    @State private var bodyText: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var hasLoaded = false

    var body: some View {
        let contentVersion = role == .intent
            ? appModel.intentContentVersion(for: worktree.id)
            : appModel.implementationPlanContentVersion(for: worktree.id)
        VStack(spacing: 0) {
            toolbar
            Divider()
            TextEditor(text: $bodyText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            if !hasLoaded {
                bodyText = loadFromDisk()
                hasLoaded = true
            }
        }
        .onChange(of: worktree.id) { _, _ in
            saveTask?.cancel()
            bodyText = loadFromDisk()
        }
        .onChange(of: bodyText) { _, newValue in
            saveTask?.cancel()
            let id = worktree.id
            saveTask = Task { [weak appModel] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    switch role {
                    case .intent:
                        appModel?.saveIntent(newValue, for: id)
                    case .implementationPlan:
                        appModel?.saveImplementationPlan(newValue, for: id)
                    }
                }
            }
        }
        .onChange(of: contentVersion) { _, _ in
            saveTask?.cancel()
            bodyText = loadFromDisk()
        }
    }

    private func loadFromDisk() -> String {
        switch role {
        case .intent:
            appModel.loadIntent(for: worktree.id)
        case .implementationPlan:
            appModel.loadImplementationPlan(for: worktree.id)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: toolbarIcon)
                .foregroundStyle(.secondary)
            Text(toolbarTitle)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if role == .intent {
                createPlanButton
            }
            agentDispatchMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var toolbarIcon: String {
        switch role {
        case .intent:
            "text.alignleft"
        case .implementationPlan:
            "doc.text"
        }
    }

    private var toolbarTitle: String {
        switch role {
        case .intent:
            "Intent"
        case .implementationPlan:
            "Implementation Plan"
        }
    }

    private var createPlanButton: some View {
        let planningAgents = availablePlanningAgents
        return Menu {
            if planningAgents.isEmpty {
                Text("No planning agents installed")
            } else {
                ForEach(planningAgents) { tool in
                    Button {
                        saveTask?.cancel()
                        appModel.saveIntent(bodyText, for: worktree.id)
                        appModel.startAgentPlanDraft(
                            using: tool,
                            for: worktree,
                            in: repository,
                            currentIntentText: bodyText,
                            modelContext: modelContext
                        )
                    } label: {
                        Label(tool.displayName, systemImage: tool.systemImageName)
                    }
                }
            }
        } label: {
            Label("Create Plan with…", systemImage: "sparkles.rectangle.stack")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canCreatePlan)
        .help("Interaktiven Planlauf mit einem unterstützten Agenten starten (Intent als Eingabe)")
    }

    private var agentDispatchMenu: some View {
        let agents = availableAgents
        return Menu {
            if agents.isEmpty {
                Text("No agents installed")
            } else {
                ForEach(agents) { tool in
                    Button("Execute with \(tool.displayName)") {
                        appModel.launchAgentWithPlan(tool, for: worktree, in: modelContext)
                    }
                }
            }
        } label: {
            Label("Execute with Agent", systemImage: "sparkles")
        }
        .disabled(agents.isEmpty || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help(executeHelp)
    }

    private var executeHelp: String {
        switch role {
        case .intent:
            "Intent mit AI-Agent ausführen"
        case .implementationPlan:
            "Implementierungsplan mit AI-Agent ausführen"
        }
    }

    private var availableAgents: [AIAgentTool] {
        appModel.installedAgentTools()
    }

    private var availablePlanningAgents: [AIAgentTool] {
        appModel.availablePlanningAgents()
    }

    private var canCreatePlan: Bool {
        !worktree.isDefaultBranchWorkspace && !availablePlanningAgents.isEmpty
    }
}
