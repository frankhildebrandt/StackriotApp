import Foundation

/// Service fuer GitHub CLI (`gh`)  Issue-Lesen, PR erstellen und Status abrufen.Operationen 
struct GitHubCLIService: TicketProviderService {
    typealias CommandExecutor = @Sendable (_ executable: String, _ arguments: [String], _ currentDirectoryURL: URL?, _ environment: [String: String]) async throws -> CommandResult
    typealias EnvironmentProvider = @Sendable () async -> [String: String]

    let kind: TicketProviderKind = .github

    struct PRInfo: Sendable {
        let number: Int
        let url: String
    }

    enum PRStatus: String, Sendable, Equatable {
        case open
        case merged
        case closed
    }

    private let runCommand: CommandExecutor
    private let environmentProvider: EnvironmentProvider

    init(
        runCommand: @escaping CommandExecutor = GitHubCLIService.liveCommand,
        environmentProvider: @escaping EnvironmentProvider = GitHubCLIService.liveEnvironment
    ) {
        self.runCommand = runCommand
        self.environmentProvider = environmentProvider
    }

    // MARK: - Availability

    /// `true` wenn `gh` CLI im PATH vorhanden ist.
    func isGHAvailable() async -> Bool {
        do {
            let result = try await runCommand("which", ["gh"], nil, await commandEnvironment())
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    /// `true` wenn `gh auth status` erfolgreich ist (User ist eingeloggt).
    func isAuthenticated() async -> Bool {
        do {
            let result = try await runCommand("gh", ["auth", "status"], nil, await commandEnvironment())
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    @MainActor
    func readiness(for repository: ManagedRepository) async -> TicketProviderStatus {
        guard repositoryTarget(for: repository) != nil else {
            return TicketProviderStatus(
                provider: .github,
                isAvailable: false,
                message: "GitHub-Issues sind nur fuer Repositories mit GitHub-Remote verfuegbar."
            )
        }

        guard await isGHAvailable() else {
            return TicketProviderStatus(
                provider: .github,
                isAvailable: false,
                message: "`gh` CLI nicht gefunden. Installiere die GitHub CLI fuer die Ticket-Auswahl."
            )
        }

        guard await isAuthenticated() else {
            return TicketProviderStatus(
                provider: .github,
                isAvailable: false,
                message: "`gh auth status` ist nicht erfolgreich. Bitte authentifiziere die GitHub CLI."
            )
        }

        return TicketProviderStatus(
            provider: .github,
            isAvailable: true,
            message: "GitHub-Issues koennen fuer dieses Repository durchsucht werden."
        )
    }

    @MainActor
    func issueReadiness(for repository: ManagedRepository) async -> TicketProviderStatus {
        await readiness(for: repository)
    }

    // MARK: - Remote Check

    /// Gibt zurueck, ob die Remote-URL zu GitHub gehoert.
    static func isGitHubRemote(url: String) -> Bool {
        url.localizedCaseInsensitiveContains("github.com")
    }

    // MARK: - Issue Operations

    @MainActor
    func searchTickets(query: String, in repository: ManagedRepository) async throws -> [TicketSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let target = try repositoryTargetOrThrow(for: repository)
        let environment = await commandEnvironment()
        var results: [TicketSearchResult] = []

        if let issueNumber = Self.issueNumber(from: trimmedQuery),
           let exactMatch = try await loadTicketSearchResult(number: issueNumber, repositoryTarget: target, environment: environment)
        {
            results.append(exactMatch)
        }

        let listResult = try await runCommand(
            "gh",
            [
                "issue", "list",
                "--repo", target,
                "--limit", "20",
                "--search", trimmedQuery,
                "--json", "number,title,url,state",
            ],
            nil,
            environment
        )

        guard listResult.exitCode == 0 else {
            throw commandFailure(from: listResult)
        }

        let decodedResults = try decodeIssueSearchResults(from: Data(listResult.stdout.utf8))
        for result in decodedResults where !results.contains(where: { $0.number == result.number }) {
            results.append(result)
        }
        return results
    }

    @MainActor
    func searchIssues(query: String, in repository: ManagedRepository) async throws -> [TicketSearchResult] {
        try await searchTickets(query: query, in: repository)
    }

    @MainActor
    func loadTicket(id: String, in repository: ManagedRepository) async throws -> TicketDetails {
        guard let number = Int(id) else {
            throw StackriotError.commandFailed("GitHub-Issue-ID ist ungueltig: \(id)")
        }
        let target = try repositoryTargetOrThrow(for: repository)
        let environment = await commandEnvironment()
        let result = try await runCommand(
            "gh",
            [
                "issue", "view", "\(number)",
                "--repo", target,
                "--json", "number,title,body,url,labels,comments",
            ],
            nil,
            environment
        )

        guard result.exitCode == 0 else {
            throw commandFailure(from: result)
        }

        return try decodeIssueDetails(from: Data(result.stdout.utf8))
    }

    @MainActor
    func loadIssue(number: Int, in repository: ManagedRepository) async throws -> TicketDetails {
        try await loadTicket(id: String(number), in: repository)
    }

    func decodeIssueSearchResults(from data: Data) throws -> [TicketSearchResult] {
        let decoded = try Self.jsonDecoder.decode([IssueSearchResultPayload].self, from: data)
        return decoded.map {
            TicketSearchResult(
                reference: TicketReference(provider: .github, id: String($0.number), displayID: "#\($0.number)"),
                title: $0.title,
                url: $0.url,
                status: $0.state
            )
        }
    }

    func decodeIssueDetails(from data: Data) throws -> TicketDetails {
        let decoded = try Self.jsonDecoder.decode(IssueDetailsPayload.self, from: data)
        return TicketDetails(
            reference: TicketReference(provider: .github, id: String(decoded.number), displayID: "#\(decoded.number)"),
            title: decoded.title,
            body: decoded.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            url: decoded.url,
            labels: (decoded.labels ?? []).map(\.name),
            comments: (decoded.comments ?? []).map {
                TicketComment(
                    author: $0.author?.login?.nilIfBlank ?? "unknown",
                    body: $0.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    createdAt: $0.createdAt,
                    url: $0.url
                )
            }
            .sorted(by: { $0.createdAt < $1.createdAt })
        )
    }

    // MARK: - Pull Request Operations

    @MainActor
    func searchPullRequests(query: String, in repository: ManagedRepository) async throws -> [PullRequestSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let target = try repositoryTargetOrThrow(for: repository)
        let environment = await commandEnvironment()
        var results: [PullRequestSearchResult] = []

        if let prNumber = Self.issueNumber(from: trimmedQuery),
           let exactMatch = try await loadPullRequestSearchResult(number: prNumber, repositoryTarget: target, environment: environment)
        {
            results.append(exactMatch)
        }

        let listResult = try await runCommand(
            "gh",
            [
                "pr", "list",
                "--repo", target,
                "--limit", "20",
                "--state", "all",
                "--search", trimmedQuery,
                "--json", "number,title,url,headRefName,headRefOid,baseRefName,state,isDraft,isCrossRepository,headRepositoryOwner",
            ],
            nil,
            environment
        )
        guard listResult.exitCode == 0 else {
            throw commandFailure(from: listResult)
        }

        let decodedResults = try decodePullRequestSearchResults(from: Data(listResult.stdout.utf8))
        for result in decodedResults where !results.contains(where: { $0.number == result.number }) {
            results.append(result)
        }
        return results
    }

    @MainActor
    func loadPullRequest(number: Int, in repository: ManagedRepository) async throws -> PullRequestDetails {
        let target = try repositoryTargetOrThrow(for: repository)
        let environment = await commandEnvironment()
        let result = try await runCommand(
            "gh",
            [
                "pr", "view", "\(number)",
                "--repo", target,
                "--json", "number,title,url,headRefName,headRefOid,baseRefName,state,isDraft,isCrossRepository,headRepositoryOwner",
            ],
            nil,
            environment
        )
        guard result.exitCode == 0 else {
            throw commandFailure(from: result)
        }
        return try decodePullRequestDetails(from: Data(result.stdout.utf8))
    }

    func decodePullRequestSearchResults(from data: Data) throws -> [PullRequestSearchResult] {
        let decoded = try Self.jsonDecoder.decode([PullRequestPayload].self, from: data)
        return decoded.map {
            PullRequestSearchResult(
                number: $0.number,
                title: $0.title,
                url: $0.url,
                headRefName: $0.headRefName,
                headRefOID: $0.headRefOid,
                baseRefName: $0.baseRefName,
                status: $0.state,
                isDraft: $0.isDraft ?? false,
                isCrossRepository: $0.isCrossRepository ?? false,
                headRepositoryOwner: $0.headRepositoryOwner?.login?.nilIfBlank
            )
        }
    }

    func decodePullRequestDetails(from data: Data) throws -> PullRequestDetails {
        let decoded = try Self.jsonDecoder.decode(PullRequestPayload.self, from: data)
        return PullRequestDetails(
            number: decoded.number,
            title: decoded.title,
            url: decoded.url,
            headRefName: decoded.headRefName,
            headRefOID: decoded.headRefOid,
            baseRefName: decoded.baseRefName,
            status: Self.prStatus(from: decoded.state),
            isDraft: decoded.isDraft ?? false,
            isCrossRepository: decoded.isCrossRepository ?? false,
            headRepositoryOwner: decoded.headRepositoryOwner?.login?.nilIfBlank
        )
    }

    /// Erstellt einen GitHub Pull Request vom aktuellen Branch des Worktrees.
    func createPR(
        worktreePath: URL,
        title: String,
        body: String,
        baseBranch: String
    ) async throws -> PRInfo {
        let environment = await commandEnvironment()
        let result = try await runCommand(
            "gh",
            [
                "pr", "create",
                "--title", title,
                "--body", body.isEmpty ? " " : body,
                "--base", baseBranch,
                "--json", "number,url",
            ],
            worktreePath,
            environment
        )

        guard result.exitCode == 0 else {
            throw commandFailure(from: result)
        }

        struct PRResponse: Decodable {
            let number: Int
            let url: String
        }

        let data = Data(result.stdout.utf8)
        let decoded = try Self.jsonDecoder.decode(PRResponse.self, from: data)
        return PRInfo(number: decoded.number, url: decoded.url)
    }

    /// Gibt den aktuellen Status eines Pull Requests zurueck.
    func getPRStatus(worktreePath: URL, prNumber: Int) async throws -> PRStatus {
        let environment = await commandEnvironment()
        let result = try await runCommand(
            "gh",
            ["pr", "view", "\(prNumber)", "--json", "state"],
            worktreePath,
            environment
        )

        guard result.exitCode == 0 else {
            throw commandFailure(from: result)
        }

        struct PRStateResponse: Decodable {
            let state: String
        }

        let data = Data(result.stdout.utf8)
        let decoded = try Self.jsonDecoder.decode(PRStateResponse.self, from: data)
        return Self.prStatus(from: decoded.state)
    }

    // MARK: - Helpers

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func liveCommand(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]
    ) async throws -> CommandResult {
        try await CommandRunner.runCollected(
            executable: executable,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: environment
        )
    }

    private static func liveEnvironment() async -> [String: String] {
        ["PATH": await ShellEnvironment.loginShellPath()]
    }

    private func loadTicketSearchResult(
        number: Int,
        repositoryTarget: String,
        environment: [String: String]
    ) async throws -> TicketSearchResult? {
        let result = try await runCommand(
            "gh",
            [
                "issue", "view", "\(number)",
                "--repo", repositoryTarget,
                "--json", "number,title,url,state",
            ],
            nil,
            environment
        )

        guard result.exitCode == 0 else {
            if Self.looksLikeMissingIssue(message: result.stderr.isEmpty ? result.stdout : result.stderr) {
                return nil
            }
            throw commandFailure(from: result)
        }

        let matches = try decodeIssueSearchResults(from: Data("[\(result.stdout)]".utf8))
        return matches.first
    }

    private func loadPullRequestSearchResult(
        number: Int,
        repositoryTarget: String,
        environment: [String: String]
    ) async throws -> PullRequestSearchResult? {
        let result = try await runCommand(
            "gh",
            [
                "pr", "view", "\(number)",
                "--repo", repositoryTarget,
                "--json", "number,title,url,headRefName,headRefOid,baseRefName,state,isDraft,isCrossRepository,headRepositoryOwner",
            ],
            nil,
            environment
        )

        guard result.exitCode == 0 else {
            if Self.looksLikeMissingPullRequest(message: result.stderr.isEmpty ? result.stdout : result.stderr) {
                return nil
            }
            throw commandFailure(from: result)
        }

        return try decodePullRequestSearchResults(from: Data("[\(result.stdout)]".utf8)).first
    }

    @MainActor
    private func repositoryTargetOrThrow(for repository: ManagedRepository) throws -> String {
        guard let target = repositoryTarget(for: repository) else {
            throw StackriotError.commandFailed("Kein GitHub-Remote fuer dieses Repository konfiguriert.")
        }
        return target
    }

    @MainActor
    private func repositoryTarget(for repository: ManagedRepository) -> String? {
        let preferredRemote: RepositoryRemote?
        if let defaultRemote = repository.defaultRemote, Self.isGitHubRemote(url: defaultRemote.url) {
            preferredRemote = defaultRemote
        } else if let originRemote = repository.remotes.first(where: { $0.name == "origin" && Self.isGitHubRemote(url: $0.url) }) {
            preferredRemote = originRemote
        } else {
            preferredRemote = nil
        }

        guard let remote = preferredRemote else { return nil }
        return repositorySlug(from: remote.url)
    }

    private func repositorySlug(from remoteURL: String) -> String? {
        guard let canonicalURL = RepositoryManager.canonicalRemoteURL(from: remoteURL) else {
            return nil
        }

        if canonicalURL.contains("://"), let components = URLComponents(string: canonicalURL) {
            guard components.host?.lowercased() == "github.com" else { return nil }
            return components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).nilIfBlank
        }

        if let separator = canonicalURL.firstIndex(of: ":") {
            let host = canonicalURL[..<separator].lowercased()
            guard host.contains("github.com") else { return nil }
            let slug = canonicalURL[canonicalURL.index(after: separator)...]
            return String(slug).trimmingCharacters(in: CharacterSet(charactersIn: "/")).nilIfBlank
        }

        return nil
    }

    private func commandFailure(from result: CommandResult) -> StackriotError {
        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return StackriotError.commandFailed(detail.isEmpty ? "GitHub CLI command failed." : detail)
    }

    private static func looksLikeMissingIssue(message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("could not resolve to an issue")
            || normalized.contains("not found")
            || normalized.contains("no issue")
    }

    private static func looksLikeMissingPullRequest(message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("could not resolve to a pull request")
            || normalized.contains("not found")
            || normalized.contains("no pull request")
    }

    private static func issueNumber(from query: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        return Int(digits)
    }

    private static func prStatus(from value: String) -> PRStatus {
        switch value.uppercased() {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: return .open
        }
    }

    private func commandEnvironment() async -> [String: String] {
        await environmentProvider()
    }
}

private struct IssueSearchResultPayload: Decodable {
    let number: Int
    let title: String
    let url: String
    let state: String
}

private struct IssueDetailsPayload: Decodable {
    struct LabelPayload: Decodable {
        let name: String
    }

    struct CommentPayload: Decodable {
        struct AuthorPayload: Decodable {
            let login: String?
        }

        let author: AuthorPayload?
        let body: String?
        let createdAt: Date
        let url: String?
    }

    let number: Int
    let title: String
    let body: String?
    let url: String
    let labels: [LabelPayload]?
    let comments: [CommentPayload]?
}

private struct PullRequestPayload: Decodable {
    struct OwnerPayload: Decodable {
        let login: String?
    }

    let number: Int
    let title: String
    let url: String
    let headRefName: String
    let headRefOid: String
    let baseRefName: String
    let state: String
    let isDraft: Bool?
    let isCrossRepository: Bool?
    let headRepositoryOwner: OwnerPayload?
}
