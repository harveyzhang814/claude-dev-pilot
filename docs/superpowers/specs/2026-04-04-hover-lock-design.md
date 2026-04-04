# Hover Lock Feature Design

**Date:** 2026-04-04
**Branch:** `fix/float-window-compact-jump` (or new feature branch from staging)
**Status:** Approved

---

## Overview

Add a lock icon button to the Float Window Hover View toolbar. When locked, the window stays in Hover View permanently — bypassing the Compact state and ignoring mouse-exit collapse. The lock preference persists across app restarts via UserDefaults.

---

## Architecture

### State Storage — `FloatWindowDisplayState`

Add `isHoverLocked: Bool` with UserDefaults persistence:

```swift
var isHoverLocked: Bool = UserDefaults.standard.bool(forKey: "floatWindowHoverLocked") {
    didSet { UserDefaults.standard.set(isHoverLocked, forKey: "floatWindowHoverLocked") }
}
```

UserDefaults key: `floatWindowHoverLocked` (default: `false`)

### State Machine — `FloatWindowController`

Four changes to respect the lock:

| Location | Unlocked behavior | Locked behavior |
|---|---|---|
| `updateFromViewModel` `.hidden` case | `hasSessions && hasEvents` → `.compact` | `hasSessions && hasEvents` → `.hover` |
| `updateFromViewModel` `.compact` case | stay compact, resize only | auto-transition to `.hover` |
| `handleMouseExit` | schedule 1s collapse timer | skip — no timer started |
| Lock toggled ON | — | if currently `.compact` → immediately transition to `.hover` |

Lock toggled OFF: no forced state change. Window stays in hover until next mouse exit, which triggers the normal 1s collapse.

### UI — `FloatWindowHoverView` Toolbar

Lock button added next to the gear icon (left side of toolbar):

```
[gear] [lock]   ·····Spacer·····   [expand]
```

Props added to `FloatWindowHoverView`:
- `isLocked: Bool` — drives icon and tint
- `onToggleLock: () -> Void` — callback, consistent with existing `onExpand` pattern

Icon states:
- Unlocked: `lock` SF symbol, color `.secondary`
- Locked: `lock.fill` SF symbol, color `.primary`

`FloatWindowRootView` reads `displayState.isHoverLocked` and passes it + a toggle closure down to `FloatWindowHoverView`.

---

## Data Flow

```
User taps lock button
  → onToggleLock() callback
  → FloatWindowController toggles displayState.isHoverLocked
  → UserDefaults persisted immediately (didSet)
  → if locking and currentState == .compact → transition(to: .hover)
  → FloatWindowHoverView re-renders with new isLocked (via displayState observation)
```

---

## Edge Cases

- **Locked + no sessions**: Lock has no visible effect; window transitions to `.hidden` normally (existing behavior unchanged).
- **Locked + app restart**: `isHoverLocked` loads from UserDefaults. First appearance with sessions goes directly to `.hover`.
- **Unlock while in hover**: Window stays in hover. Next mouse exit triggers normal 1s collapse to compact.
- **Unlock while in expanded**: No change. Expanded has its own collapse logic (mouse exit → compact), unaffected by lock.
- **Lock toggled ON while in expanded**: No forced state change. Lock takes effect next time the window is in compact or hover state.

---

## Files Changed

| File | Change |
|---|---|
| `FloatWindowDisplayState.swift` | Add `isHoverLocked` with UserDefaults persistence |
| `FloatWindowController.swift` | 4 changes to state machine (see above) |
| `FloatWindowHoverView.swift` | Add `isLocked` + `onToggleLock` props; render lock button in toolbar |
| `FloatWindowController.swift` (FloatWindowRootView) | Pass `isLocked` + toggle closure to `FloatWindowHoverView` |

---

## Testing

- Toggle lock on/off and verify hover persists / collapses as expected
- Restart app with lock on → verify window opens directly in hover when sessions present
- Restart app with lock off → verify normal compact → hover on mouse enter behavior
- Verify UserDefaults key `floatWindowHoverLocked` is written on toggle
