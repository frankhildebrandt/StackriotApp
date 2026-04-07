import Foundation

struct AIProviderService {
    typealias WorktreeNameGenerator = @Sendable (_ ticket: TicketDetails, _ configuration: AIProviderConfiguration) async throws -> AIWorktreeNameSuggestion
    typealias RunSummaryGenerator = @Sendable (_ title: String, _ commandLine: String, _ output: String, _ exitCode: Int?, _ configuration: AIProviderConfiguration) async throws -> AIRunSummary
    typealias IntentSummaryGenerator = @Sendable (_ text: String, _ configuration: AIProviderConfiguration) async throws -> AIIntentSummary
    typealias RepositoryReadmeGenerator = @Sendable (_ repositoryName: String, _ prompt: String, _ configuration: AIProviderConfiguration) async throws -> String

    private let configurationProvider: @Sendable () -> AIProviderConfiguration
    private let worktreeNameGenerator: WorktreeNameGenerator
    private let runSummaryGenerator: RunSummaryGenerator
    private let intentSummaryGenerator: IntentSummaryGenerator
    private let repositoryReadmeGenerator: RepositoryReadmeGenerator

    init(
        configurationProvider: @escaping @Sendable () -> AIProviderConfiguration = { AppPreferences.aiConfiguration },
        worktreeNameGenerator: @escaping WorktreeNameGenerator = AIProviderService.liveWorktreeNameSuggestion,
        runSummaryGenerator: @escaping RunSummaryGenerator = AIProviderService.liveRunSummary,
        intentSummaryGenerator: @escaping IntentSummaryGenerator = AIProviderService.liveIntentSummary,
        repositoryReadmeGenerator: @escaping RepositoryReadmeGenerator = AIProviderService.liveRepositoryReadme
    ) {
        self.configurationProvider = configurationProvider
        self.worktreeNameGenerator = worktreeNameGenerator
        self.runSummaryGenerator = runSummaryGenerator
        self.intentSummaryGenerator = intentSummaryGenerator
        self.repositoryReadmeGenerator = repositoryReadmeGenerator
    }

    func suggestWorktreeName(for ticket: TicketDetails) async throws -> AIWorktreeNameSuggestion {
        let configuration = configurationProvider()
        guard configuration.isConfigured else {
            return fallbackWorktreeNameSuggestion(for: ticket)
        }
        return try await worktreeNameGenerator(ticket, configuration)
    }

    func summarizeAgentRun(
        title: String,
        commandLine: String,
        output: String,
        exitCode: Int?
    ) async throws -> AIRunSummary {
        let configuration = configurationProvider()
        guard configuration.isConfigured else {
            return fallbackRunSummary(title: title, commandLine: commandLine, output: output, exitCode: exitCode)
        }
        return try await runSummaryGenerator(title, commandLine, output, exitCode, configuration)
    }

    func summarizeTextForIntent(_ text: String) async throws -> AIIntentSummary {
        let configuration = configurationProvider()
        guard configuration.isConfigured else {
            return fallbackIntentSummary(for: text)
        }
        return try await intentSummaryGenerator(text, configuration)
    }

    func generateRepositoryReadme(repositoryName: String, prompt: String) async throws -> String {
        let configuration = configurationProvider()
        guard configuration.isConfigured else {
            return fallbackRepositoryReadme(repositoryName: repositoryName, prompt: prompt)
        }
        return try await repositoryReadmeGenerator(repositoryName, prompt, configuration)
    }

    func generateCommitMessage(diff: String) async throws -> AIRunSummary {
        let configuration = configurationProvider()
        guard configuration.isConfigured else {
            throw StackriotError.commandFailed("KI-Provider nicht konfiguriert. Bitte in den Einstellungen einen AI-Provider einrichten.")
        }
        return try await Self.liveCommitMessageSummary(diff: diff, configuration: configuration)
    }

