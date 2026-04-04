# TODOS

## FloatWindow

### collapseTimer scheduled on .default run loop mode

**Priority:** P2
**Component:** FloatWindow / FloatWindowController

`collapseTimer` is created with `Timer.scheduledTimer(withTimeInterval:...)` which schedules on `.default` run loop mode. When the user is actively moving the mouse, AppKit runs in `.eventTracking` mode and the timer will not fire until mouse movement stops. The 1-second collapse delay can become unbounded if the user is hovering and moving the mouse continuously before exiting the panel.

**Fix:** Create the timer manually and add it with `RunLoop.main.add(timer, forMode: .common)`.

**File:** `Sources/App/FloatWindow/FloatWindowController.swift` — `scheduleCollapse()`
**Found by:** adversarial review on 2026-04-03 (branch: fix/float-window-height-review)

---

## Cursor Integration

### HookInstaller: installCursorScript() 调用时机

**Priority:** P2
**Component:** Core/Services/HookInstaller, App/Settings

目前 `installCursorScript()` 已定义但没有任何地方调用它。何时安装 Cursor hook 脚本尚未决定：随 Claude Code hook 一起安装（Settings 一次完成），还是独立的 Cursor onboarding 入口。

**影响：** 决定会影响 Settings 页面 UI 设计——是一个统一的 "Install All Hooks" 按钮，还是两个独立的安装入口。

**当前状态：** MVP 实现中暂时不调用；脚本存在于 `~/.agent-dev-pilot/hooks/cursor-notify.sh` 但需要用户手动触发或随 Claude Code 安装一起处理。

**建议下一步：** 实现 Settings UI 时决定是否合并。参考 `HookInstaller.installScript()` 的调用位置作为参照。
**File:** `Sources/Core/Services/HookInstaller.swift`, `Sources/App/Views/Settings`
**Found by:** /plan-eng-review on 2026-04-03 (branch: staging, Cursor integration design)

---

### tool field validation on /event endpoint

**Priority:** P3
**Component:** Server/EventHandler

`HookPayload.tool` is decoded from the raw POST body. Any localhost process with a valid token can inject `"tool": "cursor"` into a Claude Code `/event` request and mis-tag the session. The default `notify.sh` doesn't set this field (so it defaults to "claude-code"), but there is no server-side allowlist validation. An unexpected tool value (e.g. "vscode") silently falls through to `default: return nil` in `sessionToolBadge` and is never surfaced.

**Fix:** Validate `tool` against an allowlist `["claude-code", "cursor"]` in `postEvent`. Unknown values should be coerced to `"claude-code"` with a HookLog warning.

**File:** `Sources/Server/EventHandler.swift`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

### postEvent / postCursorEvent pipeline duplication

**Priority:** P3
**Component:** Server/EventHandler

The two handlers share ~60 lines of near-identical logic (body collection, parse, HookLog, lifecycle routing, stop window, onEvent). Any future change (new HookLog fields, error enrichment, new event types) must be applied to both. Already diverging: comments removed from `postEvent` in this diff.

**Fix:** Extract a `processParsedPayload(decoded:, db:, stopWindow:, onEvent:)` internal helper. Both handlers call it after their respective parsing step.

**File:** `Sources/Server/EventHandler.swift`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

### StopWindowService: timer may fire after SessionEnd (race condition)

**Priority:** P2
**Component:** Core/Services/StopWindowService

If Cursor sends `stop` and then `sessionEnd` within the 2-second window, `StopWindowService.flush()` fires after `SessionEnd` has already marked the session `.completed`. The current UPDATE guard (`NOT IN ('completed', 'stale')`) prevents the state from being overwritten, and `db.changesCount == 0` prevents the phantom event card — but the `onIdleResolved` callback (which fires the macOS push notification) still runs unconditionally after the flush. This means Cursor users may see a spurious "Cursor is ready" macOS notification even though the session has ended.

**Fix:** Add a `cancelWindow(for sessionId: String)` method to `StopWindowService` that cancels and removes the window entry. Call it from `SessionLifecycleService` when processing `SessionEnd` so a pending timer is cancelled before it fires.

**File:** `Sources/Core/Services/StopWindowService.swift`, `Sources/Core/Services/SessionLifecycleService.swift`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

### hook_logs: inconsistent hookEventName casing between Claude Code and Cursor paths

**Priority:** P3
**Component:** Server/EventHandler, Core/Models/HookLog

Claude Code hooks log PascalCase names (`"Stop"`, `"SessionStart"`) because `HookPayload` carries them already normalized. Cursor hooks log camelCase names (`"stop"`, `"sessionStart"`) because the `HookLog` is written from the raw `CursorHookPayload` *before* `CursorNormalizer.normalize()` is called. Any tooling or debugging workflow that queries `hook_logs` by `hookEventName` must know which path produced the row.

**Fix:** Either log the normalized name for Cursor (move HookLog insertion after `normalize()`) or add a `source` column to `hook_logs` (`"claude-code"` / `"cursor"`) so queries can filter appropriately. The latter preserves the "raw before normalization" audit intent.

**File:** `Sources/Server/EventHandler.swift` — `postCursorEvent`, `Sources/Core/Models/HookLog.swift`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

### cursor-notify.sh: stdin pipe assumption needs live Cursor verification

**Priority:** P2
**Component:** Core/Services/HookInstaller (cursor-notify.sh)

`cursor-notify.sh` reads the hook payload from stdin via `stdin_data=$(cat)`. This pattern works for Claude Code hooks (which pipe JSON over stdin). Cursor's hook invocation contract is not verified — if Cursor calls the script without piping JSON (or pipes it differently), `stdin_data` will be empty and the POST body will be `{}`, resulting in a PARSE_ERROR log entry. No live Cursor testing has been done.

**Fix:** Verify with a real Cursor installation. Add a fallback: if `stdin_data` is empty, log the absence and exit 0 silently rather than POSTing an empty body. Consider adding a `cursor_hook_test.sh` smoke test that simulates the Cursor invocation pattern.

**File:** `Sources/Core/Services/HookInstaller.swift` — `cursorScriptContent`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

### cursor-notify.sh: tilde in hook path may not expand in Cursor hook invocation

**Priority:** P2
**Component:** Core/Services/HookInstaller (cursor-notify.sh), HookInstaller.cursorAgentPrompt()

`HookInstaller.cursorAgentPrompt()` instructs Cursor Agent to register the hook as `~/.agent-dev-pilot/hooks/cursor-notify.sh`. Tilde expansion is a shell feature — if Cursor invokes hooks without a shell (e.g. via `execve` directly), the literal string `~/.agent-dev-pilot/hooks/cursor-notify.sh` will fail with "file not found". This is untested with a real Cursor installation.

**Fix:** Use the absolute path (`/Users/<username>/.agent-dev-pilot/hooks/cursor-notify.sh`) in the hook registration prompt. `HookInstaller.cursorAgentPrompt()` can expand `~` via `FileManager.default.homeDirectoryForCurrentUser` at generation time.

**File:** `Sources/Core/Services/HookInstaller.swift` — `cursorAgentPrompt()`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

## Completed
