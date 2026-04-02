# UI Spec Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 7 gaps between the current UI and the approved design spec in `harveyzhang96-unknown-design-20260401-131205.md`.

**Architecture:** Pure view-layer fixes across 4 existing SwiftUI files. No new files except one test file for the token formatter (the only logic-bearing change). All other changes are visual layout and text corrections.

**Tech Stack:** SwiftUI (macOS 14+), `@AppStorage` for UserDefaults, `swift test` for unit tests.

---

## File Map

| File | Change |
|------|--------|
| `Sources/App/Views/SessionRowView.swift` | Token format (extract testable func), bold project name |
| `Sources/App/Views/EventCardView.swift` | Use `event.project`, bold + truncate project name, timestamp right-aligned, button below title |
| `Sources/App/Views/MenubarPopover.swift` | Per-section empty states |
| `Sources/App/Views/SessionPanelView.swift` | `@AppStorage` for alwaysOnTop, settings gear in toolbar |
| `Tests/AgentDevPilotTests/ViewUtilsTests.swift` | Unit tests for token formatter |

---

## Task 1: Fix SessionRowView — token format + bold project name

**Files:**
- Modify: `Sources/App/Views/SessionRowView.swift`
- Create: `Tests/AgentDevPilotTests/ViewUtilsTests.swift`

### What the spec says
> token count, abbreviated: `<1K` raw, `>=1K` as `"127K tok"`
> project name, bold

### Current vs target

Current token display:
```swift
Text("\(tokens) tok")   // shows "500 tok", "127000 tok"
```

Target:
```swift
// 500 → "500 tok"
// 127000 → "127K tok"
// 1000 → "1K tok"
```

Current project name:
```swift
Text(session.project).font(.callout)
```

Target:
```swift
Text(session.project).font(.callout).bold()
```

- [ ] **Step 1: Write the failing test**

Create `Tests/AgentDevPilotTests/ViewUtilsTests.swift`:

```swift
import Testing
@testable import AgentDevPilot

struct ViewUtilsTests {
    @Test func tokenLabel_belowThousand() {
        #expect(tokenLabel(500) == "500 tok")
    }

    @Test func tokenLabel_exactlyThousand() {
        #expect(tokenLabel(1000) == "1K tok")
    }

    @Test func tokenLabel_largeValue() {
        #expect(tokenLabel(127_000) == "127K tok")
    }

    @Test func tokenLabel_zero() {
        #expect(tokenLabel(0) == "0 tok")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ViewUtilsTests
```

Expected: compile error — `tokenLabel` not defined yet.

- [ ] **Step 3: Add `tokenLabel` function to SessionRowView and make it internal**

Replace the `if let tokens` block and add the function at the bottom of `Sources/App/Views/SessionRowView.swift`.

Replace:
```swift
if let tokens = session.totalTokens {
    Text("\(tokens) tok")
        .font(.caption2)
        .foregroundColor(.secondary)
}
```

With:
```swift
if let tokens = session.totalTokens {
    Text(tokenLabel(tokens))
        .font(.caption2)
        .foregroundColor(.secondary)
}
```

Add at the bottom of the file (outside the `SessionRowView` struct, before the closing of the file):

```swift
// Internal so tests can reach it without importing a separate module.
func tokenLabel(_ count: Int) -> String {
    if count >= 1000 {
        return "\(count / 1000)K tok"
    }
    return "\(count) tok"
}
```

- [ ] **Step 4: Bold the project name**

In `SessionRowView.body`, change:
```swift
Text(session.project)
    .font(.callout)
    .lineLimit(1)
```

To:
```swift
Text(session.project)
    .font(.callout)
    .bold()
    .lineLimit(1)
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift test --filter ViewUtilsTests
```

Expected: 4 tests pass.

