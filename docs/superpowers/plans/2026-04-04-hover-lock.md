# Hover Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a lock button to the Float Window Hover View toolbar that keeps the window permanently in Hover View (bypassing Compact), persisted across restarts via UserDefaults.

**Architecture:** `isHoverLocked` lives in `FloatWindowDisplayState` (the existing `@Observable` bridge) with a `didSet` that writes to `UserDefaults`. `FloatWindowController`'s state machine reads this flag at four decision points. `FloatWindowHoverView` receives `isLocked: Bool` + `onToggleLock: () -> Void` props and renders the lock button in the toolbar.

**Tech Stack:** SwiftUI, AppKit (NSPanel), Swift Observation (`@Observable`), UserDefaults, SF Symbols, Swift Testing

---

## File Map

| File | Change |
|---|---|
| `Sources/App/FloatWindow/FloatWindowDisplayState.swift` | Add `isHoverLocked: Bool` with UserDefaults `didSet` |
| `Sources/App/FloatWindow/FloatWindowHoverView.swift` | Add `isLocked`/`onToggleLock` props; render lock button |
| `Sources/App/FloatWindow/FloatWindowController.swift` | 4 state-machine changes + wire props in `FloatWindowRootView` |
| `Tests/AgentDevPilotTests/FloatWindowHeightTests.swift` | Add `isHoverLocked` persistence tests (same file, existing pattern) |

---

### Task 1: Add `isHoverLocked` to `FloatWindowDisplayState`

**Files:**
- Modify: `Sources/App/FloatWindow/FloatWindowDisplayState.swift`
- Test: `Tests/AgentDevPilotTests/FloatWindowHeightTests.swift`

- [ ] **Step 1: Write the failing tests**

Open `Tests/AgentDevPilotTests/FloatWindowHeightTests.swift` and add at the bottom of the struct:

```swift
// MARK: - isHoverLocked persistence

@Test @MainActor func isHoverLocked_defaultsFalse() {
    UserDefaults.standard.removeObject(forKey: "floatWindowHoverLocked")
    let state = FloatWindowDisplayState()
    #expect(state.isHoverLocked == false)
}

@Test @MainActor func isHoverLocked_loadsFromUserDefaults() {
    UserDefaults.standard.set(true, forKey: "floatWindowHoverLocked")
    let state = FloatWindowDisplayState()
    #expect(state.isHoverLocked == true)
    UserDefaults.standard.removeObject(forKey: "floatWindowHoverLocked")
}

@Test @MainActor func isHoverLocked_persistsOnSet() {
    UserDefaults.standard.removeObject(forKey: "floatWindowHoverLocked")
    let state = FloatWindowDisplayState()
    state.isHoverLocked = true
    #expect(UserDefaults.standard.bool(forKey: "floatWindowHoverLocked") == true)
    UserDefaults.standard.removeObject(forKey: "floatWindowHoverLocked")
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
swift test --filter FloatWindowHeightTests
```

Expected: compile error or FAIL — `isHoverLocked` doesn't exist yet.

- [ ] **Step 3: Add `isHoverLocked` to `FloatWindowDisplayState`**

Replace the entire file content:

```swift
// Sources/App/FloatWindow/FloatWindowDisplayState.swift
import Foundation

/// @Observable bridge owned by FloatWindowController.
/// SwiftUI views read this to know what to render.
@MainActor
@Observable
final class FloatWindowDisplayState {
    enum Mode { case hidden, compact, hover, expanded }
    var mode: Mode = .hidden
    /// Reported by the SwiftUI content via GeometryReader after each render.
    var contentHeight: CGFloat = 0
    /// When true, the window stays in hover state and never auto-collapses to compact.
    var isHoverLocked: Bool = UserDefaults.standard.bool(forKey: "floatWindowHoverLocked") {
        didSet { UserDefaults.standard.set(isHoverLocked, forKey: "floatWindowHoverLocked") }
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter FloatWindowHeightTests
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/FloatWindow/FloatWindowDisplayState.swift Tests/AgentDevPilotTests/FloatWindowHeightTests.swift
git commit -m "feat: add isHoverLocked to FloatWindowDisplayState with UserDefaults persistence"
```