    /// Performs a minimal chat completion to verify credentials, base URL, and model.
    func verifyConfiguration(_ configuration: AIProviderConfiguration) async throws {
        guard configuration.isConfigured else {
            throw StackriotError.commandFailed(
                "KI-Provider ist nicht vollstaendig konfiguriert (z. B. API-Schluessel fehlt)."
            )
        }
        _ = try await Self.generateText(
            configuration: configuration,
            systemPrompt: "Du fuehrst nur einen Verbindungstest aus. Antworte sehr kurz.",
            userPrompt: "Antworte mit genau einem Wort: OK"
        )
    }

    func fallbackWorktreeNameSuggestion(for ticket: TicketDetails) -> AIWorktreeNameSuggestion {
        Self.fallbackWorktreeNameSuggestion(for: ticket)
    }

    func fallbackRunSummary(
        title: String,
        commandLine: String,
        output: String,
        exitCode: Int?
    ) -> AIRunSummary {
        Self.fallbackRunSummary(title: title, commandLine: commandLine, output: output, exitCode: exitCode)
    }

    func fallbackIntentSummary(for text: String) -> AIIntentSummary {
        Self.fallbackIntentSummary(for: text)
    }

    func fallbackRepositoryReadme(repositoryName: String, prompt: String) -> String {
        Self.fallbackRepositoryReadme(repositoryName: repositoryName, prompt: prompt)
    }

    private static func liveCommitMessageSummary(
        diff: String,
        configuration: AIProviderConfiguration
    ) async throws -> AIRunSummary {
        let trimmedDiff = String(diff.suffix(14_000))
        let prompt = """
        Analysiere den folgenden Git-Diff und erzeuge eine strukturierte Commit-Nachricht auf Deutsch. Antworte nur mit JSON.

        Regeln:
        - `title` ist die Betreffzeile des Commits: maximal 7 Woerter, beschreibt die wichtigste Aenderung.
        - `summary` besteht aus 2 bis 5 kurzen Saetzen, die die wesentlichen Aenderungen als Aufzaehlung mit `-` beschreiben.
        - Beschreibe konkret was geaendert wurde (neue Funktionen, Bugfixes, Umstrukturierungen).
        - Vermeide vage Formulierungen wie "diverse Aenderungen".

        JSON-Schema:
        {
          "title": "Kurzer Betreff",
          "summary": "- Erste Aenderung\\n- Zweite Aenderung\\n- Dritte Aenderung"
        }

        Git-Diff:
        \(trimmedDiff)
        """

        let response = try await generateText(
            configuration: configuration,
            systemPrompt: "Du erzeugst praezise, konventionelle Commit-Nachrichten aus Git-Diffs.",
            userPrompt: prompt
        )
        guard let data = extractFirstJSONObject(from: response)?.data(using: .utf8) else {
            throw StackriotError.commandFailed("AI-Antwort enthielt kein gueltiges JSON fuer die Commit-Nachricht.")
        }
        let decoded = try JSONDecoder().decode(RunSummaryPayload.self, from: data)
        guard
            let summaryTitle = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            let summaryText = decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else {
            throw StackriotError.commandFailed("AI-Antwort fuer Commit-Nachricht war unvollstaendig.")
        }
        return AIRunSummary(title: summaryTitle, summary: summaryText)
    }

