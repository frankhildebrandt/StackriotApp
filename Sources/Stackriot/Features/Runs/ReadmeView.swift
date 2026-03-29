import AppKit
import SwiftUI
import WebKit

private func markdownToHTML(_ markdown: String) -> String {
    let normalized = markdown
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")

    var html: [String] = []
    var paragraphLines: [String] = []
    var codeLines: [String] = []
    var codeLanguage = ""
    var isInCodeBlock = false
    var index = 0

    func flushParagraph() {
        guard !paragraphLines.isEmpty else { return }
        let text = paragraphLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        html.append("<p>\(renderInlineMarkdown(text))</p>")
        paragraphLines.removeAll(keepingCapacity: true)
    }

    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if isInCodeBlock {
            if trimmed.hasPrefix("```") {
                let languageClass = codeLanguage.isEmpty ? "" : " class=\"language-\(escapeHTMLAttribute(codeLanguage))\""
                let code = codeLines.joined(separator: "\n")
                html.append("<pre><code\(languageClass)>\(escapeHTML(code))</code></pre>")
                codeLines.removeAll(keepingCapacity: true)
                codeLanguage = ""
                isInCodeBlock = false
            } else {
                codeLines.append(line)
            }
            index += 1
            continue
        }

        if trimmed.hasPrefix("```") {
            flushParagraph()
            isInCodeBlock = true
            codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            index += 1
            continue
        }

        if trimmed.isEmpty {
            flushParagraph()
            index += 1
            continue
        }

        if isHorizontalRule(trimmed) {
            flushParagraph()
            html.append("<hr>")
            index += 1
            continue
        }

        if let heading = headingHTML(for: trimmed) {
            flushParagraph()
            html.append(heading)
            index += 1
            continue
        }

        if let table = parseTable(lines: lines, startIndex: index) {
            flushParagraph()
            html.append(table.html)
            index = table.nextIndex
            continue
        }

        if trimmed.hasPrefix(">") {
            flushParagraph()
            var quoteLines: [String] = []

            while index < lines.count {
                let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                guard quoteLine.hasPrefix(">") else { break }

                var inner = String(quoteLine.dropFirst())
                if inner.first == " " {
                    inner.removeFirst()
                }
                quoteLines.append(inner)
                index += 1
            }

            html.append("<blockquote>\(markdownToHTML(quoteLines.joined(separator: "\n")))</blockquote>")
            continue
        }

        if let list = parseList(lines: lines, startIndex: index) {
            flushParagraph()
            html.append(list.html)
            index = list.nextIndex
            continue
        }

        paragraphLines.append(line)
        index += 1
    }

    flushParagraph()

    if isInCodeBlock {
        let languageClass = codeLanguage.isEmpty ? "" : " class=\"language-\(escapeHTMLAttribute(codeLanguage))\""
        let code = codeLines.joined(separator: "\n")
        html.append("<pre><code\(languageClass)>\(escapeHTML(code))</code></pre>")
    }

    return html.joined(separator: "\n")
}

