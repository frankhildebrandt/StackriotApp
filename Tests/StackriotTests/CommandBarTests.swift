import Foundation
import Testing
@testable import Stackriot

struct CommandBarTests {
    @Test
    func rankingPrefersFavoritesAndDirectTitleMatches() {
        let favorite = CommandBarCommand(
            id: "favorite",
            title: "Run Target starten: dev",
            subtitle: "NPM",
            category: .run,
            systemImage: "play.fill",
            keywords: ["dev", "vite"],
            action: .openQuickIntent,
            isFavorite: true
        )
        let plain = CommandBarCommand(
            id: "plain",
            title: "Repository aktualisieren",
            subtitle: "stackriot-app",
            category: .repository,
            systemImage: "arrow.clockwise",
            keywords: ["refresh"],
            action: .openQuickIntent
        )

        let ranked = CommandBarRanking.rankedCommands([plain, favorite], query: "run dev")

        #expect(ranked.first?.id == favorite.id)
    }

    @Test
    func rankingKeepsDisabledCommandsSearchableWithLowerScore() {
        let disabled = CommandBarCommand(
            id: "disabled",
            title: "Aktuelles Run Target erneut ausfuehren",
            subtitle: "Kein Run-Tab",
            category: .run,
            systemImage: "arrow.clockwise",
            keywords: ["rerun"],
            action: .openQuickIntent,
            isEnabled: false,
            disabledReason: "Kein Run-Tab"
        )

        let ranked = CommandBarRanking.rankedCommands([disabled], query: "rerun")

        #expect(ranked.count == 1)
        #expect(ranked[0].command.isEnabled == false)
    }

    @Test
    func frontmostWorkspaceContextExtractsAbsolutePathsFromWindowTitles() {
        let paths = FrontmostWorkspaceContextService.extractCandidatePaths(
            from: "stackriot-app - /Users/dev/Worktrees/stackriot-app/default-branch - Cursor"
        )

        #expect(paths.contains("/Users/dev/Worktrees/stackriot-app/default-branch"))
    }

    @Test
    func commandBarHotkeyDefaultsAreDistinctFromQuickIntent() {
        #expect(AppPreferences.defaultCommandBarHotkey != AppPreferences.defaultQuickIntentHotkey)
        #expect(AppPreferences.defaultCommandBarHotkey.isEnabled)
    }
}
