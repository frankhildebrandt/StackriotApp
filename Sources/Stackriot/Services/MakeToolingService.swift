import Foundation
struct MakeToolingService {
    func discoverTargets(in worktreeURL: URL) -> [String] {
        for fileName in ["GNUmakefile", "Makefile", "makefile"] {
            let makefileURL = worktreeURL.appendingPathComponent(fileName)
            if let contents = try? String(contentsOf: makefileURL) {
                return Self.parseTargets(from: contents)
            }
        }
        return []
    }

    static func parseTargets(from contents: String) -> [String] {
        let lines = contents.components(separatedBy: .newlines)
        let targets = lines.compactMap { line -> String? in
            guard
                !line.hasPrefix("\t"),
                !line.hasPrefix("#"),
                !line.contains("="),
                let colonIndex = line.firstIndex(of: ":")
            else {
                return nil
            }

            let target = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !target.contains("%"), !target.contains(" "), !target.hasPrefix(".") else {
                return nil
            }
            return target
        }
        return Array(Set(targets)).sorted()
    }
}