- [ ] **Step 6: Build to verify no compile errors**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/App/Views/SessionRowView.swift Tests/AgentDevPilotTests/ViewUtilsTests.swift
git commit -m "fix: token label abbreviation and bold project name in SessionRowView"
```

---

## Task 2: Fix EventCardView — layout, field, and button placement

**Files:**
- Modify: `Sources/App/Views/EventCardView.swift`

### What the spec says
> Event card anatomy: `[status color bar 3px] | [icon] | [project name, bold, truncated at 20ch] | [event title, regular] | [relative timestamp, muted, right-aligned]`
> action button **below title** on permission/error cards

### What to change

1. Project name: use `event.project` (not `event.detail` lastPathComponent), show as bold `.caption2` truncated at 20 characters
2. Timestamp: move out of the left-aligned VStack, right-align it
3. "Open Terminal" button: move from trailing HStack position to below the title

The new `cardContent` layout:

```
[3px bar] [icon] [VStack: project-name / title / button?] [Spacer] [timestamp]
```

- [ ] **Step 1: Replace `cardContent` in EventCardView**

Replace the entire `private var cardContent: some View` computed property with:

```swift
private var cardContent: some View {
    HStack(spacing: 0) {
        // Status color bar (3px)
        Rectangle()
            .fill(tierColor)
            .frame(width: 3)

        HStack(alignment: .top, spacing: 8) {
            // SF Symbol icon
            Image(systemName: tierIcon)
                .foregroundColor(tierColor)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                // Project name — bold, truncated at 20 chars
                Text(event.project.count > 20
                        ? String(event.project.prefix(20)) + "…"
                        : event.project)
                    .font(.caption2)
                    .bold()
                    .foregroundColor(.secondary)

                // Event title
                Text(event.title)
                    .font(.callout)
                    .lineLimit(2)

                // Action button below title for permission/error events
                if event.attentionTier == .action || event.type == .taskError {
                    Button("Open Terminal") {
                        onOpenTerminal?(event.detail ?? "")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityLabel("Open terminal for \(event.title)")
                    .padding(.top, 2)
                }
            }

            Spacer()

            // Relative timestamp — right-aligned
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(relativeTime(event.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
    .background(Color(NSColor.controlBackgroundColor))
    .cornerRadius(6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
}
```

- [ ] **Step 2: Update `accessibilityDescription` to use `event.project`**

Replace:
```swift
private var accessibilityDescription: String {
    let project = event.detail.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    let time = RelativeDateTimeFormatter().localizedString(for: event.timestamp, relativeTo: Date())
    return "\(event.title), \(project), \(time)"
}
```

With:
```swift
private var accessibilityDescription: String {
    let time = RelativeDateTimeFormatter().localizedString(for: event.timestamp, relativeTo: Date())
    return "\(event.title), \(event.project), \(time)"
}
```

- [ ] **Step 3: Remove now-unused `import Foundation` guard (URL usage removed)**

The `URL(fileURLWithPath:)` call is gone. Check the imports at the top of `EventCardView.swift` — if `Foundation` was only used for that URL call and is no longer needed, remove it. (SwiftUI imports Foundation transitively, so the build will succeed either way — just keep it clean.)

- [ ] **Step 4: Build to verify no compile errors**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/App/Views/EventCardView.swift
git commit -m "fix: EventCardView layout — project field, bold name, timestamp right-aligned, button below title"
```

---

## Task 3: Fix MenubarPopover — per-section empty states

**Files:**
- Modify: `Sources/App/Views/MenubarPopover.swift`

### What the spec says
> Needs Attention empty: `"All clear. No sessions need you right now."`
> Recent Activity empty: `"No events yet. Start a Claude Code session to see activity here."`

Currently both sections are absent when empty and a single fallback is shown at the bottom. The spec wants each section to show its own empty state message inline.

- [ ] **Step 1: Replace the empty state logic in `MenubarPopover.body`**

Replace the entire `VStack` body (lines 10–76) of `MenubarPopover` with:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 0) {
        // Needs Attention section
        SectionHeader(title: "Needs Attention", count: viewModel.actionEvents.isEmpty ? nil : viewModel.actionEvents.count)

        if viewModel.actionEvents.isEmpty {
            Text("All clear. No sessions need you right now.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            ForEach(viewModel.actionEvents) { event in
                EventCardView(event: event, onOpenTerminal: onOpenTerminal) {
                    viewModel.dismiss(eventId: event.id)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }

        Divider()
            .padding(.vertical, 4)

        // Recent Activity section
        SectionHeader(title: "Recent Activity", count: nil)

        if viewModel.recentEvents.isEmpty {
            Text("No events yet. Start a Claude Code session to see activity here.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            ForEach(viewModel.recentEvents.prefix(10)) { event in
                EventCardView(event: event, onOpenTerminal: onOpenTerminal) {
                    viewModel.dismiss(eventId: event.id)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }

        Divider()

        // Footer
        HStack {
            Button("Open Session Panel") {
                openWindow(id: "session-panel")
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    .frame(width: 360)
    .background(Color(NSColor.windowBackgroundColor))
}
```

- [ ] **Step 2: Build to verify no compile errors**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/App/Views/MenubarPopover.swift
git commit -m "fix: per-section empty states in MenubarPopover per design spec"
```

---

## Task 4: Fix SessionPanelView — AppStorage for alwaysOnTop + settings gear

**Files:**
- Modify: `Sources/App/Views/SessionPanelView.swift`

### What the spec says
> Toolbar: `[title "Sessions"] [spacer] [active count] [always-on-top toggle] [settings gear]`
> Always-on-top and panel visibility persisted in UserDefaults, restored on launch.

`SettingsView.swift` already uses `@AppStorage("alwaysOnTop")`. `SessionPanelView` must read the **same key** so changes in Settings are reflected in the panel and vice versa.

- [ ] **Step 1: Replace `@State private var alwaysOnTop` with `@AppStorage`**

In `Sources/App/Views/SessionPanelView.swift`, replace:

```swift
@State private var alwaysOnTop: Bool = false
```

With:

```swift
@AppStorage("alwaysOnTop") private var alwaysOnTop: Bool = false
```

The `onChange` handler and `setWindowLevel` function stay unchanged — they still work with the binding.

- [ ] **Step 2: Add settings gear to the toolbar**

In the toolbar `HStack`, add a settings gear button after the `Toggle`. Replace the toolbar block:

```swift
HStack {
    Text("Sessions")
        .font(.headline)

    if !viewModel.activeSessions.isEmpty {
        Text("\(viewModel.activeSessions.count) active")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.2))
            .foregroundColor(.green)
            .clipShape(Capsule())
    }

    Spacer()

    Toggle("Always on Top", isOn: $alwaysOnTop)
        .toggleStyle(.checkbox)
        .font(.caption)
        .onChange(of: alwaysOnTop) { _, newValue in
            setWindowLevel(alwaysOnTop: newValue)
        }
}
```

With:

```swift
HStack {
    Text("Sessions")
        .font(.headline)

    if !viewModel.activeSessions.isEmpty {
        Text("\(viewModel.activeSessions.count) active")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.2))
            .foregroundColor(.green)
            .clipShape(Capsule())
    }

    Spacer()

    Toggle("Always on Top", isOn: $alwaysOnTop)
        .toggleStyle(.checkbox)
        .font(.caption)
        .onChange(of: alwaysOnTop) { _, newValue in
            setWindowLevel(alwaysOnTop: newValue)
        }

    Button {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } label: {
        Image(systemName: "gearshape")
            .imageScale(.medium)
    }
    .buttonStyle(.plain)
    .foregroundColor(.secondary)
    .accessibilityLabel("Open Settings")
    .padding(.leading, 4)
}
```

- [ ] **Step 3: Fix empty state text**

Replace:
```swift
Text("No sessions yet")
    .foregroundColor(.secondary)
Text("Start an agent session to see it here.")
    .font(.caption)
    .foregroundColor(.secondary)
```

With:
```swift
Text("No active sessions")
    .foregroundColor(.secondary)
Text("Start a Claude Code session in any project to see it here.")
    .font(.caption)
    .foregroundColor(.secondary)
```

- [ ] **Step 4: Build to verify no compile errors**

```bash
swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 5: Run full test suite to confirm no regressions**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/App/Views/SessionPanelView.swift
git commit -m "fix: persist alwaysOnTop via AppStorage, add settings gear, fix empty state text in SessionPanelView"
```

---

## Self-Review

### Spec coverage

| Gap from investigation | Covered by task |
|------------------------|----------------|
| Token format abbreviation | Task 1 |
| SessionRowView project name bold | Task 1 |
| EventCardView: use `event.project` | Task 2 |
| EventCardView: project name bold + 20ch truncate | Task 2 |
| EventCardView: timestamp right-aligned | Task 2 |
| EventCardView: button below title | Task 2 |
| MenubarPopover: per-section empty states | Task 3 |
| SessionPanelView: settings gear | Task 4 |
| SessionPanelView: alwaysOnTop persisted | Task 4 |
| SessionPanelView: empty state text | Task 4 |

All 10 gaps covered.

### Out of scope (intentional)
- Notification disabled banner — requires `UNUserNotificationCenter` authorization state observation. Not in the original gap list; leave for a separate task.
- `bell.badge` vs `bell.badge.fill` — current behavior (fill when action count > 0, plain otherwise) is a reasonable enhancement over the spec. No change needed.

### Placeholder scan
No TBD/TODO/placeholder patterns found.

### Type consistency
- `tokenLabel(_:)` defined in Task 1, used in Task 1 only. No cross-task type references.
- `@AppStorage("alwaysOnTop")` key matches `SettingsView.swift` line 9.