private func renderHTML(for markdown: String) -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      :root { color-scheme: light dark; }
      * { box-sizing: border-box; }
      body {
        font: -apple-system-body;
        max-width: 780px;
        margin: 0 auto;
        padding: 24px 32px;
        color: light-dark(#1f2328, #e6edf3);
        background: light-dark(#ffffff, #0d1117);
        line-height: 1.6;
        overflow-wrap: anywhere;
      }
      h1, h2 {
        border-bottom: 1px solid light-dark(#d0d7de, #30363d);
        padding-bottom: 0.3em;
      }
      h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.2em 0 0.5em; }
      p, ul, ol, pre, table, blockquote { margin: 0 0 16px; }
      ul, ol { padding-left: 2em; }
      code {
        font: 0.875em ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace;
        background: light-dark(#f6f8fa, #161b22);
        padding: 0.2em 0.4em;
        border-radius: 6px;
      }
      pre {
        background: light-dark(#f6f8fa, #161b22);
        border-radius: 8px;
        padding: 16px;
        overflow-x: auto;
      }
      pre code { background: none; padding: 0; }
      blockquote {
        border-left: 4px solid light-dark(#d0d7de, #30363d);
        margin-left: 0;
        padding: 0 1em;
        color: light-dark(#656d76, #8b949e);
      }
      table { border-collapse: collapse; width: 100%; display: block; overflow-x: auto; }
      th, td {
        border: 1px solid light-dark(#d0d7de, #30363d);
        padding: 6px 13px;
        text-align: left;
      }
      th { background: light-dark(#f6f8fa, #161b22); }
      img { max-width: 100%; height: auto; }
      a { color: light-dark(#0969da, #58a6ff); }
      hr {
        border: 0;
        border-top: 1px solid light-dark(#d0d7de, #30363d);
        margin: 24px 0;
      }
    </style>
    </head>
    <body>
    \(markdownToHTML(markdown))
    </body>
    </html>
    """
}

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(renderHTML(for: markdown), baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            } else {
                return .allow
            }
        }
    }
}

struct ReadmeView: View {
    let worktreePath: String

    @State private var content: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
                Text("README")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial)

            Divider()

            if let content {
                MarkdownWebView(markdown: content, baseURL: repositoryURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Keine README gefunden",
                    systemImage: "doc.text",
                    description: Text("Kein README in diesem Repository.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            loadReadme()
        }
        .onChange(of: worktreePath) { _, _ in
            loadReadme()
        }
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: worktreePath, isDirectory: true)
    }

    private func loadReadme() {
        let candidates = [
            "README.md",
            "readme.md",
            "Readme.md",
            "README.MD",
            "README.rst",
            "README.txt",
            "readme.txt",
        ]

        content = candidates.lazy
            .compactMap { candidate in
                try? String(contentsOf: repositoryURL.appendingPathComponent(candidate), encoding: .utf8)
            }
            .first
    }
}

private func escapeHTML(_ text: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(text.count)

    for character in text {
        switch character {
        case "&": escaped += "&amp;"
        case "<": escaped += "&lt;"
        case ">": escaped += "&gt;"
        case "\"": escaped += "&quot;"
        default: escaped.append(character)
        }
    }

    return escaped
}

private func escapeHTMLAttribute(_ text: String) -> String {
    escapeHTML(text)
}

private func renderInlineMarkdown(_ text: String) -> String {
    let characters = Array(text)
    var result = ""
    var index = 0
    var boldOpen = false
    var italicOpen = false
    var strikeOpen = false

    while index < characters.count {
        if characters[index] == "`", let end = findCharacter("`", in: characters, from: index + 1) {
            let content = String(characters[(index + 1) ..< end])
            result += "<code>\(escapeHTML(content))</code>"
            index = end + 1
            continue
        }

        if characters[index] == "!", index + 1 < characters.count, characters[index + 1] == "[",
           let image = parseLinkLikeSyntax(characters, startIndex: index + 1) {
            result += "<img alt=\"\(escapeHTMLAttribute(image.label))\" src=\"\(escapeHTMLAttribute(image.destination))\">"
            index = image.nextIndex
            continue
        }

        if characters[index] == "[", let link = parseLinkLikeSyntax(characters, startIndex: index) {
            result += "<a href=\"\(escapeHTMLAttribute(link.destination))\">\(renderInlineMarkdown(link.label))</a>"
            index = link.nextIndex
            continue
        }

        if hasSequence("**", in: characters, at: index) {
            if boldOpen || hasSequence("**", in: characters, after: index + 2) {
                result += boldOpen ? "</strong>" : "<strong>"
                boldOpen.toggle()
                index += 2
                continue
            }
        }

        if hasSequence("~~", in: characters, at: index) {
            if strikeOpen || hasSequence("~~", in: characters, after: index + 2) {
                result += strikeOpen ? "</del>" : "<del>"
                strikeOpen.toggle()
                index += 2
                continue
            }
        }

        if characters[index] == "*" && !hasSequence("**", in: characters, at: index) {
            if italicOpen || hasSequence("*", in: characters, after: index + 1) {
                result += italicOpen ? "</em>" : "<em>"
                italicOpen.toggle()
                index += 1
                continue
            }
        }

        if characters[index] == "\\" && index + 1 < characters.count {
            result += escapeHTML(String(characters[index + 1]))
            index += 2
            continue
        }

        result += escapeHTML(String(characters[index]))
        index += 1
    }

    if strikeOpen {
        result += "</del>"
    }
    if italicOpen {
        result += "</em>"
    }
    if boldOpen {
        result += "</strong>"
    }

    return result
}

private func headingHTML(for line: String) -> String? {
    var level = 0

    for character in line {
        guard character == "#" else { break }
        level += 1
    }

    guard (1 ... 6).contains(level) else { return nil }
    guard line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }

    let content = line.dropFirst(level + 1)
    return "<h\(level)>\(renderInlineMarkdown(String(content)))</h\(level)>"
}

private func isHorizontalRule(_ line: String) -> Bool {
    let stripped = line.filter { !$0.isWhitespace }
    guard stripped.count >= 3 else { return false }
    guard let first = stripped.first else { return false }
    guard first == "-" || first == "*" || first == "_" else { return false }
    return stripped.allSatisfy { $0 == first }
}

private func parseList(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int)? {
    guard let kind = listKind(for: lines[startIndex].trimmingCharacters(in: .whitespaces)) else { return nil }

    var items: [String] = []
    var index = startIndex

    while index < lines.count {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard let currentKind = listKind(for: trimmed), currentKind == kind else { break }

        switch currentKind {
        case .unordered:
            let content = trimmed.dropFirst(2)
            items.append("<li>\(renderInlineMarkdown(String(content)))</li>")
        case .ordered:
            let contentStart = trimmed.firstIndex(where: { $0 == " " }) ?? trimmed.endIndex
            let content = trimmed[contentStart...].trimmingCharacters(in: .whitespaces)
            items.append("<li>\(renderInlineMarkdown(content))</li>")
        }

        index += 1
    }

    let tag = kind == .unordered ? "ul" : "ol"
    return ("<\(tag)>\n\(items.joined(separator: "\n"))\n</\(tag)>", index)
}

private func parseTable(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int)? {
    guard startIndex + 1 < lines.count else { return nil }

    let headerLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
    let separatorLine = lines[startIndex + 1].trimmingCharacters(in: .whitespaces)

    guard headerLine.contains("|"), isTableSeparator(separatorLine) else { return nil }

    let headerCells = splitTableRow(headerLine)
    guard !headerCells.isEmpty else { return nil }

    var rows: [[String]] = []
    var index = startIndex + 2

    while index < lines.count {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains("|") else { break }
        rows.append(splitTableRow(trimmed))
        index += 1
    }

    let head = headerCells.map { "<th>\(renderInlineMarkdown($0))</th>" }.joined()
    let body = rows.map { row in
        let cells = row.map { "<td>\(renderInlineMarkdown($0))</td>" }.joined()
        return "<tr>\(cells)</tr>"
    }.joined(separator: "\n")

    let bodyHTML = body.isEmpty ? "" : "<tbody>\n\(body)\n</tbody>"
    let html = """
    <table>
    <thead><tr>\(head)</tr></thead>
    \(bodyHTML)
    </table>
    """

    return (html, index)
}

private func splitTableRow(_ row: String) -> [String] {
    var trimmed = row
    if trimmed.hasPrefix("|") {
        trimmed.removeFirst()
    }
    if trimmed.hasSuffix("|") {
        trimmed.removeLast()
    }

    var cells: [String] = []
    var current = ""

    for character in trimmed {
        if character == "|" {
            cells.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        } else {
            current.append(character)
        }
    }

    cells.append(current.trimmingCharacters(in: .whitespaces))
    return cells
}

private func isTableSeparator(_ line: String) -> Bool {
    let cells = splitTableRow(line)
    guard !cells.isEmpty else { return false }

    return cells.allSatisfy { cell in
        let stripped = cell.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" || $0 == ":" }
    }
}

private enum ListKind {
    case unordered
    case ordered
}

private func listKind(for line: String) -> ListKind? {
    if line.hasPrefix("- ") || line.hasPrefix("* ") {
        return .unordered
    }

    var hasDigit = false
    var index = line.startIndex

    while index < line.endIndex, line[index].isNumber {
        hasDigit = true
        index = line.index(after: index)
    }

    guard hasDigit, index < line.endIndex, line[index] == "." else { return nil }
    let next = line.index(after: index)
    guard next < line.endIndex, line[next] == " " else { return nil }
    return .ordered
}

private func parseLinkLikeSyntax(_ characters: [Character], startIndex: Int) -> (label: String, destination: String, nextIndex: Int)? {
    guard characters[startIndex] == "[" else { return nil }
    guard let closingBracket = findCharacter("]", in: characters, from: startIndex + 1) else { return nil }
    let openParen = closingBracket + 1
    guard openParen < characters.count, characters[openParen] == "(" else { return nil }
    guard let closingParen = findCharacter(")", in: characters, from: openParen + 1) else { return nil }

    let label = String(characters[(startIndex + 1) ..< closingBracket])
    let destination = String(characters[(openParen + 1) ..< closingParen])
    return (label, destination, closingParen + 1)
}

private func hasSequence(_ sequence: String, in characters: [Character], at index: Int) -> Bool {
    let pattern = Array(sequence)
    guard index + pattern.count <= characters.count else { return false }
    for offset in pattern.indices where characters[index + offset] != pattern[offset] {
        return false
    }
    return true
}

private func hasSequence(_ sequence: String, in characters: [Character], after index: Int) -> Bool {
    let pattern = Array(sequence)
    guard !pattern.isEmpty, index < characters.count else { return false }

    var current = index
    while current + pattern.count <= characters.count {
        if hasSequence(sequence, in: characters, at: current) {
            return true
        }
        current += 1
    }

    return false
}

private func findCharacter(_ character: Character, in characters: [Character], from index: Int) -> Int? {
    guard index < characters.count else { return nil }
    for current in index ..< characters.count where characters[current] == character {
        return current
    }
    return nil
}
