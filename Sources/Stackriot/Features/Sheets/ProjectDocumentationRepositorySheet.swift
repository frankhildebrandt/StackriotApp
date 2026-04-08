import SwiftData
import SwiftUI

struct ProjectDocumentationRepositorySheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let draft: ProjectDocumentationSourceDraft

    @State private var isSaving = false

    private var project: RepositoryProject? {
        appModel.projectRecord(with: draft.projectID)
    }

    private var canSubmit: Bool {
        guard !isSaving else { return false }
        guard let activeDraft = appModel.projectDocumentationSourceDraft else { return false }

        switch activeDraft.mode {
        case .existingRemote:
            return !activeDraft.remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .automaticRepository:
            return !activeDraft.repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        @Bindable var appModel = appModel
        let activeDraft = appModel.projectDocumentationSourceDraft ?? draft
        let draftBinding = $appModel.projectDocumentationSourceDraft.withDefaultValue(draft)

        VStack(alignment: .leading, spacing: 18) {
            Text(project?.documentationRepository == nil ? "Dokumentationsquelle einrichten" : "Dokumentationsquelle verwalten")
                .font(.title2.weight(.semibold))

            if let project {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.headline)
                    Text(project.namespace?.name ?? "Ohne Namespace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Modus", selection: draftBinding.mode) {
                ForEach(ProjectDocumentationSourceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSaving)

            Group {
                switch activeDraft.mode {
                case .existingRemote:
                    TextField("Remote URL", text: draftBinding.remoteURLString)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSaving)

                    TextField("Anzeigename (optional)", text: draftBinding.displayName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSaving)

                    Text("Kloniert ein bestehendes Dokumentations-Repository oder verknuepft ein bereits von Stackriot verwaltetes Remote.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .automaticRepository:
                    TextField("Repository-Name", text: draftBinding.repositoryName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSaving)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Initiale Struktur")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("README.md, market-data/, archive/intents/, archive/plans/ und archive/worktrees/ werden vorbereitet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isSaving {
                ProgressView("Dokumentationsquelle wird eingerichtet…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Abbrechen") {
                    appModel.dismissProjectDocumentationSourceEditor()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Button(project?.documentationRepository == nil ? "Einrichten" : "Speichern") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .commandEnterAction(disabled: !canSubmit) {
                    submit()
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(.regularMaterial)
        .task(id: draft.id) {
            if appModel.projectDocumentationSourceDraft == nil {
                appModel.projectDocumentationSourceDraft = draft
            }
        }
        .onChange(of: appModel.projectDocumentationSourceDraft == nil) { _, isNil in
            if isNil {
                dismiss()
            }
        }
    }

    private func submit() {
        isSaving = true
        Task {
            await appModel.saveProjectDocumentationSource(in: modelContext)
            isSaving = false
            if appModel.pendingErrorMessage == nil {
                dismiss()
            }
        }
    }
}

private extension Binding where Value == ProjectDocumentationSourceDraft? {
    func withDefaultValue(_ fallback: ProjectDocumentationSourceDraft) -> Binding<ProjectDocumentationSourceDraft> {
        Binding<ProjectDocumentationSourceDraft>(
            get: { wrappedValue ?? fallback },
            set: { wrappedValue = $0 }
        )
    }
}