---

### Task 2: Add lock button to `FloatWindowHoverView`

**Files:**
- Modify: `Sources/App/FloatWindow/FloatWindowHoverView.swift`

No unit test — pure UI rendering. Manual verification in Task 3.

- [ ] **Step 1: Add `isLocked` and `onToggleLock` props to `FloatWindowHoverView`**

In `FloatWindowHoverView.swift`, change the struct declaration and toolbar section.

Replace the struct's props block (lines 4–8):

```swift
struct FloatWindowHoverView: View {
    let sessions: [DevSession]
    let eventsBySession: [String: [DevEvent]]
    let onFocusSession: (DevSession) -> Void
    let onExpand: () -> Void
    let isLocked: Bool
    let onToggleLock: () -> Void
```

- [ ] **Step 2: Add lock button to the toolbar**

In the toolbar `HStack`, after the gear `Button` and before the `Spacer`, add the lock button:

```swift
// Toolbar
HStack(spacing: 0) {
    Button {
        // No action yet
    } label: {
        Image(systemName: "gear")
            .foregroundColor(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(Color.clear)
    .cornerRadius(3)

    Button {
        onToggleLock()
    } label: {
        Image(systemName: isLocked ? "lock.fill" : "lock")
            .foregroundColor(isLocked ? .primary : .secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(Color.clear)
    .cornerRadius(3)

    Spacer()

    Button {
        onExpand()
    } label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .foregroundColor(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(Color.clear)
    .cornerRadius(3)
}
.padding(.horizontal, 8)
.padding(.vertical, 4)
```

- [ ] **Step 3: Build to confirm no compile errors**

```bash
swift build -c debug 2>&1 | grep -E "error:|FloatWindowHoverView"
```

Expected: compile errors about missing `isLocked`/`onToggleLock` at call sites in `FloatWindowController.swift` (the `FloatWindowRootView` section). That's expected — Task 3 fixes them.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/FloatWindow/FloatWindowHoverView.swift
git commit -m "feat: add isLocked prop and lock button to FloatWindowHoverView toolbar"
```

---

### Task 3: Update `FloatWindowController` — state machine + wiring

**Files:**
- Modify: `Sources/App/FloatWindow/FloatWindowController.swift`

- [ ] **Step 1: Fix `handleMouseExit` to respect lock**

Find `handleMouseExit` (around line 303):

```swift
private func handleMouseExit() {
    if currentState == .hover || currentState == .expanded { scheduleCollapse() }
}
```

Replace with:

```swift
private func handleMouseExit() {
    guard !displayState.isHoverLocked else { return }
    if currentState == .hover || currentState == .expanded { scheduleCollapse() }
}
```

- [ ] **Step 2: Fix `updateFromViewModel` hidden case**

Find the `updateFromViewModel` method and its `.hidden` case (around line 271):

```swift
case .hidden:
    if hasSessions && hasEvents { transition(to: .compact) }
```

Replace with:

```swift
case .hidden:
    if hasSessions && hasEvents {
        transition(to: displayState.isHoverLocked ? .hover : .compact)
    }
```

- [ ] **Step 3: Fix `updateFromViewModel` compact case**

Find the `.compact` case in `updateFromViewModel`:

```swift
case .compact:
    if !hasEvents || !hasSessions {
        transition(to: .hidden)
    } else {
        // Re-size if event count changed
        let h = targetHeight(for: .compact)
        positionPanel(height: h, animated: true)
    }
```

Replace with:

```swift
case .compact:
    if !hasEvents || !hasSessions {
        transition(to: .hidden)
    } else if displayState.isHoverLocked {
        transition(to: .hover)
    } else {
        // Re-size if event count changed
        let h = targetHeight(for: .compact)
        positionPanel(height: h, animated: true)
    }