    private static func liveWorktreeNameSuggestion(
        ticket: TicketDetails,
        configuration: AIProviderConfiguration
    ) async throws -> AIWorktreeNameSuggestion {
        let prompt = """
        Analysiere das folgende Ticket und antworte nur mit JSON.

        Regeln:
        - `kind` muss genau eines von `bug`, `feature`, `refactor`, `chore` sein.
        - `ticketIdentifier` muss der Ticket-Key bzw. die Nummer ohne fuehrendes `#` sein oder `null`.
        - `shortSummary` muss maximal 4 Woerter enthalten.
        - `branchName` muss das Format `prefix/ticket-zusammenfassung` oder `prefix/zusammenfassung` haben.
        - `branchName` muss nur Kleinbuchstaben, Zahlen, `-`, `_`, `.`, und `/` enthalten.
        - Umlaute und `ß` muessen ASCII-normalisiert werden.

        JSON-Schema:
        {
          "kind": "bug|feature|refactor|chore",
          "ticketIdentifier": "abc-123",
          "shortSummary": "grosses fenster kaputt",
          "branchName": "bug/abc-123-grosses-fenster-kaputt"
        }

        Ticket:
        \(ticket.reference.displayID) \(ticket.title)
        Provider: \(ticket.reference.provider.displayName)

        Labels: \(ticket.labels.joined(separator: ", "))

        Body:
        \(ticket.body)

        Kommentare:
        \(ticket.comments.map { "\($0.author): \($0.body)" }.joined(separator: "\n"))
        """

        let response = try await generateText(
            configuration: configuration,
            systemPrompt: "Du erzeugst kurze, praezise Branch-Namen fuer Git-Worktrees.",
            userPrompt: prompt
        )
        guard let data = extractFirstJSONObject(from: response)?.data(using: .utf8) else {
            throw StackriotError.commandFailed("AI response did not contain valid JSON for worktree naming.")
        }
        let decoded = try JSONDecoder().decode(WorktreeSuggestionPayload.self, from: data)
        let normalizedBranchName = WorktreeManager.normalizedWorktreeName(from: decoded.branchName.lowercased())
        let shortSummary = decoded.shortSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let kind = WorktreeIssueKind(rawValue: decoded.kind),
            let normalizedSummary = shortSummary.nonEmpty,
            let branchName = normalizedBranchName.nonEmpty
        else {
            throw StackriotError.commandFailed("AI response for worktree naming was incomplete.")
        }
        return AIWorktreeNameSuggestion(
            kind: kind,
            ticketIdentifier: decoded.ticketIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            shortSummary: normalizedSummary,
            branchName: branchName
        )
    }

    private static func liveRunSummary(
        title: String,
        commandLine: String,
        output: String,
        exitCode: Int?,
        configuration: AIProviderConfiguration
    ) async throws -> AIRunSummary {
        let trimmedOutput = String(output.suffix(12_000))
        let prompt = """
        Fasse den folgenden Agent-Run fuer einen Benutzer kurz auf Deutsch zusammen und antworte nur mit JSON.

        Regeln:
        - `title` maximal 7 Woerter.
        - `summary` 2 bis 5 kurze Saetze.
        - Beschreibe Ergebnis, wichtige Aktionen und naechsten sinnvollen Schritt.
        - Wenn Fehler enthalten sind, nenne sie klar.

        JSON-Schema:
        {
          "title": "Kurzer Titel",
          "summary": "Kurze Zusammenfassung."
        }

        Run-Titel: \(title)
        Befehl: \(commandLine)
        Exit-Code: \(exitCode.map(String.init) ?? "unbekannt")

        Ausgabe:
        \(trimmedOutput)
        """

        let response = try await generateText(
            configuration: configuration,
            systemPrompt: "Du komprimierst Agent- und Terminal-Ausgaben in knappe, verlaessliche Statuszusammenfassungen.",
            userPrompt: prompt
        )
        guard let data = extractFirstJSONObject(from: response)?.data(using: .utf8) else {
            throw StackriotError.commandFailed("AI response did not contain valid JSON for run summary.")
        }
        let decoded = try JSONDecoder().decode(RunSummaryPayload.self, from: data)
        guard
            let summaryTitle = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            let summaryText = decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else {
            throw StackriotError.commandFailed("AI response for run summary was incomplete.")
        }
        return AIRunSummary(title: summaryTitle, summary: summaryText)
    }

