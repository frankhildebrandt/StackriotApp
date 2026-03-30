import Foundation
import WebKit

@MainActor
enum EmbeddedBrowserSessionStore {
    static func configuration(for provider: TicketProviderKind) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        _ = provider
        return configuration
    }

    static func applyPreferredUserAgent(to webView: WKWebView) {
        webView.customUserAgent = preferredSafariUserAgent()
    }

    nonisolated static func preferredSafariUserAgent(operatingSystemMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        let safariVersion: String = if operatingSystemMajorVersion >= 15 {
            "18.4"
        } else {
            "17.6"
        }
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }

    static func loginURL(for provider: TicketProviderKind) -> URL {
        switch provider {
        case .github:
            return URL(string: "https://github.com/login")!
        case .jira:
            let configuredBaseURL = AppPreferences.jiraBaseURL
            if let trimmedBaseURL = configuredBaseURL.nilIfBlank,
               let url = URL(string: trimmedBaseURL)
            {
                return url
            }
            return URL(string: "https://id.atlassian.com/login")!
        }
    }

    static func providerDisplayName(_ provider: TicketProviderKind) -> String {
        provider == .github ? "GitHub" : "Jira"
    }

    static func isSessionExpired(for provider: TicketProviderKind, url: URL?) -> Bool {
        guard let url else { return false }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        switch provider {
        case .github:
            return host == "github.com" && (path == "/login" || path.hasPrefix("/session"))
        case .jira:
            return host.contains("atlassian.com") && (path.contains("/login") || path.contains("/signin"))
                || host.hasPrefix("id.atlassian.com")
        }
    }

    static func clearSession(for provider: TicketProviderKind) async {
        let store = WKWebsiteDataStore.default()
        let allDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: allDataTypes) { records in
                continuation.resume(returning: records)
            }
        }
        let relevantRecords = records.filter { record in
            let names = record.displayName.lowercased()
            switch provider {
            case .github:
                return names.contains("github")
            case .jira:
                return names.contains("atlassian") || names.contains("jira")
            }
        }
        guard !relevantRecords.isEmpty else { return }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: allDataTypes, for: relevantRecords) {
                continuation.resume()
            }
        }
    }
}
