import SwiftUI

struct CodexPlanDraftSheet: View {
    @Environment(AppModel.self) private var appModel

    let worktreeID: UUID

    @State private var replyText = ""

    var body: some View {
        Group {
            if let draft = appModel.codexPlanDraft(for: worktreeID) {
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
                    "No Codex Plan Run",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("The transient Codex planning session is no longer available.")
                )
                .frame(minWidth: 640, minHeight: 420)
            }
        }
    }

    private func header(for draft: CodexPlanDraft) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create Plan with Codex")
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
                appModel.cancelCodexPlanDraft(for: draft.worktreeID)
            }
        }
        .padding(20)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func transcript(for draft: CodexPlanDraft) -> some View {
        if let session = appModel.terminalSession(for: draft.run) {
            TerminalSessionView(session: session)
                .id(session.runID)
                .background(.black.opacity(0.92))
        } else {
            TextEditor(text: .constant(draft.run.outputText))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(.black.opacity(0.9))
                .foregroundStyle(.white)
        }
    }

    private func composer(for draft: CodexPlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusMessage(for: draft))
                .font(.caption)
                .foregroundStyle(statusColor(for: draft))

            HStack(alignment: .bottom, spacing: 12) {
                TextField("Reply to Codex…", text: $replyText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(!canSendReply(for: draft))

                Button("Send") {
                    let reply = replyText
                    replyText = ""
                    appModel.sendCodexPlanReply(reply, for: draft.worktreeID)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSendReply(for: draft) || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .background(.regularMaterial)
    }

    private func canSendReply(for draft: CodexPlanDraft) -> Bool {
        appModel.activeRunIDs.contains(draft.runID) && appModel.terminalSession(for: draft.run) != nil
    }

    private func activeButtonTitle(for draft: CodexPlanDraft) -> String {
        canSendReply(for: draft) ? "Cancel" : "Close"
    }

    private func activeButtonRole(for draft: CodexPlanDraft) -> ButtonRole? {
        canSendReply(for: draft) ? .destructive : nil
    }

    private func statusMessage(for draft: CodexPlanDraft) -> String {
        if let importErrorMessage = draft.importErrorMessage?.nonEmpty {
            return "Import failed: \(importErrorMessage)"
        }
        if draft.didImportPlan {
            return "The proposed plan was imported. The sheet will close automatically."
        }
        if canSendReply(for: draft) {
            return "Answer follow-up questions here. Once Codex emits a complete <proposed_plan> block, the worktree plan file is replaced automatically."
        }
        return "No complete <proposed_plan> block was imported. You can close this draft and start a new Codex planning run."
    }

    private func statusColor(for draft: CodexPlanDraft) -> Color {
        if draft.importErrorMessage != nil {
            return .red
        }
        return .secondary
    }
}
