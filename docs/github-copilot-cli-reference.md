# GitHub Copilot CLI — Referenz & DevVault Integration

## Status / Migration

Das `gh copilot`-Extension (`github/gh-copilot`) wurde am **30. Oktober 2025 deprecated und archiviert**.
Es wurde durch das eigenständige **GitHub Copilot CLI** (`github/copilot-cli`) ersetzt, das von demselben agentic Harness wie Copilots Coding Agent angetrieben wird.

| Alt (archiviert) | Neu |
|---|---|
| `gh copilot suggest "..."` | `copilot` (interaktiv) |
| `gh copilot explain "..."` | `copilot -p "Explain: ..."` |
| `gh extension install github/gh-copilot` | `brew install copilot-cli` |
| Binary: `gh` | Binary: `copilot` |

DevVault verwendet seit diesem Fix: `executableName = "copilot"` und `launchCommand = "copilot"`.

---

## Installation

```bash
# macOS/Linux via Homebrew (empfohlen)
brew install copilot-cli

# macOS/Linux via curl
curl -fsSL https://gh.io/copilot-install | bash

# npm (alle Plattformen)
npm install -g @github/copilot
```

**Voraussetzungen:** Aktives GitHub Copilot-Abonnement. Beim ersten Start erscheint ein Login-Prompt
oder man setzt `GH_TOKEN` / `GITHUB_TOKEN` als Umgebungsvariable.

---

## Modi

### Interaktiver Modus (TUI)

```bash
copilot
```

Öffnet eine vollständige interaktive Chat-Session im Terminal. Innerhalb der Session:

- **Standard-Modus** (Standard): Ask & Execute — Copilot fragt bei jeder Aktion nach Bestätigung
- **Plan-Modus**: `Shift+Tab` — Copilot erstellt zuerst einen strukturierten Plan, bevor Code geschrieben wird
- **Autopilot-Modus**: `Shift+Tab` (zweimal) — Copilot arbeitet autonom bis zum Abschluss (experimentell)

Slash-Commands in der Session:

| Command | Wirkung |
|---|---|
| `/model` | Modell wechseln |
| `/allow-all` oder `/yolo` | Alle Tool-Berechtigungen für diese Session erteilen |
| `/compact` | Kontext-Fenster manuell komprimieren |
| `/context` | Token-Verbrauch anzeigen |
| `/mcp` | Verbundene MCP-Server anzeigen |
| `/experimental` | Experimentelle Features aktivieren (wird persistiert) |
| `/feedback` | Feedback senden |
| `/login` | GitHub-Authentifizierung |

### Programmatischer Modus (Non-Interactive)

```bash
# Einzelnen Task ausführen, dann beenden
copilot -p "Implementiere ein Rate-Limiting-Middleware für Express"

# Mit expliziter Tool-Erlaubnis (für Autopilot-ähnlichen Betrieb)
copilot -p "Refaktoriere src/auth.ts auf moderne async/await" --allow-all-tools

# Limit für Continuation-Steps setzen (verhindert Endlosläufe)
copilot -p "Schreibe Tests für alle Funktionen in utils/" \
  --allow-all-tools \
  --max-autopilot-continues=15

# Ausgabe als JSON (für maschinelle Weiterverarbeitung)
copilot -p "List open PRs" --output-format=json --silent
```

Stdin-Piping für Optionen (aus Script):

```bash
# Script kann Optionen ausgeben, die an copilot gepiped werden
./generate-task-options.sh | copilot
```

---

## Flags-Referenz

### Core

| Flag | Beschreibung |
|---|---|
| `-p`, `--prompt="TASK"` | Einzelner Prompt, CLI beendet sich nach Abschluss |
| `--model=NAME` | Modell setzen (Default: Claude Sonnet 4.5) |
| `--experimental` | Experimentelle Features aktivieren (wird in Config persistiert) |
| `--banner` | Splash-Screen erzwingen |

### Tool-Berechtigungen

| Flag | Beschreibung |
|---|---|
| `--allow-all-tools` | Alle Tools ohne manuelle Bestätigung erlauben |
| `--allow-tool='shell(git)'` | Spezifisches Shell-Kommando erlauben |
| `--allow-tool='shell(git push)'` | Spezifischen Subcommand erlauben |
| `--allow-tool='write'` | Datei-Schreibzugriff ohne Bestätigung |
| `--allow-tool='MCP_SERVER_NAME'` | Alle Tools eines MCP-Servers erlauben |
| `--deny-tool='shell(rm)'` | Shell-Kommando verbieten (Vorrang vor allow) |
| `--deny-tool='shell(git push)'` | Subcommand verbieten |

Kombinierbar: `--allow-all-tools --deny-tool='shell(git push)' --deny-tool='shell(rm)'`

### Pfad & Verzeichnisse

| Flag | Beschreibung |
|---|---|
| `--add-dir=/path` | Zugriff auf zusätzliches Verzeichnis gewähren |
| `--allow-all-paths` | Zugriff auf alle Pfade |
| `--disallow-temp-dir` | Temp-Verzeichnis sperren |