```

- [ ] **Step 4: Handle lock toggle ON while in compact**

In `setupContentView`, the `FloatWindowRootView` is created with an `onExpand` callback. We'll add an `onToggleLock` callback there in Step 5. First, add a private toggle method to `FloatWindowController`:

After the `close()` method (around line 32), add:

```swift
func toggleHoverLock() {
    displayState.isHoverLocked.toggle()
    if displayState.isHoverLocked && currentState == .compact {
        transition(to: .hover)
    }
}
```

- [ ] **Step 5: Wire `isLocked` and `onToggleLock` into `FloatWindowRootView`**

In `setupContentView`, the `FloatWindowRootView` initializer is called around line 87. Update the call:

```swift
let root = FloatWindowRootView(
    displayState: displayState,
    viewModel: viewModel,
    onExpand: { [weak self] in self?.transition(to: .expanded) },
    onToggleLock: { [weak self] in self?.toggleHoverLock() },
    onFocusSession: onFocusSession,
    onContentHeight: { [weak self] h in
        Task { @MainActor [weak self] in self?.displayState.contentHeight = h }
    }
)
```

- [ ] **Step 6: Update `FloatWindowRootView` to accept and pass through `onToggleLock`**

Find `FloatWindowRootView` at the bottom of `FloatWindowController.swift` (around line 329):

```swift
private struct FloatWindowRootView: View {
    let displayState: FloatWindowDisplayState
    let viewModel: PopoverViewModel
    let onExpand: () -> Void
    let onFocusSession: (DevSession) -> Void
    let onContentHeight: (CGFloat) -> Void
```

Replace with:

```swift
private struct FloatWindowRootView: View {
    let displayState: FloatWindowDisplayState
    let viewModel: PopoverViewModel
    let onExpand: () -> Void
    let onToggleLock: () -> Void
    let onFocusSession: (DevSession) -> Void
    let onContentHeight: (CGFloat) -> Void
```

- [ ] **Step 7: Pass `isLocked` and `onToggleLock` to `FloatWindowHoverView` in `FloatWindowRootView.content`**

Find the `.hover` case inside `FloatWindowRootView.content` (around line 357):

```swift
case .hover:
    FloatWindowHoverView(
        sessions: viewModel.activeSessions,
        eventsBySession: viewModel.eventsBySession,
        onFocusSession: onFocusSession,
        onExpand: onExpand
    )
```

Replace with:

```swift
case .hover:
    FloatWindowHoverView(
        sessions: viewModel.activeSessions,
        eventsBySession: viewModel.eventsBySession,
        onFocusSession: onFocusSession,
        onExpand: onExpand,
        isLocked: displayState.isHoverLocked,
        onToggleLock: onToggleLock
    )
```

- [ ] **Step 8: Build to confirm clean compile**

```bash
swift build -c debug 2>&1 | grep "error:"
```

Expected: no errors.

- [ ] **Step 9: Run full test suite**

```bash
swift test --filter AgentDevPilotTests
```

Expected: all tests PASS.

- [ ] **Step 10: Commit**

```bash
git add Sources/App/FloatWindow/FloatWindowController.swift
git commit -m "feat: wire hover lock into FloatWindowController state machine and FloatWindowRootView"
```

---

### Task 4: Manual verification

- [ ] **Step 1: Launch the app**

```bash
make run
```

- [ ] **Verify: lock button appears in hover toolbar**
  - Hover over the float window → Hover View appears
  - Lock icon (`lock`) visible between gear and spacer, color secondary (gray)

- [ ] **Verify: lock toggles on click**
  - Click lock → icon changes to `lock.fill`, color primary (white)
  - Click again → icon back to `lock`, color secondary

- [ ] **Verify: locked window doesn't collapse**
  - Lock the window
  - Move mouse away → window stays in Hover View (does not collapse to compact pill)

- [ ] **Verify: locked window appears as hover on session arrival**
  - Lock the window
  - Trigger a new session (or restart app with a running Claude Code session)
  - Float window appears directly in Hover View, not Compact

- [ ] **Verify: persistence across restart**
  - Lock the window
  - Quit and relaunch the app (`make run`)
  - With active sessions, window opens in Hover View
  - Lock button shows `lock.fill`

- [ ] **Verify: unlock restores normal behavior**
  - Unlock while in hover → window stays hover for now
  - Move mouse away → 1s later, collapses back to compact pill

- [ ] **Final commit if any tweaks were made during manual testing**

```bash
git add -p
git commit -m "fix: hover lock manual verification tweaks"
```
