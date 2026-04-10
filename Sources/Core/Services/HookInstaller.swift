import Foundation

public enum HookInstaller {

    // MARK: - Paths

    public static var hooksDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentpilot/hooks").path
    }

    public static var scriptPath: String {
        hooksDirectory + "/notify.sh"
    }

    // MARK: - Script content (canonical source of truth)

    static let scriptContent = """
    #!/bin/bash
    # Agent Pilot — Claude Code hook helper script
    # Reads hook event JSON from stdin and forwards to the local HTTP server.
    #
    # SECURITY: Use --data-binary @- to pipe stdin directly to curl.
    # Do NOT capture stdin into a variable (shell expansion risk).
    # head -c 65536 enforces 64KB max payload at the source.
    TOKEN=$(cat ~/.agentpilot/token 2>/dev/null)
    cat | head -c 65536 | curl -s -X POST http://127.0.0.1:9876/event \\
      -H 'Content-Type: application/json' \\
      -H "Authorization: Bearer $TOKEN" \\
      --data-binary @- \\
      --max-time 2 \\
      >/dev/null 2>&1 &
    # Fire-and-forget: if app is not running, event is silently lost.
    # This is intentional — hooks must never block Claude Code's workflow.
    """

    // MARK: - Install

    /// Writes notify.sh to ~/.agentpilot/hooks/ with 0755 permissions.
    /// Safe to call repeatedly — only writes if content has changed.
    public static func installScript() throws {
        let fm = FileManager.default

        // Create directory if needed
        try fm.createDirectory(atPath: hooksDirectory, withIntermediateDirectories: true)

        // Skip write if already up to date
        if let existing = try? String(contentsOfFile: scriptPath, encoding: .utf8),
           existing == scriptContent {
            return
        }

        try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    // MARK: - Status

    public static func isScriptInstalled() -> Bool {
        guard let existing = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            return false
        }
        return existing == scriptContent
    }

    // MARK: - Cursor

    public static var cursorScriptPath: String {
        hooksDirectory + "/cursor-notify.sh"
    }

    /// Cursor hook script content (canonical source of truth).
    /// Posts Cursor hook payloads to /cursor-event endpoint.
    /// Fire-and-forget — never blocks Cursor's workflow.
    static let cursorScriptContent = """
    #!/bin/bash
    # Agent Pilot — Cursor hook
    # Cursor passes payload via stdin as JSON

    TOKEN_FILE=~/.agentpilot/token
    [ -f "$TOKEN_FILE" ] || exit 0
    TOKEN=$(cat "$TOKEN_FILE")
    PORT=${AGENT_PILOT_PORT:-9876}

    head -c 65536 | curl -s \\
      -X POST "http://127.0.0.1:$PORT/cursor-event" \\
      -H 'Content-Type: application/json' \\
      -H "Authorization: Bearer $TOKEN" \\
      --data-binary @- \\
      --max-time 2 \\
      >/dev/null 2>&1 &
    # Fire-and-forget: if app is not running, event is silently lost.
    """

    /// Writes cursor-notify.sh to ~/.agentpilot/hooks/ with 0755 permissions.
    /// Safe to call repeatedly — only writes if content has changed.
    public static func installCursorScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: hooksDirectory, withIntermediateDirectories: true)

        if let existing = try? String(contentsOfFile: cursorScriptPath, encoding: .utf8),
           existing == cursorScriptContent {
            return
        }

        try cursorScriptContent.write(toFile: cursorScriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cursorScriptPath)
    }

    public static func isCursorScriptInstalled() -> Bool {
        guard let existing = try? String(contentsOfFile: cursorScriptPath, encoding: .utf8) else {
            return false
        }
        return existing == cursorScriptContent
    }

    /// Returns a prompt the user can paste into Cursor Agent.
    /// Cursor Agent will merge the hooks into ~/.cursor/hooks.json.
    public static func cursorAgentPrompt() -> String {
        """
        Please add sessionStart, sessionEnd, and stop hooks to my Cursor hooks \
        configuration (~/.cursor/hooks.json) for Agent Pilot.

        All three hooks should run `~/.agentpilot/hooks/cursor-notify.sh`.

        Target JSON to merge under the "hooks" key (create the file if it doesn't exist, \
        set "version": 1 at the top level):
        {
          "sessionStart": [{ "command": "~/.agentpilot/hooks/cursor-notify.sh" }],
          "sessionEnd":   [{ "command": "~/.agentpilot/hooks/cursor-notify.sh" }],
          "stop":         [{ "command": "~/.agentpilot/hooks/cursor-notify.sh" }]
        }

        Rules:
        - Only add entries that do not already exist.
        - Preserve all existing hooks exactly as-is.
        - Do not modify any other keys in hooks.json.
        """
    }

    // MARK: - Claude Code prompt

    /// Returns a prompt the user can paste into Claude Code.
    /// Claude Code will use its own update-config skill + permission system
    /// to safely add all required hooks to ~/.claude/settings.json.
    ///
    /// Hooks registered: SessionStart, SessionEnd, UserPromptSubmit,
    /// PreToolUse, PostToolUse, Stop, Notification
    public static func claudeCodePrompt() -> String {
        """
        Please add the following hooks to my Claude Code \
        settings (~/.claude/settings.json) for Agent Pilot.

        All hooks should run `~/.agentpilot/hooks/notify.sh`.

        Target JSON to merge under the "hooks" key:
        {
          "SessionStart": [
            {
              "matcher": "",
              "hooks": [{ "type": "command", "command": "~/.agentpilot/hooks/notify.sh" }]
            }
          ],
          "SessionEnd": [
            {
              "matcher": "",
              "hooks": [{ "type": "command", "command": "~/.agentpilot/hooks/notify.sh" }]
            }
          ],
          "UserPromptSubmit": [
            {
              "matcher": "",
              "hooks": [{ "type": "command", "command": "~/.agentpilot/hooks/notify.sh" }]
            }
          ],
          "PreToolUse": [
            {
              "matcher": "",
              "hooks": [{ "type": "command", "command": "~/.agentpilot/hooks/notify.sh" }]
            }
          ],
          "PostToolUse": [
            {
              "matcher": "",
              "hooks": [{ "type": "command", "command": "~/.agentpilot/hooks/notify.sh" }]
            }
          ],
          "Stop": [
            {
              "matcher": "",
              "hooks": [{ "type": "command", "command": "~/.agentpilot/hooks/notify.sh" }]
            }
          ],
          "Notification": [
            {
              "matcher": "",
              "hooks": [{ "type": "command", "command": "~/.agentpilot/hooks/notify.sh" }]
            }
          ]
        }

        Rules:
        - Only add entries that do not already exist.
        - Preserve all existing hooks and permissions exactly as-is.
        - Do not modify any other keys in settings.json.
        """
    }

}
