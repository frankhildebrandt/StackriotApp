import Foundation

struct GeneratedCommitMessage: Sendable, Equatable {
    let subject: String
    let bodyItems: [String]

    private init(subject: String, bodyItems: [String]) {
        self.subject = subject
        self.bodyItems = bodyItems
    }

    var fullMessage: String {
        guard !bodyItems.isEmpty else { return subject }
        let body = bodyItems.map { "- \($0)" }.joined(separator: "\n")
        return "\(subject)\n\n\(body)"
    }

    init?(summaryTitle: String?, summaryText: String?) {
        let resolved = Self.makeMessage(summaryTitle: summaryTitle, summaryText: summaryText)
        guard let resolved else { return nil }
        self = resolved
    }

    private static func makeMessage(summaryTitle: String?, summaryText: String?) -> GeneratedCommitMessage? {
        let cleanedTitle = normalizedTitleCandidate(summaryTitle)
        let bulletCandidates = normalizedBulletCandidates(from: summaryText)

        guard cleanedTitle != nil || !bulletCandidates.isEmpty else { return nil }

        let category = inferredCategory(
            title: cleanedTitle,
            summary: summaryText,
            bullets: bulletCandidates
        )
        let subjectSource = cleanedTitle ?? bulletCandidates.first ?? "update agent work"
        let subject = "\(category.marker): \(truncatedSubject(from: subjectSource, marker: category.marker))"

        let normalizedSubject = normalizedComparisonValue(subjectSource)
        let bodyItems = bulletCandidates
            .filter { normalizedComparisonValue($0) != normalizedSubject }
            .prefix(4)
            .map(\.self)

        return GeneratedCommitMessage(subject: subject, bodyItems: bodyItems)
    }

    private static func normalizedTitleCandidate(_ title: String?) -> String? {
        guard let candidate = cleanedFragment(title), !isGenericSummaryTitle(candidate) else {
            return nil
        }
        return stripKnownCommitPrefix(candidate)
    }

    private static func normalizedBulletCandidates(from summaryText: String?) -> [String] {
        guard let summaryText = summaryText?.nonEmpty else { return [] }

        let explicitBullets = summaryText
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    trimmed.hasPrefix("- ")
                        || trimmed.hasPrefix("* ")
                        || trimmed.hasPrefix("• ")
                        || trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) != nil
                else {
                    return nil
                }
                return cleanedFragment(trimmed)
            }

        let candidates = explicitBullets.isEmpty ? sentenceFragments(from: summaryText) : explicitBullets

        var seen: Set<String> = []
        return candidates.filter { candidate in
            let normalized = normalizedComparisonValue(candidate)
            guard !normalized.isEmpty, !seen.contains(normalized) else { return false }
            seen.insert(normalized)
            return true
        }
    }

    private static func sentenceFragments(from text: String) -> [String] {
        var fragments: [String] = []

        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .localized]
        ) { substring, _, _, _ in
            guard let cleaned = cleanedFragment(substring) else { return }
            fragments.append(cleaned)
        }

        if !fragments.isEmpty {
            return fragments
        }

        return text
            .replacingOccurrences(of: "|", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .split(whereSeparator: \.isNewline)
            .compactMap { cleanedFragment(String($0)) }
    }

    private static func cleanedFragment(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.nonEmpty else { return nil }

        let withoutBullet = rawValue.replacingOccurrences(
            of: #"^\s*(?:[-*•]\s+|\d+[\.\)]\s+)"#,
            with: "",
            options: .regularExpression
        )

        let withoutMetadata = withoutBullet.replacingOccurrences(
            of: #"^(?:Wichtige Rueckmeldung|Relevante Auszuege):\s*"#,
            with: "",
            options: .regularExpression
        )

        let collapsedWhitespace = withoutMetadata.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        let trimmed = collapsedWhitespace
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: "`", with: "")

        guard
            let candidate = trimmed.nonEmpty,
            !isExcludedSummarySentence(candidate)
        else {
            return nil
        }

        return stripKnownCommitPrefix(candidate)
    }

    private static func truncatedSubject(from value: String, marker: String) -> String {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let maxLength = max(24, 72 - marker.count - 2)
        guard cleaned.count > maxLength else { return cleaned }

        let index = cleaned.index(cleaned.startIndex, offsetBy: maxLength)
        let prefix = cleaned[..<index]
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(prefix)
    }

    private static func normalizedComparisonValue(_ value: String) -> String {
        value
            .lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripKnownCommitPrefix(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"^(?:fix|feature|chore|docs|refactor|test):\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func isGenericSummaryTitle(_ value: String) -> Bool {
        let normalized = normalizedComparisonValue(value)
        return [
            "agent zusammenfassung",
            "agentlauf abgeschlossen",
            "agentlauf mit fehlern",
            "agentlauf beendet"
        ].contains(normalized)
    }

    private static func isExcludedSummarySentence(_ value: String) -> Bool {
        let normalized = normalizedComparisonValue(value)
        return normalized.hasPrefix("der run")
            || normalized.hasPrefix("ausgefuhrt wurde")
            || normalized.hasPrefix("relevante auszuge")
            || normalized.hasPrefix("wichtige ruckmeldung")
            || normalized.hasPrefix("exit code")
    }

    private static func inferredCategory(title: String?, summary: String?, bullets: [String]) -> CommitCategory {
        let haystack = normalizedComparisonValue(
            [title, summary, bullets.joined(separator: " ")]
                .compactMap { $0?.nonEmpty }
                .joined(separator: " ")
        )

        if haystack.contains(anyOf: ["fix", "bug", "error", "fail", "crash", "issue", "regression", "conflict"]) {
            return .fix
        }
        if haystack.contains(anyOf: ["feature", "add", "implement", "create", "support", "enable", "introduce"]) {
            return .feature
        }
        if haystack.contains(anyOf: ["docs", "documentation", "readme"]) {
            return .docs
        }
        if haystack.contains(anyOf: ["refactor", "cleanup", "clean up", "rename", "restructure"]) {
            return .refactor
        }
        if haystack.contains(anyOf: ["test", "spec", "coverage"]) {
            return .test
        }
        return .chore
    }
}

private enum CommitCategory: String, Sendable {
    case fix = "Fix"
    case feature = "Feature"
    case chore = "Chore"
    case docs = "Docs"
    case refactor = "Refactor"
    case test = "Test"

    var marker: String { rawValue }
}

private extension String {
    func contains(anyOf values: [String]) -> Bool {
        values.contains(where: contains)
    }
}
