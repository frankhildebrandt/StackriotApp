import SwiftData
import SwiftUI

struct CheckoutPullRequestSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let repository: ManagedRepository

    @State private var searchTask: Task<Void, Never>?
    @State private var isCheckingOut = false

    private var draft: PullRequestCheckoutDraft {
        appModel.pullRequestCheckoutDraft
    }

    private var canCheckout: Bool {
        draft.selectedPullRequest != nil && !isCheckingOut
    }

    var body: some View {
        @Bindable var appModel = appModel
        VStack(alignment: .leading, spacing: 20) {
            Text("Checkout Pull Request")
                .font(.title2.weight(.semibold))

            Text("Check out a GitHub pull request into its own local worktree. The PR becomes the worktree's primary context.")
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("PR # or title", text: $appModel.pullRequestCheckoutDraft.searchText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCheckingOut)

                Button("Search") {
                    triggerSearch()
                }
                .disabled(isCheckingOut || draft.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if draft.isLoading {
                ProgressView("Loading pull requests")
            } else if draft.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Search by PR number or title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if draft.searchResults.isEmpty {
                Text("No pull requests found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(draft.searchResults) { pr in
                            Button {
                                Task {
                                    await appModel.selectPullRequest(pr, for: repository)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("#\(pr.number) \(pr.title)")
                                        .font(.subheadline.weight(.medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(pr.headRefName) -> \(pr.baseRefName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(isCheckingOut)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            if let selected = draft.selectedPullRequest {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Selected PR")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if selected.isDraft {
                            Text("Draft")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }

                    Text("#\(selected.number) \(selected.title)")
                        .font(.headline)
                    Text(selected.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("Head: \(selected.headRefName) -> \(selected.baseRefName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Local branch: \(draft.normalizedBranchName)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCheckingOut)

                Button("Checkout") {
                    isCheckingOut = true
                    Task {
                        await appModel.checkoutSelectedPullRequest(for: repository, in: modelContext)
                        isCheckingOut = false
                        if appModel.pendingErrorMessage == nil {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCheckout)
                .commandEnterAction(disabled: !canCheckout) {
                    isCheckingOut = true
                    Task {
                        await appModel.checkoutSelectedPullRequest(for: repository, in: modelContext)
                        isCheckingOut = false
                        if appModel.pendingErrorMessage == nil {
                            dismiss()
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 720)
        .background(.regularMaterial)
        .onDisappear {
            searchTask?.cancel()
        }
        .onChange(of: appModel.pullRequestCheckoutDraft.searchText) { _, newValue in
            searchTask?.cancel()
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                appModel.pullRequestCheckoutDraft.searchResults = []
                appModel.pullRequestCheckoutDraft.selectedPullRequest = nil
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await appModel.searchPullRequests(for: repository)
            }
        }
    }

    private func triggerSearch() {
        searchTask?.cancel()
        Task {
            await appModel.searchPullRequests(for: repository)
        }
    }
}
