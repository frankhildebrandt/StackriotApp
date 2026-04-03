import SwiftData
import SwiftUI

struct ProjectEditorSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let draft: ProjectEditorDraft

    @State private var name = ""

    var body: some View {
        let namespace = draft.namespaceID.flatMap(appModel.namespaceRecord(with:))

        VStack(alignment: .leading, spacing: 18) {
            Text(draft.mode == .create ? "Create Project" : "Rename Project")
                .font(.title2.weight(.semibold))

            if let namespace {
                Text(namespace.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    appModel.dismissProjectEditor()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(draft.mode == .create ? "Create" : "Save") {
                    guard let namespace else {
                        appModel.pendingErrorMessage = "The selected namespace could not be found."
                        return
                    }
                    let project = draft.projectID.flatMap(appModel.projectRecord(with:))
                    appModel.saveProject(name: name, in: namespace, editing: project, modelContext: modelContext)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || namespace == nil)
                .commandEnterAction(disabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || namespace == nil) {
                    guard let namespace else { return }
                    let project = draft.projectID.flatMap(appModel.projectRecord(with:))
                    appModel.saveProject(name: name, in: namespace, editing: project, modelContext: modelContext)
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
