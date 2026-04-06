# Stackriot

**Stackriot** ist eine native macOS-App (macOS 14+) für Entwickler, die mit mehreren Git-Branches gleichzeitig arbeiten. Sie kombiniert ein Git-Worktree-Management mit IDE-Integration, KI-Agenten, Node.js-Tooling und einem integrierten Run-Terminal – alles in einer übersichtlichen drei-spaltigen Oberfläche.

---

## Features

### Git-Repository- & Worktree-Management
- Klont Repositories als **Bare-Repositories** und verwaltet beliebig viele **Git Worktrees** pro Repository
- Erstellt neue Worktrees inkl. Branch-Anlage direkt aus der App
- Zeigt Worktree-Status: uncommitted changes, ahead/behind-Zähler, Konflikte
- Erkennt Abweichungen zum Default-Branch und bietet Rebase/Merge-Workflows an
- Integriert Worktrees zurück in den Default-Branch (inkl. Konflikt-Handling)
- Löscht Worktrees inkl. lokalem Branch nach dem Mergen

### Organisation
- Repositories lassen sich in **Namespaces** und **Projekte** gruppieren
- Mehrere Remotes pro Repository konfigurierbar (inkl. SSH-Key-Zuweisung pro Remote)
- Auto-Refresh aller Repositories im Hintergrund (konfigurierbares Intervall)

### IDE-Integration
- Öffnet Worktrees direkt in **VS Code**, **Cursor** oder **Codex App** per Klick
- Öffnet Worktrees in **Terminal.app**
- Zeigt den Worktree-Pfad im Finder an

### KI-Agenten
- Weist jedem Worktree einen **AI-Agent** zu: Claude Code, Codex, GitHub Copilot CLI, Cursor CLI oder OpenCode
- Startet den Agenten per AppleScript in einem Terminal.app-Fenster
- Überwacht den laufenden Agenten-Prozess via PID-Polling
- Zeigt laufende Agenten mit einem animierten **lila Indikator** in der Sidebar und in der Worktree-Liste

### Aktionen & Run-Konsole
- Führt Aktionen in Worktrees aus: **Make-Targets**, **npm/pnpm/yarn-Scripts**, **Dependency-Installation**, **Git-Operationen**
- Zeigt die Ausgabe jeder Aktion in einem integrierten **Terminal-Tab** (SwiftTerm-basiert)
- Verwaltet mehrere Tabs pro Worktree mit Tab-Pinning und konfigurierbarem Retention-Modus
- Speichert alle Runs mit Status (pending, running, succeeded, failed, cancelled) in SwiftData

### Node.js-Tooling
- Verwaltet eine **nvm**-kompatible Node.js-Runtime automatisch (lts/* als Standard)
- Erkennt die benötigte Node-Version aus `package.json` (`engines`-Feld), `.nvmrc` oder `.node-version`
- Unterstützt npm, pnpm und yarn inkl. Corepack
- Automatische Runtime-Updates im Hintergrund

### SSH-Key-Management
- Generiert und importiert SSH-Keys, speichert sie sicher im **Keychain**
- Konfiguriert die SSH-Umgebung für alle Git-Operationen automatisch

### GitHub CLI-Integration
- Löst PRs und Remote-Informationen über die GitHub CLI auf

---

## Architektur

| Schicht | Details |
|---|---|
| Plattform | macOS 14+, Swift 6, SwiftUI, SwiftData |
| UI | Drei-spaltige `NavigationSplitView`: Sidebar → Repository-Detail → Run-Konsole |
| State | `AppModel` (SwiftUI `@Observable`) als zentraler App-State |
| Services | `RepositoryManager`, `WorktreeManager`, `IDEManager`, `AIAgentManager`, `NodeToolingService`, `SSHKeyManager`, `GitHubCLIService`, `MakeToolingService`, `DevContainerService` |
| Persistenz | SwiftData (Bare-Repository-Pfade, Worktrees, SSH-Keys, Runs, Action-Templates) |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (Vendor-Abhängigkeit) |

---

## Voraussetzungen

- macOS 14 (Sonoma) oder neuer
- Xcode 16+ mit Swift 6
- Optionale CLI-Tools (je nach genutzter Funktion): `git`, `gh`, `node`/`nvm`, `make`, `claude`, `codex`, `cursor`, `docker`, `devcontainer` oder `npx`

---

## Build

```bash
swift build
```

Oder das Xcode-Projekt `Stackriot.xcodeproj` öffnen und dort bauen.

### Packaging

```bash
make production
make production-build
make dmg
```

- `make production` exportiert einen portablen Production-Build nach `build/production/Stackriot.app` und erstellt zusätzlich `build/production/Stackriot.zip` für die Weitergabe an andere Macs
- `make production-build` baut ein Release-App-Bundle nach `build/DerivedData/Build/Products/Release/Stackriot.app`
- `make dmg` erzeugt ein klassisches macOS-DMG mit Drag-&-Drop-Installationshilfe, Hintergrundbild und `README.md` unter `build/dmg/Stackriot.dmg`

---

## Lizenz

Dieses Projekt enthält keinen expliziten Lizenzeintrag.
