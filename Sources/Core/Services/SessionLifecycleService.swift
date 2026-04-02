import Foundation
import GRDB

public enum SessionLifecycleService {
    /// Handles SessionStart and SessionEnd hooks.
    /// Only writes to the sessions table — never creates DevEvent records.
    public static func handleSessionLifecycle(payload: HookPayload, in db: any DatabaseWriter) throws {
        let project = URL(fileURLWithPath: payload.cwd).lastPathComponent
        let now = ISO8601DateFormatter().string(from: Date())

        try db.write { db in
            let existing = try DevSession.fetchOne(db, key: payload.sessionId)

            switch payload.hookEventName {
            case "SessionStart":
                if let session = existing {
                    // Always refresh location/terminal info in case Claude Code restarted
                    try db.execute(
                        sql: "UPDATE sessions SET cwd = ?, tty = ?, terminal_app = ? WHERE id = ?",
                        arguments: [payload.cwd, payload.tty, payload.terminalApp, payload.sessionId]
                    )
                    // Update custom_name only when explicitly provided (don't clear a prior rename)
                    if let title = payload.title {
                        try db.execute(
                            sql: "UPDATE sessions SET custom_name = ? WHERE id = ?",
                            arguments: [title, payload.sessionId]
                        )
                    }
                    // If closed, also reset status and clear ended_at
                    if session.status == .completed || session.status == .stale {
                        try db.execute(
                            sql: "UPDATE sessions SET status = 'idle', ended_at = NULL WHERE id = ?",
                            arguments: [payload.sessionId]
                        )
                    }
                    // If already idle/busy/waiting: cwd/tty/terminalApp updated above, status unchanged
                } else {
                    var session = DevSession(
                        id: payload.sessionId,
                        project: project,
                        customName: payload.title,
                        cwd: payload.cwd,
                        tty: payload.tty,
                        terminalApp: payload.terminalApp,
                        tool: "claude-code",
                        status: .idle,
                        startedAt: Date(),
                        endedAt: nil,
                        totalTokens: nil,
                        lastEventTitle: nil
                    )
                    try session.insert(db)
                }

            case "SessionEnd":
                if existing != nil {
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'completed', ended_at = ? WHERE id = ?",
                        arguments: [now, payload.sessionId]
                    )
                }
                // Session not found → silently ignore (app may have restarted)

            default:
                break
            }
        }
    }

    /// Processes a DevEvent: creates/updates the session, inserts the event, transitions session state.
    ///
    /// State transitions:
    ///   - `promptSubmitted`  → `busy`
    ///   - `permissionNeeded` → `waiting`
    ///   - `agentStopped`     → no change (StopWindowService resolves idle/waiting after window)
    ///   - `authSuccess`      → no change (record-only)
    public static func processEvent(_ event: DevEvent, sessionTitle: String? = nil, in db: any DatabaseWriter) throws {
        try db.write { db in
            let existingSession = try DevSession.fetchOne(db, key: event.sessionId)

            if let session = existingSession {
                // Reopen completed/stale sessions on new activity
                if session.status == .completed || session.status == .stale {
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'idle', ended_at = NULL WHERE id = ?",
                        arguments: [event.sessionId]
                    )
                }

                try event.insert(db)
                try db.execute(
                    sql: "UPDATE sessions SET last_event_title = ? WHERE id = ?",
                    arguments: [event.title, event.sessionId]
                )
                // Update custom_name when payload carries a title (e.g. after /rename)
                if let title = sessionTitle {
                    try db.execute(
                        sql: "UPDATE sessions SET custom_name = ? WHERE id = ?",
                        arguments: [title, event.sessionId]
                    )
                }

                switch event.type {
                case .promptSubmitted:
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'busy' WHERE id = ?",
                        arguments: [event.sessionId]
                    )
                    // User submitted a new prompt — auto-dismiss all prior notifications
                    // for this session (they've implicitly acknowledged them by continuing)
                    try db.execute(
                        sql: "UPDATE events SET is_dismissed = 1 WHERE session_id = ? AND is_dismissed = 0",
                        arguments: [event.sessionId]
                    )
                case .permissionNeeded:
                    try db.execute(
                        sql: "UPDATE sessions SET status = 'waiting' WHERE id = ?",
                        arguments: [event.sessionId]
                    )
                case .agentStopped, .authSuccess:
                    break
                }

                if let tokens = event.tokenCount {
                    try db.execute(
                        sql: "UPDATE sessions SET total_tokens = COALESCE(total_tokens, 0) + ? WHERE id = ?",
                        arguments: [tokens, event.sessionId]
                    )
                }
            } else {
                // Session not found — app started after SessionStart was missed
                let cwd = event.detail
                let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
                let initialStatus: SessionStatus = event.type == .promptSubmitted ? .busy
                    : event.type == .permissionNeeded ? .waiting
                    : .idle
                var session = DevSession(
                    id: event.sessionId, project: project,
                    cwd: cwd,
                    tool: "claude-code", status: initialStatus, startedAt: Date(),
                    endedAt: nil, totalTokens: event.tokenCount, lastEventTitle: event.title
                )
                try session.insert(db)
                try event.insert(db)
            }
        }
    }
}
