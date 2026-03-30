import Foundation

struct JiraCloudService: TicketProviderService {
    typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let kind: TicketProviderKind = .jira

    private let configurationProvider: @Sendable () -> JiraConfiguration
    private let performRequest: RequestExecutor

    init(
        configurationProvider: @escaping @Sendable () -> JiraConfiguration = { AppPreferences.jiraConfiguration },
        performRequest: @escaping RequestExecutor = JiraCloudService.liveRequest
    ) {
        self.configurationProvider = configurationProvider
        self.performRequest = performRequest
    }

    @MainActor
    func readiness(for _: ManagedRepository) async -> TicketProviderStatus {
        let configuration = configurationProvider()
        guard configuration.trimmedBaseURL.nonEmpty != nil else {
            return TicketProviderStatus(
                provider: .jira,
                isAvailable: false,
                message: "Jira Cloud ist noch nicht konfiguriert. Bitte Base URL, Atlassian-E-Mail und API-Token in den Einstellungen hinterlegen."
            )
        }
        guard configuration.trimmedUserEmail.nonEmpty != nil else {
            return TicketProviderStatus(
                provider: .jira,
                isAvailable: false,
                message: "Fuer Jira Cloud fehlt die Atlassian-Account-E-Mail in den Einstellungen."
            )
        }
        guard configuration.apiToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil else {
            return TicketProviderStatus(
                provider: .jira,
                isAvailable: false,
                message: "Fuer Jira Cloud fehlt das API-Token in den Einstellungen."
            )
        }

        do {
            _ = try await request(path: "/rest/api/3/myself", configuration: configuration)
            return TicketProviderStatus(
                provider: .jira,
                isAvailable: true,
                message: "Jira Cloud ist verbunden und kann fuer Ticket-Suche und Plan-Kontext verwendet werden."
            )
        } catch {
            return TicketProviderStatus(
                provider: .jira,
                isAvailable: false,
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    func searchTickets(query: String, in _: ManagedRepository) async throws -> [TicketSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let configuration = configurationProvider()
        let jql = Self.searchJQL(for: trimmedQuery)
        let data = try await request(
            path: "/rest/api/3/search",
            queryItems: [
                URLQueryItem(name: "jql", value: jql),
                URLQueryItem(name: "maxResults", value: "20"),
                URLQueryItem(name: "fields", value: "summary,status"),
            ],
            configuration: configuration
        )
        return try decodeSearchResults(from: data, baseURL: configuration.trimmedBaseURL)
    }

    @MainActor
    func loadTicket(id: String, in _: ManagedRepository) async throws -> TicketDetails {
        let configuration = configurationProvider()
        let data = try await request(
            path: "/rest/api/3/issue/\(id)",
            queryItems: [
                URLQueryItem(name: "fields", value: "summary,description,status,comment,labels"),
            ],
            configuration: configuration
        )
        return try decodeTicketDetails(from: data, baseURL: configuration.trimmedBaseURL)
    }

    func decodeSearchResults(from data: Data, baseURL: String) throws -> [TicketSearchResult] {
        let decoded = try Self.jsonDecoder.decode(SearchResponsePayload.self, from: data)
        return decoded.issues.map { issue in
            TicketSearchResult(
                reference: TicketReference(provider: .jira, id: issue.key, displayID: issue.key),
                title: issue.fields.summary,
                url: Self.browseURL(baseURL: baseURL, ticketID: issue.key),
                status: issue.fields.status.name
            )
        }
    }

    func decodeTicketDetails(from data: Data, baseURL: String) throws -> TicketDetails {
        let decoded = try Self.jsonDecoder.decode(IssuePayload.self, from: data)
        return TicketDetails(
            reference: TicketReference(provider: .jira, id: decoded.key, displayID: decoded.key),
            title: decoded.fields.summary,
            body: Self.plainText(from: decoded.fields.description),
            url: Self.browseURL(baseURL: baseURL, ticketID: decoded.key),
            labels: decoded.fields.labels,
            comments: decoded.fields.comment.comments.map { comment in
                TicketComment(
                    author: comment.author.displayName?.nilIfBlank ?? comment.author.accountID ?? "unknown",
                    body: Self.plainText(from: comment.body),
                    createdAt: comment.created,
                    url: nil
                )
            }
        )
    }

    private static func liveRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }

    private func request(
        path: String,
        queryItems: [URLQueryItem] = [],
        configuration: JiraConfiguration
    ) async throws -> Data {
        let request = try Self.makeRequest(path: path, queryItems: queryItems, configuration: configuration)
        let (data, response) = try await performRequest(request)
        try Self.ensureSuccess(response: response, data: data)
        return data
    }

    private static func makeRequest(
        path: String,
        queryItems: [URLQueryItem],
        configuration: JiraConfiguration
    ) throws -> URLRequest {
        guard let baseURL = URL(string: configuration.trimmedBaseURL) else {
            throw StackriotError.commandFailed("Jira Base URL ist ungueltig.")
        }
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: baseURL.appendingPathComponent(normalizedPath), resolvingAgainstBaseURL: false) else {
            throw StackriotError.commandFailed("Jira Base URL ist ungueltig.")
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw StackriotError.commandFailed("Jira Request-URL konnte nicht erstellt werden.")
        }
        guard let token = configuration.apiToken else {
            throw StackriotError.commandFailed("Jira API-Token fehlt.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let credentials = "\(configuration.trimmedUserEmail):\(token)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func ensureSuccess(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = jiraErrorMessage(from: data)
            switch httpResponse.statusCode {
            case 401:
                throw StackriotError.commandFailed(message ?? "Jira-Authentifizierung fehlgeschlagen. Bitte E-Mail und API-Token pruefen.")
            case 403:
                throw StackriotError.commandFailed(message ?? "Jira-Zugriff verweigert. Bitte Berechtigungen fuer dieses Konto pruefen.")
            default:
                throw StackriotError.commandFailed(message ?? "Jira-Request fehlgeschlagen (HTTP \(httpResponse.statusCode)).")
            }
        }
    }

    private static func jiraErrorMessage(from data: Data) -> String? {
        if let decoded = try? jsonDecoder.decode(ErrorPayload.self, from: data) {
            let combined = ([decoded.errorMessages] + decoded.errors.values.map { [$0] })
                .flatMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return combined.nonEmpty
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private static func browseURL(baseURL: String, ticketID: String) -> String {
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return "\(trimmedBase)/browse/\(ticketID)"
    }

    private static func searchJQL(for query: String) -> String {
        let escaped = query.replacingOccurrences(of: "\"", with: "\\\"")
        if escaped.range(of: #"^[A-Za-z][A-Za-z0-9]+-\d+$"#, options: .regularExpression) != nil {
            return #"key = "\#(escaped)" ORDER BY updated DESC"#
        }
        return #"summary ~ "\#(escaped)" ORDER BY updated DESC"#
    }

    private static func plainText(from document: RichTextDocument?) -> String {
        let value = document?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value
    }

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct SearchResponsePayload: Decodable {
    let issues: [IssueSummaryPayload]
}

private struct IssueSummaryPayload: Decodable {
    struct FieldsPayload: Decodable {
        struct StatusPayload: Decodable {
            let name: String
        }

        let summary: String
        let status: StatusPayload
    }

    let key: String
    let fields: FieldsPayload
}

private struct IssuePayload: Decodable {
    struct FieldsPayload: Decodable {
        struct CommentContainerPayload: Decodable {
            struct CommentPayload: Decodable {
                struct AuthorPayload: Decodable {
                    let displayName: String?
                    let accountID: String?

                    enum CodingKeys: String, CodingKey {
                        case displayName
                        case accountID = "accountId"
                    }
                }

                let author: AuthorPayload
                let body: RichTextDocument?
                let created: Date
            }

            let comments: [CommentPayload]
        }

        let summary: String
        let description: RichTextDocument?
        let labels: [String]
        let comment: CommentContainerPayload
    }

    let key: String
    let fields: FieldsPayload
}

private struct ErrorPayload: Decodable {
    let errorMessages: [String]
    let errors: [String: String]
}

private struct RichTextDocument: Decodable {
    struct Node: Decodable {
        struct Attributes: Decodable {
            let text: String?
        }

        let type: String?
        let text: String?
        let attrs: Attributes?
        let content: [Node]?

        var plainText: String {
            if let text {
                return text
            }
            if let attrsText = attrs?.text {
                return attrsText
            }

            let joined = (content ?? []).map(\.plainText).joined()
            switch type {
            case "hardBreak":
                return "\n"
            case "paragraph", "heading", "blockquote", "listItem":
                return joined + "\n"
            case "bulletList", "orderedList":
                return joined + "\n"
            default:
                return joined
            }
        }
    }

    let content: [Node]?

    var plainText: String {
        (content ?? []).map(\.plainText).joined()
    }
}
