import SwiftData
import SwiftUI

struct CloneRepositorySheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var isCloning = false

    private var trimmedRemoteURL: String {
        appModel.cloneDraft.remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canClone: Bool {
        !trimmedRemoteURL.isEmpty && !isCloning
    }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 18) {
            Text("Clone Bare Repository")
                .font(.title2.weight(.semibold))

            TextField("Remote URL", text: $appModel.cloneDraft.remoteURLString)
                .textFieldStyle(.roundedBorder)
                .disabled(isCloning)
            TextField("Display Name (optional)", text: $appModel.cloneDraft.displayName)
                .textFieldStyle(.roundedBorder)
                .disabled(isCloning)

            if isCloning {
                ProgressView("Repository wird geklont und vorbereitet…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isCloning)
                Button("Clone") {
                    startClone()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canClone)
                .commandEnterAction(disabled: !canClone) { startClone() }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(.regularMaterial)
    }

    private func startClone() {
        isCloning = true
        Task {
            await appModel.cloneRepository(in: modelContext)
            isCloning = false
            if appModel.pendingErrorMessage == nil {
                dismiss()
            }
        }
    }
}
