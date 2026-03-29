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
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text("Plan")
                .font(.subheadline.weight(.semibold))
            Spacer()
            agentDispatchMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
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

    // MARK: - Helpers

    private var availableAgents: [AIAgentTool] {
        AIAgentTool.allCases.filter { $0 != .none && appModel.availableAgents.contains($0) }
    }
}
