import SwiftUI

struct AgentRunSummaryWindow: View {
    let run: RunRecord
    let isSummarizing: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.aiSummaryTitle ?? "Agent-Zusammenfassung")
                        .font(.title3.weight(.semibold))
                    Text(run.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(run.commandLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Label("Schliessen", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }

            Divider()

            if isSummarizing {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView()
                    Text("Die AI fasst den Agent-Output gerade zusammen…")
                        .foregroundStyle(.secondary)
                }
            } else if let summary = run.aiSummaryText?.nonEmpty {
                ScrollView {
                    Text(summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                Text("Noch keine Zusammenfassung verfuegbar.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.bottom, 12)
    }
}
