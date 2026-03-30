import AppKit
import SwiftUI
import WebKit

struct WorktreePrimaryContextView: View {
    @Environment(AppModel.self) private var appModel

    let worktree: WorktreeRecord
    let repository: ManagedRepository

    @State private var authProvider: TicketProviderKind?

    var body: some View {
        Group {
            switch worktree.primaryContextTabKind {
            case .readme:
                ReadmeView(worktreePath: worktree.path)
            case .plan:
                primaryPaneContent(browserAvailable: false)
            case .browser:
                primaryPaneContent(browserAvailable: worktree.resolvedPrimaryContext != nil)
            }
        }
        .sheet(item: $authProvider) { provider in
            EmbeddedBrowserAuthenticationSheet(provider: provider)
        }
    }

    @ViewBuilder
    private func primaryPaneContent(browserAvailable: Bool) -> some View {
        let pane = appModel.primaryPane(for: worktree)
        switch pane {
        case .intent:
            PlanEditorView(role: .intent, worktree: worktree, repository: repository)
        case .implementationPlan:
            PlanEditorView(role: .implementationPlan, worktree: worktree, repository: repository)
        case .browser:
            if browserAvailable, let context = worktree.resolvedPrimaryContext {
                EmbeddedBrowserPageView(
                    context: context,
                    onReauthenticate: { authProvider = context.provider }
                )
            } else {
                PlanEditorView(role: .intent, worktree: worktree, repository: repository)
            }
        }
    }
}

struct EmbeddedBrowserAuthenticationSheet: View {
    let provider: TicketProviderKind

    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(EmbeddedBrowserSessionStore.providerDisplayName(provider)) Browser Session")
                    .font(.title3.weight(.semibold))
                Text("Sign in here to create or refresh the persistent embedded-browser session used by PR and ticket worktrees.")
                    .foregroundStyle(.secondary)
            }

            EmbeddedBrowserPageView(
                context: WorktreePrimaryContext(
                    kind: .ticket,
                    canonicalURL: EmbeddedBrowserSessionStore.loginURL(for: provider).absoluteString,
                    title: "\(EmbeddedBrowserSessionStore.providerDisplayName(provider)) Login",
                    label: EmbeddedBrowserSessionStore.providerDisplayName(provider),
                    provider: provider,
                    prNumber: nil,
                    ticketID: nil,
                    upstreamReference: nil,
                    upstreamSHA: nil
                ),
                onReauthenticate: {}
            )
            .id(reloadToken)
            .frame(minHeight: 500)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Button("Clear Session", role: .destructive) {
                    Task {
                        await EmbeddedBrowserSessionStore.clearSession(for: provider)
                        reloadToken = UUID()
                    }
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 920, height: 700)
        .background(.regularMaterial)
    }
}

private struct EmbeddedBrowserPageView: View {
    let context: WorktreePrimaryContext
    let onReauthenticate: () -> Void

    @State private var currentURL: URL?
    @State private var pageTitle = ""
    @State private var isLoading = false
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var reloadToken = UUID()
    @State private var returnToken = UUID()
    @State private var goBackToken = UUID()
    @State private var goForwardToken = UUID()

    private var canonicalURL: URL? {
        URL(string: context.canonicalURL)
    }

    private var displayTitle: String {
        pageTitle.nilIfBlank ?? context.title
    }

    private var shouldShowReturnButton: Bool {
        guard let canonicalURL, let currentURL else { return false }
        return normalizedURL(currentURL) != normalizedURL(canonicalURL)
    }

    private var sessionExpired: Bool {
        EmbeddedBrowserSessionStore.isSessionExpired(for: context.provider, url: currentURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(context.label, systemImage: iconName)
                    .font(.subheadline.weight(.semibold))
                Text(displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if shouldShowReturnButton {
                    Button(context.returnButtonTitle) {
                        returnToken = UUID()
                    }
                }
                if sessionExpired {
                    Button("Re-Auth") {
                        onReauthenticate()
                    }
                }
                Button {
                    reloadToken = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Button {
                    goBackToken = UUID()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(!canGoBack)
                Button {
                    goForwardToken = UUID()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(!canGoForward)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial)

            Divider()

            EmbeddedBrowserWebView(
                provider: context.provider,
                initialURL: canonicalURL,
                currentURL: $currentURL,
                pageTitle: $pageTitle,
                isLoading: $isLoading,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                reloadToken: reloadToken,
                returnToken: returnToken,
                goBackToken: goBackToken,
                goForwardToken: goForwardToken,
                canonicalURL: canonicalURL
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var iconName: String {
        switch context.kind {
        case .pullRequest:
            "arrow.triangle.merge"
        case .ticket:
            context.provider == .github ? "number.square" : "link"
        }
    }

    private func normalizedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}

private struct EmbeddedBrowserWebView: NSViewRepresentable {
    let provider: TicketProviderKind
    let initialURL: URL?
    @Binding var currentURL: URL?
    @Binding var pageTitle: String
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    let reloadToken: UUID
    let returnToken: UUID
    let goBackToken: UUID
    let goForwardToken: UUID
    let canonicalURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: EmbeddedBrowserSessionStore.configuration(for: provider))
        EmbeddedBrowserSessionStore.applyPreferredUserAgent(to: webView)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView)
        if let initialURL {
            webView.load(URLRequest(url: initialURL))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
        if context.coordinator.lastReturnToken != returnToken {
            context.coordinator.lastReturnToken = returnToken
            if let canonicalURL {
                webView.load(URLRequest(url: canonicalURL))
            }
        }
        if context.coordinator.lastGoBackToken != goBackToken {
            context.coordinator.lastGoBackToken = goBackToken
            if webView.canGoBack {
                webView.goBack()
            }
        }
        if context.coordinator.lastGoForwardToken != goForwardToken {
            context.coordinator.lastGoForwardToken = goForwardToken
            if webView.canGoForward {
                webView.goForward()
            }
        }
        context.coordinator.updateState(for: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: EmbeddedBrowserWebView
        private weak var webView: WKWebView?
        var lastReloadToken = UUID()
        var lastReturnToken = UUID()
        var lastGoBackToken = UUID()
        var lastGoForwardToken = UUID()

        init(parent: EmbeddedBrowserWebView) {
            self.parent = parent
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func updateState(for webView: WKWebView) {
            parent.currentURL = webView.url
            parent.pageTitle = webView.title ?? ""
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            parent.isLoading = true
            updateState(for: webView)
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            parent.isLoading = false
            updateState(for: webView)
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            parent.isLoading = false
            updateState(for: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            parent.isLoading = false
            updateState(for: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .cancel
            }
            defer { updateState(for: webView) }
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return .allow
            }
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}
