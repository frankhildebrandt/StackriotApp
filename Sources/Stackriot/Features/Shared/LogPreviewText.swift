import Foundation

enum LogPreviewText {
    static func tail(from text: String, lineCount: Int) -> String {
        guard lineCount > 0 else { return "" }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)
        let effectiveLines = trimTrailingEmptyLines(lines)
        guard !effectiveLines.isEmpty else { return "" }

        return effectiveLines.suffix(lineCount).joined(separator: "\n")
    }

    static func lineCount(for text: String) -> Int {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return trimTrailingEmptyLines(normalized.components(separatedBy: .newlines)).count
    }

    private static func trimTrailingEmptyLines(_ lines: [String]) -> [String] {
        var trimmed = lines
        while trimmed.last?.isEmpty == true {
            trimmed.removeLast()
        }
        return trimmed
    }
}
