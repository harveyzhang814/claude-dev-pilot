# Menubar Tap → Reveal Float Window (with Border Pulse)

**Date:** 2026-04-05
**Status:** Approved

## Problem

In Float Window mode, clicking the Menu Bar icon calls `toggleExpanded()`, which unconditionally switches the window to `.expanded` state regardless of current state. The expected behavior is to only *reveal* the window (show it if hidden), not force-expand it.

## Desired Behavior

| Current State | After Menubar Tap |
|---|---|
| `.hidden` | Show window → transition to `.compact` (or `.hover` if hoverLocked) |
| `.compact` | Stay in `.compact`, play border pulse animation |
| `.hover` | Stay in `.hover`, play border pulse animation |
| `.expanded` | Stay in `.expanded`, play border pulse animation |

## Animation: Border Pulse

When the window is already visible, a blue border glow briefly appears and fades out over 0.7s — matching the style previewed in the HTML prototype.

- Color: `rgb(99, 179, 243)` (iOS blue)
- Stroke width: 2pt
- Glow shadow: radius 8, same color at 40% opacity
- Duration: 0.7s ease-out fade-out
- Shape: `Capsule` in compact mode, `RoundedRectangle(cornerRadius: 12)` in hover/expanded

## Architecture

### `FloatWindowDisplayState`
Add one new property:
```swift
var isPulsing: Bool = false
```
The controller writes this; the view reads it.

### `FloatWindowController`
- Rename `toggleExpanded()` → `reveal()`
- New logic:
  - `.hidden` → `transition(to: isHoverLocked ? .hover : .compact)`
  - `.compact` / `.hover` / `.expanded` → `triggerPulse()`
- Add `triggerPulse()`:
  - Resets `isPulsing = false` then sets `isPulsing = true` (handles rapid re-triggers)
  - Schedules `isPulsing = false` after 0.75s (50ms buffer after 0.7s animation)

### `AppState`
- Rename `toggleFloatWindowExpanded()` → `revealFloatWindow()`
- Calls `floatWindowController?.reveal()`

### `AgentDevPilotApp` — `FloatWindowMenubarTap`
- Change call from `appState.toggleFloatWindowExpanded()` → `appState.revealFloatWindow()`

### `FloatWindowRootView`
Add a pulse overlay on top of content, shape-matched to the current mode:
```swift
.overlay(
    Group {
        if displayState.mode == .compact {
            Capsule()
                .strokeBorder(pulseColor.opacity(displayState.isPulsing ? 0.9 : 0), lineWidth: 2)
                .shadow(color: pulseColor.opacity(displayState.isPulsing ? 0.4 : 0), radius: displayState.isPulsing ? 8 : 0)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(pulseColor.opacity(displayState.isPulsing ? 0.9 : 0), lineWidth: 2)
                .shadow(color: pulseColor.opacity(displayState.isPulsing ? 0.4 : 0), radius: displayState.isPulsing ? 8 : 0)
        }
    }
    .animation(.easeOut(duration: 0.7), value: displayState.isPulsing)
)
```

## Edge Cases

- **Rapid re-tap**: `triggerPulse()` resets `isPulsing` to `false` before setting to `true`, forcing SwiftUI to re-observe the change and restart the animation.
- **Hidden state**: `reveal()` shows the window; no pulse plays (pulse only fires for visible states).
- **hoverLocked + hidden**: `reveal()` transitions to `.hover` directly (respects the lock).

## Files Changed

| File | Change |
|---|---|
| `Sources/App/FloatWindow/FloatWindowDisplayState.swift` | Add `isPulsing: Bool` |
| `Sources/App/FloatWindow/FloatWindowController.swift` | Rename `toggleExpanded()` → `reveal()`, add `triggerPulse()` |
| `Sources/App/AppState.swift` | Rename `toggleFloatWindowExpanded()` → `revealFloatWindow()` |
| `Sources/App/AgentDevPilotApp.swift` | Update call site in `FloatWindowMenubarTap` |
