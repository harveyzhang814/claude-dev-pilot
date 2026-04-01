import Foundation
import GRDB

enum SessionLifecycleService {
    /// Processes a DevEvent: creates/updates the session, inserts the event, transitions session state.
    static func processEvent(_ event: DevEvent, in db: any DatabaseWriter) throws {
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
                // Create new session
                var session = DevSession(
                    id: event.sessionId, project: event.detail ?? "unknown",
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
