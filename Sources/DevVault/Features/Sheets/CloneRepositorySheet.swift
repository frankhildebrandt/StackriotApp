import SwiftData
import SwiftUI

struct CloneRepositorySheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 18) {
            Text("Clone Bare Repository")
                .font(.title2.weight(.semibold))

            TextField("Remote URL", text: $appModel.cloneDraft.remoteURLString)
                .textFieldStyle(.roundedBorder)
            TextField("Display Name (optional)", text: $appModel.cloneDraft.displayName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Clone") {
                    Task {
                        await appModel.cloneRepository(in: modelContext)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.cloneDraft.remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(.regularMaterial)
    }
}
