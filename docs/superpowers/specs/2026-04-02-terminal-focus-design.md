# Terminal Focus — Jump to Session Window

**Goal:** When the user clicks a session (in popover or Session Panel), focus the existing terminal window running that Claude Code session, instead of opening a new one.

---

## Background

Current behavior: "Open Terminal" button on `EventCardView` calls `open -a Terminal <cwd>`, always opening a new window. This is disruptive — the user's Claude Code session is already running in a specific terminal window, and they just want to switch to it.

---

## Scope

**In scope:**
- Ghostty: AppleScript focus by `working directory`
- Terminal.app: AppleScript focus by `tty`
- Fallback alert when window not found
- SessionGroupView header: entire row is clickable (focus trigger)
- SessionRowView (Session Panel): entire row is clickable (focus trigger)
- Remove "Open Terminal" button from `EventCardView`
- Status label redesigned as colored capsule

**Out of scope:**
- iTerm2, Warp, or other terminal support (architecture is extensible, implementations deferred)
- In-app terminal preview
- Automatic focus on notification tap

**Prerequisites:**
- Session-grouped UI spec (`2026-04-02-menubar-session-grouped-ui.md`) must be implemented first — `SessionGroupView.swift` is created there; this spec modifies it.

---

## Design Decisions

### 1. Terminal identification

`notify.sh` injects `tty` and `terminal_app` into the hook payload at the shell level:

```bash
jq --arg tty "$(tty 2>/dev/null)" \
   --arg terminal_app "${TERM_PROGRAM:-}" \
   '. + {tty: $tty, terminal_app: $terminal_app}'
```

**`jq` dependency:** `jq` must be available on PATH. It is not bundled with macOS but is standard on developer machines (Homebrew). The installer / onboarding should check for it and warn if missing.

Known `terminal_app` values: `"ghostty"`, `"Apple_Terminal"`.

### 2. Window focus strategy (per terminal)

| Terminal | Match strategy | AppleScript API |
|----------|---------------|-----------------|
| Ghostty | `working directory` == session `cwd` | `select tab t` + `activate window w` |
| Terminal.app | `tty` == session `tty` | `tab whose tty is X` → `set selected` |

No Accessibility permissions required for either.

**Ghostty edge case:** Two sessions with the same `cwd` → first matching tab wins. Acceptable: rare in practice.

### 3. Fallback behavior

Focus fails (window not found / app not running):

```
"Terminal window not found"
"The terminal running <project> may have been closed. Open a new window instead?"
[Cancel]  [Open New Window]
```

"Open New Window" → existing `openTerminal(at: cwd)` logic (opens Ghostty/Terminal.app at cwd).

### 4. UI interaction model

**Both surfaces use the same pattern:** entire session row is the tap target, `↗` is a visual affordance only (not an independent button).

**SessionGroupView header:**
```
● my-saas   [needs input capsule]  ↗
● agent-dev-pilot  [running capsule]  ↗
```

**SessionRowView (Session Panel):**
```
● agent-dev-pilot   started 12m ago   [running capsule]  ↗
● my-saas           started 3m ago    [needs input capsule]  ↗
```

**Status capsule colors:**
- `waiting` / needs input: red `#FF453A`, background `rgba(255,69,58,0.15)`, border `rgba(255,69,58,0.35)`
- `running`: amber `#FF9F0A`, background `rgba(255,159,10,0.15)`, border `rgba(255,159,10,0.35)`

This replaces the plain text status label in both the current `SessionGroupView` spec and `SessionRowView`.

### 5. EventCardView

Remove the "Open Terminal" `Button` from `EventCardView`. Session-level navigation supersedes event-level navigation.

---

## Architecture

### Data layer

**`HookPayload`** — two new optional fields:
```swift
public let tty: String?           // e.g. "/dev/ttys003"
public let terminalApp: String?   // e.g. "ghostty", "Apple_Terminal"
```

**`DevSession`** — two new optional columns (v4 migration):
```swift
public var tty: String?
public var terminalApp: String?
```