    private static func liveIntentSummary(
        text: String,
        configuration: AIProviderConfiguration
    ) async throws -> AIIntentSummary {
        let trimmedInput = String(text.suffix(12_000))
        let prompt = """
        Fasse den folgenden Rohtext fuer einen neuen Intent auf Deutsch zusammen und antworte nur mit JSON.

        Regeln:
        - `title` ist ein kurzer Titel mit maximal 6 Woertern.
        - `summary` ist ein kurzer, klarer Arbeitsauftrag in 2 bis 5 Saetzen.
        - Schreibe praezise und produktorientiert.
        - Erhalte wichtige Randbedingungen, aber vermeide Wiederholungen.

        JSON-Schema:
        {
          "title": "Kurzer Titel",
          "summary": "Praeziser, editierbarer Intent."
        }

        Rohtext:
        \(trimmedInput)
        """

        let response = try await generateText(
            configuration: configuration,
            systemPrompt: "Du verdichtest ungeordneten Rohtext in kurze, verlaessliche Intent-Zusammenfassungen auf Deutsch.",
            userPrompt: prompt
        )
        guard let data = extractFirstJSONObject(from: response)?.data(using: .utf8) else {
            throw StackriotError.commandFailed("AI response did not contain valid JSON for the intent summary.")
        }
        let decoded = try JSONDecoder().decode(RunSummaryPayload.self, from: data)
        guard
            let title = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            let summary = decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        else {
            throw StackriotError.commandFailed("AI response for intent summary was incomplete.")
        }
        return AIIntentSummary(title: title, summary: summary)
    }

