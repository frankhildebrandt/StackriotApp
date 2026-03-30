import SwiftUI

struct AgentPlanDraftSheet: View {
    @Environment(AppModel.self) private var appModel

    let worktreeID: UUID

    @State private var replyText = ""

    var body: some View {
        Group {
            if let draft = appModel.agentPlanDraft(for: worktreeID) {
                VStack(spacing: 0) {
                    header(for: draft)
                    Divider()
                    transcript(for: draft)
                    Divider()
                    composer(for: draft)
                }
                .frame(minWidth: 780, minHeight: 560)
            } else {
                ContentUnavailableView(
                    "No Planning Run",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("The transient planning session is no longer available.")
                )
                .frame(minWidth: 640, minHeight: 420)
            }
        }
    }

    private func header(for draft: AgentPlanDraft) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create Plan with \(draft.tool.displayName)")
                    .font(.title3.weight(.semibold))
                Text(draft.branchName)
                    .font(.subheadline.weight(.medium))
                Text(draft.issueContext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(activeButtonTitle(for: draft), role: activeButtonRole(for: draft)) {
                appModel.cancelAgentPlanDraft(for: draft.worktreeID)
            }
        }
        .padding(20)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func transcript(for draft: AgentPlanDraft) -> some View {
        if draft.run.outputInterpreter != nil {
            AgentRunFeedView(run: draft.run)
        } else {
            TextEditor(text: .constant(draft.run.outputText))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(.black.opacity(0.9))
                .foregroundStyle(.white)
        }
    }

    private func composer(for draft: AgentPlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusMessage(for: draft))
                .font(.caption)
                .foregroundStyle(statusColor(for: draft))

            if let summary = draft.latestSummary?.nonEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            if !draft.latestQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(draft.latestQuestions.enumerated()), id: \.offset) { index, question in
                        Text("\(index + 1). \(question)")
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField("Reply to \(draft.tool.displayName)…", text: $replyText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(!canSendReply(for: draft))

                Button("Send") {
                    let reply = replyText
                    replyText = ""
                    appModel.sendAgentPlanReply(reply, for: draft.worktreeID)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSendReply(for: draft) || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .background(.regularMaterial)
    }

    private func canSendReply(for draft: AgentPlanDraft) -> Bool {
        draft.tool.supportsPlanResume
            && !appModel.activeRunIDs.contains(draft.runID)
            && draft.sessionID?.isEmpty == false
            && !draft.latestQuestions.isEmpty
    }

    private func activeButtonTitle(for draft: AgentPlanDraft) -> String {
        appModel.activeRunIDs.contains(draft.runID) ? "Cancel" : "Close"
    }

    private func activeButtonRole(for draft: AgentPlanDraft) -> ButtonRole? {
        appModel.activeRunIDs.contains(draft.runID) ? .destructive : nil
    }

    private func statusMessage(for draft: AgentPlanDraft) -> String {
        if let importErrorMessage = draft.importErrorMessage?.nonEmpty {
            return "Import failed: \(importErrorMessage)"
        }
        if draft.didImportPlan {
            return "The proposed plan was imported. The sheet will close automatically."
        }
        if appModel.activeRunIDs.contains(draft.runID) {
            return "\(draft.tool.displayName) is inspecting the worktree and preparing the next planning response."
        }
        if canSendReply(for: draft) {
            return "Answer the follow-up questions here. After your reply, Stackriot resumes the same \(draft.tool.displayName) session and replaces the worktree plan as soon as the final plan returns."
        }
        return "No final plan was imported. You can close this draft and start a new planning run."
    }

    private func statusColor(for draft: AgentPlanDraft) -> Color {
        if draft.importErrorMessage != nil {
            return .red
        }
        return .secondary
    }
}