`SessionLifecycleService.handleSessionLifecycle()` writes both at `SessionStart`.

### Service layer (`Sources/App/Services/TerminalFocus/`)

```swift
public protocol TerminalFocuser {
    func focus(cwd: String, tty: String?) throws -> Bool
}

public struct GhosttyFocuser: TerminalFocuser      // AppleScript, cwd match
public struct TerminalAppFocuser: TerminalFocuser  // AppleScript, tty match

public final class TerminalFocusService {
    public static func focus(session: DevSession) throws -> FocusResult
}

public enum FocusResult { case success, notFound }
```

`TerminalFocusService.focus()` dispatches on `session.terminalApp`. Unknown values default to `GhosttyFocuser`.

**Location:** `Sources/App/` — AppleScript execution is macOS app-only behavior, not appropriate for `Core`.

### UI layer

**`SessionGroupView`** — header row becomes a `Button` wrapping the entire HStack. Status text → capsule. `↗` label appended (opacity 0.2).

**`SessionRowView`** — same pattern. Existing "Open Terminal" button (if any) removed.

**`EventCardView`** — remove the `if event.attentionTier == .action || event.type == .taskError` button block.

**Alert** — follows the existing `onOpenTerminal` callback pattern. `SessionGroupView` and `SessionRowView` receive an `onFocusSession: (DevSession) -> Void` closure. `AgentDevPilotApp` owns the implementation: call `TerminalFocusService.focus(session:)`; on `.notFound`, show `NSAlert` and offer to call `openTerminal(at: session.cwd ?? "")`.

```swift
// In AgentDevPilotApp
onFocusSession: { session in
    let result = try? TerminalFocusService.focus(session: session)
    if result == .notFound {
        // show NSAlert → "Open New Window" calls openTerminal(at: session.cwd ?? "")
    }
}
```

---

## File map

| File | Change |
|------|--------|
| `Resources/notify.sh` | Inject `tty` and `terminal_app` via `jq` |
| `Sources/Core/Models/HookPayload.swift` | Add `tty`, `terminalApp` optional fields |
| `Sources/Core/Models/DevSession.swift` | Add `tty`, `terminalApp` optional columns |
| `Sources/Core/Store/DatabaseManager.swift` | Add `v4_session_terminal` migration |
| `Sources/Core/Services/SessionLifecycleService.swift` | Write `tty`/`terminalApp` at SessionStart |
| `Sources/App/Services/TerminalFocus/TerminalFocuser.swift` | Protocol definition |
| `Sources/App/Services/TerminalFocus/GhosttyFocuser.swift` | Ghostty AppleScript implementation |
| `Sources/App/Services/TerminalFocus/TerminalAppFocuser.swift` | Terminal.app AppleScript implementation |
| `Sources/App/Services/TerminalFocus/TerminalFocusService.swift` | Dispatcher + FocusResult |
| `Sources/App/Views/SessionGroupView.swift` | Header row → Button, status → capsule, ↗ hint |
| `Sources/App/Views/SessionPanelView.swift` / `SessionRowView.swift` | Row → Button, status → capsule, ↗ hint |
| `Sources/App/Views/EventCardView.swift` | Remove "Open Terminal" button |

---

## Not in scope (v3 backlog)

- iTerm2 / Warp support (add new `TerminalFocuser` impl, update `TERM_PROGRAM` mapping)
- Ghostty tab-level precision via future Ghostty IPC API (Discussion #3782 + #2353)
- Automatic focus when notification is tapped

---

## Success criteria

1. Clicking a running session in popover or Session Panel focuses the existing terminal window
2. Ghostty: correct window comes to front when multiple windows are open (cwd match)
3. Terminal.app: correct tab comes to front (tty match)
4. Window not found → NSAlert with "Open New Window" option
5. EventCardView has no "Open Terminal" button
6. Status labels are colored capsules in both popover and Session Panel
7. All existing tests pass; new unit tests cover `GhosttyFocuser`, `TerminalAppFocuser`, and `TerminalFocusService` dispatch logic