    private static func liveRepositoryReadme(
        repositoryName: String,
        prompt: String,
        configuration: AIProviderConfiguration
    ) async throws -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = try await generateText(
            configuration: configuration,
            systemPrompt: "Du erzeugst belastbare, gut strukturierte README-Dateien in Markdown fuer neue Software-Repositories.",
            userPrompt: """
            Erzeuge eine README.md fuer ein neues Repository. Antworte nur mit Markdown, ohne Code-Fences.

            Regeln:
            - Beginne mit einer H1-Ueberschrift fuer den Projektnamen.
            - Liefere eine kurze Einordnung, Kernfunktionen oder Ziele, erste Setup-/Nutzungshinweise und naechste sinnvolle Schritte.
            - Wenn Informationen fehlen, formuliere vorsichtig und markiere Annahmen knapp.
            - Die README soll sofort commitbar sein.

            Repository-Name: \(repositoryName)

            Prompt:
            \(trimmedPrompt)
            """
        )
        guard let markdown = response.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw StackriotError.commandFailed("AI response for the repository README was empty.")
        }
        return stripCodeFences(from: markdown)
    }

    private static func generateText(
        configuration: AIProviderConfiguration,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        switch configuration.provider {
        case .openAI, .openRouter, .lmStudio:
            return try await generateOpenAICompatibleText(
                configuration: configuration,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        case .anthropic:
            return try await generateAnthropicText(
                configuration: configuration,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        case .ollama:
            return try await generateOllamaText(
                configuration: configuration,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        }
    }

    private static func fallbackIntentSummary(for text: String) -> AIIntentSummary {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = normalized
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .prefix(6)
            .joined(separator: " ")
            .nonEmpty ?? "Quick Intent"
        let summary = String(normalized.prefix(800)).nonEmpty ?? "Kein Inhalt vorhanden."
        return AIIntentSummary(title: title, summary: summary)
    }

    static func fallbackRepositoryReadme(repositoryName: String, prompt: String) -> String {
        let trimmedName = repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "New Repository"
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Projektbeschreibung folgt."
        return """
        # \(trimmedName)

        ## Overview

        \(trimmedPrompt)

        ## Getting Started

        1. Review the initial project structure.
        2. Add implementation details and setup instructions.
        3. Extend this README as the repository evolves.
        """
    }

    private static func generateOpenAICompatibleText(
        configuration: AIProviderConfiguration,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let url = try serviceURL(from: configuration.baseURL, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey?.nonEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if configuration.provider == .openRouter {
            applyOpenRouterAttributionHeaders(to: &request)
        }

        let payload = OpenAICompatibleRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt),
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureHTTPStatus(response, data: data)
        let decoded = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        if let apiError = decoded.error {
            throw StackriotError.commandFailed(apiError.message)
        }
        guard let choice = decoded.choices.first else {
            throw StackriotError.commandFailed("No completion choices received from \(configuration.provider.displayName).")
        }
        if let choiceError = choice.error {
            throw StackriotError.commandFailed(choiceError.message)
        }
        guard let message = choice.message else {
            throw StackriotError.commandFailed("No assistant message received from \(configuration.provider.displayName).")
        }
        guard let content = message.resolvedContent?.nonEmpty else {
            throw StackriotError.commandFailed("No completion content received from \(configuration.provider.displayName).")
        }
        return content
    }

    /// OpenRouter recommends `HTTP-Referer` and `X-OpenRouter-Title` for app attribution (see openrouter.ai/docs/requests).
    private static func applyOpenRouterAttributionHeaders(to request: inout URLRequest) {
        request.setValue(openRouterHTTPReferer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(openRouterAppTitle, forHTTPHeaderField: "X-OpenRouter-Title")
    }

    private static let openRouterHTTPReferer = "https://stackriot.app"
    private static let openRouterAppTitle = "Stackriot"

    private static func generateAnthropicText(
        configuration: AIProviderConfiguration,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let url = try serviceURL(from: configuration.baseURL, path: "messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey?.nonEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let payload = AnthropicRequest(
            model: configuration.model,
            maxTokens: 900,
            system: systemPrompt,
            messages: [.init(role: "user", content: userPrompt)]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureHTTPStatus(response, data: data)
        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        let content = decoded.content.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = content.nonEmpty else {
            throw StackriotError.commandFailed("No completion content received from Anthropic.")
        }
        return resolved
    }

    private static func generateOllamaText(
        configuration: AIProviderConfiguration,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let url = try serviceURL(from: configuration.baseURL, path: "api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = OllamaRequest(
            model: configuration.model,
            stream: false,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt),
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureHTTPStatus(response, data: data)
        let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
        guard let content = decoded.message.content.nonEmpty else {
            throw StackriotError.commandFailed("No completion content received from Ollama.")
        }
        return content
    }

    private static func serviceURL(from baseURL: String, path: String) throws -> URL {
        let normalizedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(normalizedBase)/\(path)") else {
            throw StackriotError.commandFailed("Invalid AI base URL: \(baseURL)")
        }
        return url
    }

    private static func ensureHTTPStatus(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw StackriotError.commandFailed(message?.nonEmpty ?? "AI provider request failed with HTTP \(httpResponse.statusCode).")
        }
    }

    static func fallbackWorktreeNameSuggestion(for ticket: TicketDetails) -> AIWorktreeNameSuggestion {
        let haystack = ([ticket.title, ticket.body] + ticket.labels).joined(separator: " ").lowercased()
        let kind: WorktreeIssueKind
        if haystack.contains(anyOf: ["bug", "fix", "broken", "error", "crash", "kaputt", "defekt"]) {
            kind = .bug
        } else if haystack.contains(anyOf: ["refactor", "cleanup", "clean-up", "rename", "restructure"]) {
            kind = .refactor
        } else if haystack.contains(anyOf: ["chore", "dependency", "dependencies", "deps", "ci", "build", "maintenance"]) {
            kind = .chore
        } else {
            kind = .feature
        }

        let summary = slugSummary(from: ticket.title)
        let branchName: String
        if let ticketIdentifier = ticket.reference.id
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty?
            .lowercased()
        {
            branchName = "\(kind.branchPrefix)/\(ticketIdentifier)-\(summary)"
        } else {
            branchName = "\(kind.branchPrefix)/\(summary)"
        }

        return AIWorktreeNameSuggestion(
            kind: kind,
            ticketIdentifier: ticket.reference.id.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            shortSummary: summary.replacingOccurrences(of: "-", with: " "),
            branchName: WorktreeManager.normalizedWorktreeName(from: branchName)
        )
    }

    static func fallbackRunSummary(
        title: String,
        commandLine: String,
        output: String,
        exitCode: Int?
    ) -> AIRunSummary {
        let normalizedLines = output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let noteworthyLines = normalizedLines.filter {
            $0.localizedCaseInsensitiveContains("error")
                || $0.localizedCaseInsensitiveContains("failed")
                || $0.localizedCaseInsensitiveContains("warning")
                || $0.hasPrefix("$ ")
        }
        let tail = Array((noteworthyLines.isEmpty ? normalizedLines : noteworthyLines).suffix(3))
        let statusTitle: String
        switch exitCode {
        case .some(0):
            statusTitle = "Agentlauf abgeschlossen"
        case .some:
            statusTitle = "Agentlauf mit Fehlern"
        case .none:
            statusTitle = "Agentlauf beendet"
        }
        var summaryParts = [
            "Der Run `\(title)` wurde mit Exit-Code \(exitCode.map(String.init) ?? "unbekannt") beendet.",
            "Ausgefuehrt wurde `\(commandLine)`."
        ]
        if let lastLine = tail.last?.nonEmpty {
            summaryParts.append("Wichtige Rueckmeldung: \(lastLine)")
        }
        if tail.count > 1 {
            summaryParts.append("Relevante Auszuege: \(tail.joined(separator: " | "))")
        }
        return AIRunSummary(title: statusTitle, summary: summaryParts.joined(separator: " "))
    }

    private static func slugSummary(from value: String) -> String {
        let stopWords: Set<String> = [
            "a", "an", "and", "bug", "das", "der", "die", "ein", "eine", "fuer", "für", "fix", "feature",
            "implement", "issue", "mit", "the", "und", "von", "zu"
        ]
        let transliterated = value
            .lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive], locale: .current)
        let tokens = transliterated
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { token -> String? in
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count > 1, !stopWords.contains(trimmed) else { return nil }
                return trimmed
            }
        let summaryTokens = Array(tokens.prefix(4))
        return (summaryTokens.isEmpty ? ["update"] : summaryTokens).joined(separator: "-")
    }

    private static func extractFirstJSONObject(from response: String) -> String? {
        if let fencedStart = response.range(of: "```json") ?? response.range(of: "```") {
            let remainder = response[fencedStart.upperBound...]
            if let fencedEnd = remainder.range(of: "```") {
                return String(remainder[..<fencedEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let start = response.firstIndex(of: "{") else { return nil }
        var depth = 0
        for index in response[start...].indices {
            switch response[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(response[start...index])
                }
            default:
                break
            }
        }
        return nil
    }

    private static func stripCodeFences(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return trimmed }
        let body = lines.dropFirst().dropLast()
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct WorktreeSuggestionPayload: Decodable {
    let kind: String
    let ticketIdentifier: String?
    let shortSummary: String
    let branchName: String
}

private struct RunSummaryPayload: Decodable {
    let title: String
    let summary: String
}

private struct OpenAICompatibleRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double = 0.2
}

private struct OpenAICompatibleResponse: Decodable {
    struct APIErrorPayload: Decodable {
        let message: String
    }

    struct Choice: Decodable {
        struct ChoiceError: Decodable {
            let code: Int?
            let message: String
        }

        struct Message: Decodable {
            let content: String?
            let parts: [Part]

            struct Part: Decodable {
                let text: String?
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let content = try? container.decode(String.self, forKey: .content) {
                    self.content = content
                    self.parts = []
                } else if let parts = try? container.decode([Part].self, forKey: .content) {
                    self.content = nil
                    self.parts = parts
                } else {
                    self.content = nil
                    self.parts = []
                }
            }

            enum CodingKeys: String, CodingKey {
                case content
            }

            var resolvedContent: String? {
                content?.nonEmpty ?? parts.compactMap(\.text).joined(separator: "\n").nonEmpty
            }
        }

        let message: Message?
        let error: ChoiceError?
    }

    let choices: [Choice]
    let error: APIErrorPayload?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decodeIfPresent(APIErrorPayload.self, forKey: .error)
        choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case choices
        case error
    }
}

private struct AnthropicRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct AnthropicResponse: Decodable {
    struct Content: Decodable {
        let text: String
    }

    let content: [Content]
}

private struct OllamaRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let stream: Bool
    let messages: [Message]
}

private struct OllamaResponse: Decodable {
    struct Message: Decodable {
        let content: String
    }

    let message: Message
}

private extension String {
    func contains(anyOf candidates: [String]) -> Bool {
        candidates.contains { contains($0) }
    }
}
