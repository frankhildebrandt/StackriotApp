import SwiftData
import SwiftUI

struct TerminalTabChip: View {
    let run: RunRecord
    let isSelected: Bool
    let isRunning: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(run.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !isRunning {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minWidth: 140, alignment: .leading)
        .background(isSelected ? Color(nsColor: .underPageBackgroundColor) : Color.clear)
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

