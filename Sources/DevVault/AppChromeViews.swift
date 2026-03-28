import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("App") {
                LabeledContent("Mode", value: "Dock app")
                LabeledContent("Platform", value: "macOS")
                LabeledContent("Workflow", value: "Bare repos + worktrees")
            }

            Section("Current V1 Scope") {
                Text("DevVault manages bare repositories, creates worktrees, launches editors, and runs typed project actions from a single desktop app.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(minWidth: 520, minHeight: 320)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("DevVault")
                    .font(.largeTitle.weight(.semibold))
                Text("Repository orchestration for focused local development")
                    .foregroundStyle(.secondary)
            }

            Text("Bare repositories, worktrees, editor launchers, and structured local task execution in one macOS app.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 280)
        .background(.regularMaterial)
    }
}
