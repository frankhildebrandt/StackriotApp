import SwiftData
import SwiftUI

struct NamespaceEditorSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let draft: NamespaceEditorDraft

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.mode == .create ? "Create Namespace" : "Rename Namespace")
                .font(.title2.weight(.semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    appModel.dismissNamespaceEditor()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(draft.mode == .create ? "Create" : "Save") {
                    let namespace = draft.namespaceID.flatMap(appModel.namespaceRecord(with:))
                    appModel.saveNamespace(name: name, editing: namespace, in: modelContext)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .commandEnterAction(disabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    let namespace = draft.namespaceID.flatMap(appModel.namespaceRecord(with:))
                    appModel.saveNamespace(name: name, editing: namespace, in: modelContext)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(.regularMaterial)
        .task(id: draft.id) {
            name = draft.name
        }
    }
}