### Output & Logging

| Flag | Beschreibung |
|---|---|
| `--output-format=json` | JSON Lines Output |
| `--silent` | Nur Antwort, keine Stats/UI |
| `--no-color` | Keine Terminal-Farben |
| `--max-autopilot-continues=N` | Max. Continuation-Schritte begrenzen |

---

## Umgebungsvariablen

| Variable | Beschreibung |
|---|---|
| `GH_TOKEN` | GitHub-Auth-Token (höhere Priorität als `GITHUB_TOKEN`) |
| `GITHUB_TOKEN` | GitHub-Auth-Token |
| `COPILOT_GITHUB_TOKEN` | Höchste Priorität für Auth |
| `COPILOT_MODEL` | Standard-Modell überschreiben |
| `COPILOT_HOME` | Config-Verzeichnis (Default: `~/.copilot`) |
| `COPILOT_AUTO_UPDATE` | Auto-Updates deaktivieren (`false`) |

---

## Konfiguration

### User-Level (`~/.copilot/config.json`)

```json
{
  "model": "claude-sonnet-4.5",
  "auto_update": true,
  "stream": true
}
```

### Repository-Level (`.github/copilot/settings.json`)

Wird ins Repo commitet und gilt für das gesamte Team.

### Custom Instructions (`.github/copilot-instructions.md`)

Gibt Copilot zusätzlichen Kontext über das Projekt — Konventionen, Build-Befehle, Test-Strategien.
Alle Instruction-Files werden kombiniert (keine Priorisierung).

### MCP-Server (`~/.copilot/mcp-config.json`)

```json
{
  "servers": {
    "my-server": {
      "command": "node",
      "args": ["/path/to/mcp-server.js"]
    }
  }
}
```

Copilot CLI kommt mit dem GitHub MCP-Server vorinstalliert (Zugriff auf Issues, PRs, Repos).

---

## Autopilot / Plan-Modus

**Interaktiv:**
1. `copilot` starten
2. `Shift+Tab` drücken → Plan-Modus (Copilot erstellt Implementierungsplan)
3. Plan bestätigen oder verfeinern
4. Nochmals `Shift+Tab` → Autopilot-Modus (Copilot arbeitet autonom)

**Autopilot erfordert `--experimental`:**
```bash
copilot --experimental
# einmal aktiviert, ist es persistent — kein Flag mehr nötig
```

**Programmatisch (Autopilot-äquivalent):**
```bash
copilot -p "$(cat PLAN.md)" --allow-all-tools --max-autopilot-continues=20
```

---

## ACP (Agent Client Protocol)

Copilot CLI unterstützt ACP — einen offenen Standard für die programmatische Einbindung als Agent
in externe Tools und IDEs. Details: [Copilot CLI ACP server](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server).

Dieses Protokoll ermöglicht es, Copilot CLI als Sub-Agent in eigene Automatisierungspipelines
einzubinden, ohne Terminal-Emulation zu benötigen.

---

## DevVault — Aktueller Integrationsstand

### Was funktioniert

- **Interactive Launch**: `copilot` startet als vollständiger TUI-Agent im In-App-SwiftTerm-Terminal
- **Plan-Execution**: `AppModel.launchAgentWithPlan(...)` übergibt den Plan-Text via
  `copilot -p "<plan>" --allow-all-tools` — Copilot führt den Plan aus und beendet sich danach
- **Availability-Check**: `which copilot` in `AIAgentManager.checkAvailability()`
- **Session-Tracking**: PID-basiertes Polling über `refresh­Running­Agent­Worktrees()`

### Routing-Logik (`AppModel+AgentsNode.swift`)

```
initialPrompt vorhanden?
  → launchCommandWithPrompt() != launchCommand()?
      → JA: prompt via -p Flag (copilot, claude)     → kein stdin
      → NEIN: interactive launch                      → prompt via PTY stdin (codex)
initialPrompt nicht vorhanden?
  → Interactive launch (alle Tools)
```

### Noch nicht implementiert (Ideen)

- **`--experimental` / Autopilot-Modus**: Flag könnte als User-Preference pro Tool gespeichert werden
- **`--max-autopilot-continues`**: Als konfigurierbare Einstellung im Worktree-Detail
- **Custom Instructions**: `.github/copilot-instructions.md` beim Erstellen von Worktrees automatisch
  aus einem Template anlegen
- **MCP-Server-Konfiguration**: UI für `~/.copilot/mcp-config.json` in den App-Einstellungen
- **ACP-Integration**: Copilot als programmatischen Sub-Agenten ohne Terminal-Emulation ansprechen
- **Auth-Validierung**: `gh auth status` / Token-Check vor dem Launch, um sofortiges Scheitern
  mit verständlicher Fehlermeldung abzufangen
- **`--allow-tool`-Granulare Perms**: Statt `--allow-all-tools` nur git/write erlauben
  (sicherer Default für weniger erfahrene Nutzer)
