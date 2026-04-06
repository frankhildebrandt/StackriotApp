import Foundation

struct RunConfigurationMenuSection: Identifiable {
    let id: String
    let title: String
    let configurations: [RunConfiguration]
}

enum RunConfigurationMenuGrouping {
    static func sections(for configurations: [RunConfiguration]) -> [RunConfigurationMenuSection] {
        let grouped = Dictionary(grouping: configurations, by: { $0.menuSectionKey })

        return grouped.keys
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.sortOrder < rhs.sortOrder
            }
            .compactMap { key in
                guard let configurations = grouped[key], !configurations.isEmpty else {
                    return nil
                }

                return RunConfigurationMenuSection(
                    id: key.id,
                    title: key.title,
                    configurations: configurations.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                )
            }
    }
}

private struct RunConfigurationMenuSectionKey: Hashable {
    let id: String
    let title: String
    let sortOrder: Int
}

private extension RunConfiguration {
    var menuSectionKey: RunConfigurationMenuSectionKey {
        switch source {
        case .native:
            switch kind {
            case .makeTarget:
                return RunConfigurationMenuSectionKey(id: "native-make", title: "Make", sortOrder: 0)
            case .npmScript:
                return RunConfigurationMenuSectionKey(id: "native-npm", title: "NPM", sortOrder: 1)
            case .shellCommand, .nodeLaunch, .xcodeScheme, .jetbrainsConfiguration:
                return RunConfigurationMenuSectionKey(
                    id: "native-other",
                    title: source.displayName,
                    sortOrder: 2
                )
            }
        case .vscode:
            return RunConfigurationMenuSectionKey(id: "vscode", title: source.displayName, sortOrder: 3)
        case .cursor:
            return RunConfigurationMenuSectionKey(id: "cursor", title: source.displayName, sortOrder: 4)
        case .jetbrains:
            return RunConfigurationMenuSectionKey(
                id: "jetbrains-\(preferredDevTool?.rawValue ?? "unknown")",
                title: displaySourceName,
                sortOrder: 5 + (preferredDevTool?.sortPriority ?? 0)
            )
        case .xcode:
            return RunConfigurationMenuSectionKey(id: "xcode", title: source.displayName, sortOrder: 20)
        }
    }
}
