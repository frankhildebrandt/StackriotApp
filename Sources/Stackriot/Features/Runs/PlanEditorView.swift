import Foundation
import SwiftData
import SwiftUI

struct PlanEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let worktree: WorktreeRecord
    let repository: ManagedRepository

    @State private var planText: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var hasLoaded = false

    var body: some View {
        let planContentVersion = appModel.planContentVersion(for: worktree.id)
        VStack(spacing: 0) {
            toolbar
            Divider()
            TextEditor(text: $planText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            if !hasLoaded {
                planText = appModel.loadPlan(for: worktree.id)
                hasLoaded = true
            }
        }
        .onChange(of: worktree.id) { _, _ in
            saveTask?.cancel()
            planText = appModel.loadPlan(for: worktree.id)
        }
        .onChange(of: planText) { _, newValue in
            saveTask?.cancel()
            let id = worktree.id
            saveTask = Task { [weak appModel] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await MainActor.run { appModel?.savePlan(newValue, for: id) }
            }
        }
        .onChange(of: planContentVersion) { _, _ in
            saveTask?.cancel()
            planText = appModel.loadPlan(for: worktree.id)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text("Plan")
                .font(.subheadline.weight(.semibold))
            Spacer()
            createPlanButton
            agentDispatchMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
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
                        appModel.savePlan(planText, for: worktree.id)
                        appModel.startAgentPlanDraft(
                            using: tool,
                            for: worktree,
                            in: repository,
                            currentPlanText: planText,
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
        .help("Interaktiven Planlauf mit einem unterstützten Agenten starten")
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
        .disabled(agents.isEmpty || planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Plan mit AI-Agent ausführen")
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
