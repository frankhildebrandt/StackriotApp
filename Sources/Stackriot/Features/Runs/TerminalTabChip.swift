import SwiftData
import SwiftUI

struct TerminalTabChip: View {
    let run: RunRecord
    let isSelected: Bool
    let isRunning: Bool
    let usesCloseActionWhileRunning: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCancel: () -> Void

    @State private var isHoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }

            Text(run.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if isRunning, !usesCloseActionWhileRunning {
                    onCancel()
                } else {
                    onClose()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(
                        Circle()
                            .fill(isHoveringClose ? Color.primary.opacity(0.15) : Color.clear)
                    )
                    .foregroundStyle(isHoveringClose ? Color.primary : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringClose = $0 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 160, alignment: .leading)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 5,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 5
            )
            .fill(isSelected ? Color(nsColor: .underPageBackgroundColor) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .frame(height: isSelected ? 2 : 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }

    private var statusColor: Color {
        switch run.status {
        case .pending, .running:
            .orange
        case .succeeded:
            .green
        case .failed:
            .red
        case .cancelled:
            .gray
        }
    }
}
