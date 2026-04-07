import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct CloneRepositorySheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false
    @State private var isArchiveImporterPresented = false

    private var trimmedRemoteURL: String {
        appModel.repositoryCreationDraft.remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDisplayName: String {
        appModel.repositoryCreationDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNPXCommand: String {
        appModel.repositoryCreationDraft.npxCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReadmePrompt: String {
        appModel.repositoryCreationDraft.readmePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        let draft = appModel.repositoryCreationDraft
        guard !isCreating else { return false }

        switch draft.mode {
        case .cloneRemote:
            return !trimmedRemoteURL.isEmpty
        case .npxTemplate:
            return !trimmedDisplayName.isEmpty && !trimmedNPXCommand.isEmpty
        case .aiReadme:
            return !trimmedDisplayName.isEmpty && !trimmedReadmePrompt.isEmpty
        case .archiveImport:
            return !trimmedDisplayName.isEmpty && draft.archiveFileURL != nil
        }
    }

    var body: some View {
        @Bindable var appModel = appModel
        let mode = appModel.repositoryCreationDraft.mode

        VStack(alignment: .leading, spacing: 18) {
            Text("Create Repository")
                .font(.title2.weight(.semibold))

            Picker("Mode", selection: $appModel.repositoryCreationDraft.mode) {
                ForEach(RepositoryCreationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isCreating)

            Text(mode.formDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Group {
                switch mode {
                case .cloneRemote:
                    TextField("Remote URL", text: $appModel.repositoryCreationDraft.remoteURLString)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCreating)

                    TextField("Display Name (optional)", text: $appModel.repositoryCreationDraft.displayName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCreating)
                case .npxTemplate:
                    TextField("Repository Name", text: $appModel.repositoryCreationDraft.displayName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCreating)

                    TextField("NPX Command", text: $appModel.repositoryCreationDraft.npxCommand)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCreating)

                    Text("Nutze idealerweise ein Kommando, das in das aktuelle Verzeichnis scaffoldet, z. B. `npx create-next-app@latest .`.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .aiReadme:
                    TextField("Repository Name", text: $appModel.repositoryCreationDraft.displayName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCreating)

                    TextEditor(text: $appModel.repositoryCreationDraft.readmePrompt)
                        .frame(minHeight: 150)
                        .padding(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                        .disabled(isCreating)
                case .archiveImport:
                    TextField("Repository Name", text: $appModel.repositoryCreationDraft.displayName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isCreating)

                    HStack {
                        Button("Choose Archive…") {
                            isArchiveImporterPresented = true
                        }
                        .disabled(isCreating)

                        Text(appModel.repositoryCreationDraft.archiveFileURL?.lastPathComponent ?? "No archive selected")
                            .foregroundStyle(appModel.repositoryCreationDraft.archiveFileURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text("Unterstützt ZIP sowie Tar-Archive wie .tar, .tar.gz oder .tgz.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isCreating {
                ProgressView(mode.progressTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isCreating)

                Button(mode.primaryActionTitle) {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .commandEnterAction(disabled: !canSubmit) { submit() }
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(.regularMaterial)
        .fileImporter(
            isPresented: $isArchiveImporterPresented,
            allowedContentTypes: [.item, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                appModel.repositoryCreationDraft.archiveFileURL = urls.first
            case let .failure(error):
                appModel.pendingErrorMessage = error.localizedDescription
            }
        }
    }

    private func submit() {
        isCreating = true
        Task {
            await appModel.createRepository(in: modelContext)
            isCreating = false
            if appModel.pendingErrorMessage == nil {
                dismiss()
            }
        }
    }
}
