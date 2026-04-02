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
                    // Reopen if closed; always update cwd
                    if session.status == .completed || session.status == .error || session.status == .stale {
                        try db.execute(
                            sql: "UPDATE sessions SET status = 'running', ended_at = NULL, cwd = ? WHERE id = ?",
                            arguments: [payload.cwd, payload.sessionId]
                        )
                    }
                    // If already running/waiting: no-op (idempotent)
                } else {
                    var session = DevSession(
                        id: payload.sessionId,
                        project: project,
                        cwd: payload.cwd,
                        tool: "claude-code",
                        status: .running,
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
    public static func processEvent(_ event: DevEvent, in db: any DatabaseWriter) throws {
        try db.write { db in
            let existingSession = try DevSession.fetchOne(db, key: event.sessionId)

            if let session = existingSession {
                // Reopen if closed
                if session.status == .completed || session.status == .error {
                    try db.execute(sql: "UPDATE sessions SET status = 'running', ended_at = NULL WHERE id = ?",
                                   arguments: [event.sessionId])
                }

                try event.insert(db)

                switch event.type {
                case .permissionNeeded:
                    try db.execute(sql: "UPDATE sessions SET status = 'waiting', last_event_title = ? WHERE id = ?",
                                   arguments: [event.title, event.sessionId])
                case .taskCompleted:
                    let now = ISO8601DateFormatter().string(from: Date())
                    try db.execute(sql: "UPDATE sessions SET status = 'completed', ended_at = ?, last_event_title = ? WHERE id = ?",
                                   arguments: [now, event.title, event.sessionId])
                case .taskError:
                    let now = ISO8601DateFormatter().string(from: Date())
                    try db.execute(sql: "UPDATE sessions SET status = 'error', ended_at = ?, last_event_title = ? WHERE id = ?",
                                   arguments: [now, event.title, event.sessionId])
                case .taskStarted:
                    try db.execute(sql: "UPDATE sessions SET status = 'running', last_event_title = ? WHERE id = ?",
                                   arguments: [event.title, event.sessionId])
                }

                if let tokens = event.tokenCount {
                    try db.execute(sql: "UPDATE sessions SET total_tokens = COALESCE(total_tokens, 0) + ? WHERE id = ?",
                                   arguments: [tokens, event.sessionId])
                }
            } else {
                // Create new session (app started after session began; SessionStart was missed)
                let cwd = event.detail
                let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
                var session = DevSession(
                    id: event.sessionId, project: project,
                    cwd: cwd,
                    tool: "claude-code", status: .running, startedAt: Date(),
                    endedAt: nil, totalTokens: event.tokenCount, lastEventTitle: event.title
                )
                try session.insert(db)
                try event.insert(db)

                // Apply state transition for first event
                if event.type == .permissionNeeded {
                    try db.execute(sql: "UPDATE sessions SET status = 'waiting' WHERE id = ?", arguments: [event.sessionId])
                } else if event.type == .taskCompleted {
                    let now = ISO8601DateFormatter().string(from: Date())
                    try db.execute(sql: "UPDATE sessions SET status = 'completed', ended_at = ? WHERE id = ?",
                                   arguments: [now, event.sessionId])
                } else if event.type == .taskError {
                    let now = ISO8601DateFormatter().string(from: Date())
                    try db.execute(sql: "UPDATE sessions SET status = 'error', ended_at = ? WHERE id = ?",
                                   arguments: [now, event.sessionId])
                }
            }
        }
    }
}
