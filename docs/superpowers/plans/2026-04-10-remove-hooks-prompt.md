# Remove Hooks Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "remove hooks" prompt in Settings below each existing install-hooks prompt, so users can paste it into Claude Code / Cursor Agent to cleanly remove only Agent Pilot hooks without touching other hooks.

**Architecture:** Add two new static methods to `HookInstaller` (`claudeCodeRemovePrompt()` and `cursorAgentRemovePrompt()`), then extend `SettingsView` to display each remove prompt box + copy button beneath the existing install prompt, separated by a `Divider()`.

**Tech Stack:** Swift, SwiftUI, macOS

---

### Task 1: Add remove prompt methods to HookInstaller

**Files:**
- Modify: `Sources/Core/Services/HookInstaller.swift`

- [ ] **Step 1: Add `claudeCodeRemovePrompt()` after `claudeCodePrompt()`**

In `HookInstaller.swift`, after the closing `}` of `claudeCodePrompt()` (line 207), add:

```swift
/// Returns a prompt the user can paste into Claude Code to remove all Agent Pilot hooks.
/// Only removes entries whose command is `~/.agentpilot/hooks/notify.sh`.
/// Does not modify any other hooks or settings.json keys.
public static func claudeCodeRemovePrompt() -> String {
    """
    Please remove all Agent Pilot hooks from my Claude Code \
    settings (~/.claude/settings.json).

    Remove any hook entry whose "command" value is \
    "~/.agentpilot/hooks/notify.sh" (including tilde-expanded \
    variants such as "/Users/<username>/.agentpilot/hooks/notify.sh").

    This applies to all hook event keys: SessionStart, SessionEnd, \
    UserPromptSubmit, PreToolUse, PostToolUse, Stop, Notification — \
    and any others that may reference the same command.

    Rules:
    - Remove only entries whose command matches the path above.
    - If removing entries leaves a matcher group's "hooks" array empty, \
    remove that matcher group object entirely.
    - If removing matcher groups leaves a hook event key's array empty, \
    remove that hook event key entirely.
    - Preserve all other hooks and settings.json keys exactly as-is.
    - Do not modify any other keys in settings.json.
    """
}
```

- [ ] **Step 2: Add `cursorAgentRemovePrompt()` after `cursorAgentPrompt()`**

In `HookInstaller.swift`, after the closing `}` of `cursorAgentPrompt()` (around line 139), add:

```swift
/// Returns a prompt the user can paste into Cursor Agent to remove all Agent Pilot hooks.
/// Only removes entries whose command is `~/.agentpilot/hooks/cursor-notify.sh`.
/// Does not modify any other hooks or hooks.json keys.
public static func cursorAgentRemovePrompt() -> String {
    """
    Please remove all Agent Pilot hooks from my Cursor hooks \
    configuration (~/.cursor/hooks.json).

    Remove any hook entry whose "command" value is \
    "~/.agentpilot/hooks/cursor-notify.sh" (including tilde-expanded \
    variants such as "/Users/<username>/.agentpilot/hooks/cursor-notify.sh").

    This applies to all hook event keys: sessionStart, sessionEnd, stop — \
    and any others that may reference the same command.

    Rules:
    - Remove only entries whose command matches the path above.
    - If removing entries leaves a hook event key's array empty, \
    remove that hook event key entirely.
    - Preserve all other hooks and hooks.json keys exactly as-is.
    - Do not modify any other keys in hooks.json.
    """
}
```

- [ ] **Step 3: Build to verify**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/Services/HookInstaller.swift
git commit -m "feat: add claudeCodeRemovePrompt and cursorAgentRemovePrompt to HookInstaller"
```

---

### Task 2: Update SettingsView to show remove prompts

**Files:**
- Modify: `Sources/App/Views/SettingsView.swift`

- [ ] **Step 1: Add two new `@State` variables for copied state**

In `SettingsView`, after the existing state variables (around line 17), add:

```swift
@State private var removePromptCopied: Bool = false
@State private var cursorRemovePromptCopied: Bool = false
```

- [ ] **Step 2: Add remove prompt UI to the "Claude Code Hooks" section**

In `SettingsView.swift`, the "Claude Code Hooks" section currently ends with the Copy button's closing `}` around line 96, before the section's closing `}`. Insert the following block after that Copy button and before the section closes:

```swift
Divider()
    .padding(.vertical, 4)

Text("To remove these hooks, paste this into any Claude Code session:")
    .font(.caption)
    .foregroundColor(.secondary)
    .fixedSize(horizontal: false, vertical: true)

ScrollView {
    Text(HookInstaller.claudeCodeRemovePrompt())
        .font(.system(.caption2, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
}
.frame(height: 100)
.background(Color(NSColor.textBackgroundColor))
.cornerRadius(6)

Button {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(HookInstaller.claudeCodeRemovePrompt(), forType: .string)
    removePromptCopied = true
    Task {
        try? await Task.sleep(for: .seconds(2))
        removePromptCopied = false
    }
} label: {
    Label(removePromptCopied ? "Copied!" : "Copy Remove Prompt", systemImage: removePromptCopied ? "checkmark" : "doc.on.doc")
}
```

- [ ] **Step 3: Add remove prompt UI to the "Cursor Hooks" section**

In `SettingsView.swift`, the "Cursor Hooks" section ends with the Copy button before the section's closing `}` around line 128. Insert the following block after that Copy button and before the section closes:

```swift
Divider()
    .padding(.vertical, 4)

Text("To remove these hooks, paste this into Cursor Agent:")
    .font(.caption)
    .foregroundColor(.secondary)
    .fixedSize(horizontal: false, vertical: true)

ScrollView {
    Text(HookInstaller.cursorAgentRemovePrompt())
        .font(.system(.caption2, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
}
.frame(height: 100)
.background(Color(NSColor.textBackgroundColor))
.cornerRadius(6)

Button {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(HookInstaller.cursorAgentRemovePrompt(), forType: .string)
    cursorRemovePromptCopied = true
    Task {
        try? await Task.sleep(for: .seconds(2))
        cursorRemovePromptCopied = false
    }
} label: {
    Label(cursorRemovePromptCopied ? "Copied!" : "Copy Remove Prompt", systemImage: cursorRemovePromptCopied ? "checkmark" : "doc.on.doc")
}
```

- [ ] **Step 4: Build to verify**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 5: Run app to visually verify**

```bash
make run
```

Open Settings from the menubar icon. Verify:
- "Claude Code Hooks" section shows: install prompt → Copy Prompt button → Divider → remove prompt → Copy Remove Prompt button
- "Cursor Hooks" section shows the same structure
- Both Copy Remove Prompt buttons flash "Copied!" for 2 seconds when clicked
- Pasting the copied text shows the correct remove instructions

- [ ] **Step 6: Commit**

```bash
git add Sources/App/Views/SettingsView.swift
git commit -m "feat: show remove hooks prompt in Settings below install prompt"
```
