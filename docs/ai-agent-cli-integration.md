# AI Agent CLI Integration — Feature Plan

## Übersicht

Integration von AI CLI Tools (Claude Code, Codex, GitHub Copilot CLI, Cursor) in DevVault, sodass pro Worktree ein AI Agent zugewiesen und gestartet werden kann. Laufende Agents werden im Repository- und Worktree-Level visuell signalisiert.

---

## Architektur-Entscheidungen

### Launch-Strategie: Terminal.app via AppleScript

Statt einem In-App-Terminal-Emulator wird Terminal.app per AppleScript geöffnet.

**Begründung:**
- AI CLIs brauchen echte TTY-Unterstützung (interactive prompts, readline, etc.)
- Kein Scope für PTY/ANSI-Handling in SwiftUI
- Passt zum bestehenden `IDEManager`-Muster (`open -a`)
- ~50 Zeilen Code statt 500+

### Laufzeit-Detection: PID-Polling

PID-Ermittlung via Temp-File (`/tmp/dv_agent_<uuid>.pid`) — das Terminal-Startskript schreibt `echo $$ >` in die Datei. Danach prüft ein Swift-Task alle 2 Sekunden via `kill(pid, 0)` ob der Prozess noch läuft.

**Begründung:**
- Signal 0 prüft Prozess-Existenz ohne tatsächliches Signal
- Einfacher als `kqueue`/`EVFILT_PROC` unter Swift 6 strict concurrency
- 2-Sekunden-Latenz beim Erkennen des Prozess-Endes ist für den User nicht spürbar

---

## Implementierungsschritte

### Schritt 1 — `Domain.swift`: Neue Typen

**`AIAgentTool`** — persistiertes Enum für die Tool-Zuweisung pro Worktree:

```swift
enum AIAgentTool: String, Codable, CaseIterable, Identifiable {
    case none
    case claudeCode
    case codex
    case githubCopilot
    case cursorCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:          "None"
        case .claudeCode:    "Claude Code"
        case .codex:         "Codex"
        case .githubCopilot: "GitHub Copilot"
        case .cursorCLI:     "Cursor CLI"
        }
    }

    /// Primärer Executable-Name für Availability-Checks und Launch.
    var executableName: String? {
        switch self {
        case .none:          nil
        case .claudeCode:    "claude"
        case .codex:         "codex"
        case .githubCopilot: "gh"       // invoked as: gh copilot suggest
        case .cursorCLI:     "cursor"
        }
    }

    /// Vollständiger Shell-Befehl zum Starten des Agents im gegebenen Verzeichnis.
    func launchCommand(in path: String) -> String {
        switch self {
        case .none:          ""
        case .claudeCode:    "cd \(path.shellEscaped) && claude"
        case .codex:         "cd \(path.shellEscaped) && codex"
        case .githubCopilot: "cd \(path.shellEscaped) && gh copilot suggest"
        case .cursorCLI:     "cd \(path.shellEscaped) && cursor ."
        }
    }
}
```

`String.shellEscaped` — wraps path in single quotes, escapes embedded single quotes (2-Zeilen-Extension).

**`AgentSessionState`** — reiner Runtime-State (nicht persistiert):

```swift
struct AgentSessionState: Sendable {
    let worktreeID: UUID
    let tool: AIAgentTool
    var pid: pid_t          // Shell-PID aus /tmp PID-File
    let startedAt: Date
    var phase: AgentSessionPhase
}

enum AgentSessionPhase: Sendable {
    case launching
    case running
    case finished(exitCode: Int32?)
    case errored(String)
}
```

---

### Schritt 2 — `Models.swift`: `WorktreeRecord` erweitern

Neues Feld `assignedAgentRawValue: String` mit Default `"none"`.

SwiftData behandelt das als **lightweight migration** (additiv, kein `MigrationPlan` nötig).

```swift
@Model
final class WorktreeRecord {
    // ... bestehende Felder unverändert ...
    var assignedAgentRawValue: String   // neu, default "none"

    var assignedAgent: AIAgentTool {
        get { AIAgentTool(rawValue: assignedAgentRawValue) ?? .none }
        set { assignedAgentRawValue = newValue.rawValue }
    }
}
```

---

### Schritt 3 — `Services.swift`: `AIAgentManager`

Drei Verantwortlichkeiten:

#### Availability-Check

```swift
func checkAvailability() async -> Set<AIAgentTool> {
    // which <executable> via CommandRunner für alle Tools
}
```

#### Launch via AppleScript

```swift
func launchAgent(_ tool: AIAgentTool, for worktree: WorktreeRecord) throws -> AgentSessionState {
    let pidFile = "/tmp/dv_agent_\(worktree.id.uuidString).pid"
    let shellCmd = "echo $$ > \(pidFile); \(tool.launchCommand(in: worktree.path))"
    let appleScript = """
        tell application "Terminal"
            activate
            do script "\(shellCmd.appleScriptEscaped)"
        end tell
        """
    // NSAppleScript ausführen, dann PID-File nach 600ms lesen
    // → startPolling(pid:worktreeID:) starten
}
```

#### PID-Polling

```swift
private func startPolling(pid: pid_t, worktreeID: UUID) {
    Task { [weak self] in
        while true {
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            if kill(pid, 0) != 0 {
                // Prozess beendet
                activeSessions.removeValue(forKey: worktreeID)
                return
            }
        }
    }
}
```

#### Session-Registry

```swift
private(set) var activeSessions: [UUID: AgentSessionState] = [:]

func isAgentRunning(for worktreeID: UUID) -> Bool { ... }

func isAgentRunning(forAnyWorktreeIn repository: ManagedRepository) -> Bool {
    repository.worktrees.contains { isAgentRunning(for: $0.id) }
}
```

---

### Schritt 4 — `AppModel.swift`: Integration

```swift
@MainActor
@Observable
final class AppModel {
    // ... bestehende Properties ...
    private(set) var agentManager = AIAgentManager()
    var availableAgents: Set<AIAgentTool> = []

    func checkAgentAvailability() async {
        availableAgents = await agentManager.checkAvailability()
    }

    func launchAgent(for worktree: WorktreeRecord) {
        guard worktree.assignedAgent != .none else { return }
        do {
            try agentManager.launchAgent(worktree.assignedAgent, for: worktree)
        } catch {
            pendingErrorMessage = error.localizedDescription
        }
    }

    func assignAgent(_ tool: AIAgentTool, to worktree: WorktreeRecord, in modelContext: ModelContext) {
        worktree.assignedAgent = tool
        try? modelContext.save()
    }

    func isAgentRunning(for worktree: WorktreeRecord) -> Bool {
        agentManager.isAgentRunning(for: worktree.id)
    }

    func isAgentRunning(forRepository repo: ManagedRepository) -> Bool {
        agentManager.isAgentRunning(forAnyWorktreeIn: repo)
    }
}
```

---

### Schritt 5 — `RootView.swift`: UI-Komponenten

#### `AgentActivityDot` — Animierter Indikator

Lila gewählt, da klar unterschieden von bestehenden Status-Farben (grün = healthy, orange = warning):

```swift
private struct AgentActivityDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.purple)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing ? 1.35 : 0.85)
            .opacity(pulsing ? 1.0 : 0.5)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
```

#### Sidebar: Repository-Zeile

`AgentActivityDot` einblenden wenn `appModel.isAgentRunning(forRepository: repository)` true ist.

#### Worktree-Liste: Worktree-Zeile

`AgentActivityDot` einblenden wenn `appModel.isAgentRunning(for: worktree)` true ist.

#### `AgentAssignmentRow` — Agent-Zuweisung im Worktree-Detail

```swift
private struct AgentAssignmentRow: View {
    let worktree: WorktreeRecord
    let availableAgents: Set<AIAgentTool>
    let isRunning: Bool
    let onAssign: (AIAgentTool) -> Void
    let onLaunch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("AI Agent", selection: ...) {
                ForEach(AIAgentTool.allCases) { tool in
                    // Nicht-installierte Tools: "(not found)" Label
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)

            if worktree.assignedAgent != .none {
                Button { onLaunch() } label: {
                    Label(
                        isRunning ? "Running" : "Launch Agent",
                        systemImage: isRunning ? "terminal.fill" : "terminal"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)
                .tint(isRunning ? .purple : .accentColor)
            }

            if isRunning { AgentActivityDot() }
        }
    }
}
```

Die `AgentAssignmentRow` erscheint in `actionSection(for:)` oberhalb der bestehenden IDE-Buttons.

---

### Schritt 6 — Startup (`RootView.swift`)

In `.task` ergänzen:

```swift
.task {
    appModel.configure(modelContext: modelContext)
    appModel.selectInitialRepository(from: repositories)
    await appModel.checkAgentAvailability()   // neu
}
```

---

### Schritt 7 — Entitlements

Für Apple Events an Terminal.app in der `.entitlements`-Datei:

```xml
<key>com.apple.security.automation.apple-events</key>
<true/>
```

Falls App Store-Distribution: zusätzlich Temporary Exception für `com.apple.Terminal`.

> Bei einem Developer-Tool ohne Mac App Store Distribution kann die Sandbox auch ganz deaktiviert werden.

---

## Trade-off-Übersicht

| Thema | Entscheidung | Begründung |
|---|---|---|
| Launch | Terminal.app via AppleScript | Echter TTY, ~50 Zeilen Code statt 500+ |
| PID-Tracking | `/tmp` PID-File + 2s-Poll | Einfacher als kqueue, Latenz unspürbar |
| Sessions | 1 Session pro Worktree | Natürliches Mental-Modell |
| Tool-Enum | `none` als expliziter Case | Einfache Picker-Bindung, kein `Optional` |
| Nicht-installierte Tools | Wählbar aber `(not found)` | Kein Verwirrung bei nachträglicher Installation |

---

## Implementierungsreihenfolge

1. `Sources/DevVault/Domain.swift` — `AIAgentTool` + `AgentSessionState` + String-Extensions
2. `Sources/DevVault/Models.swift` — `WorktreeRecord.assignedAgentRawValue`
3. `Sources/DevVault/Services.swift` — `AIAgentManager`
4. `Sources/DevVault/AppModel.swift` — Integration der neuen Service-Methoden
5. `Sources/DevVault/RootView.swift` — `AgentActivityDot`, `AgentAssignmentRow`, Sidebar-Indikatoren
6. `DevVault.entitlements` — Apple Events Berechtigung
