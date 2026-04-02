# Hook Raw Log Design

**Date:** 2026-04-03
**Status:** Approved

## Goal

Store every incoming hook HTTP request as a raw debug log, so developers can verify which hooks were received, when, and with what payload. Currently `SessionStart` and `SessionEnd` produce no stored record, and other hooks only persist a re-encoded subset of the original JSON.

## Data Model

New table: `hook_logs`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT (UUID) | Primary key |
| `received_at` | TEXT (ISO8601) | Arrival timestamp |
| `hook_event_name` | TEXT | `SessionStart`, `SessionEnd`, `Stop`, `Notification`, `UserPromptSubmit`, `PARSE_ERROR` |
| `session_id` | TEXT | From payload; empty string for parse errors |
| `notification_type` | TEXT NULL | Populated only for `Notification` hooks (e.g. `permission_prompt`, `idle_prompt`, `auth_success`) |
| `raw_payload` | TEXT | True raw JSON bytes as received, before `JSONDecoder`; falls back to `"[non-UTF-8 body]"` if not valid UTF-8 |

Indexes: `session_id`, `received_at`.

Pruned by the same `retentionDays` UserDefaults key (default 30 days) as `DevEvent`.

## New Files

### `Sources/Core/Models/HookLog.swift`
`HookLog` struct — `Codable`, `Identifiable`, `Sendable`, `FetchableRecord`, `PersistableRecord`. Maps to `hook_logs` table.

### `Sources/Core/Store/HookLogStore.swift`
Static enum with:
- `insert(_:in:)` — used fire-and-forget (`try?`) from `EventHandler`
- `fetchRecent(limit:in:)` — most recent N entries
- `fetchForSession(_:in:)` — all entries for a session ID
- `pruneOlderThan(days:in:)` — same interface as `EventStore.pruneOlderThan`

## Modified Files

### `Sources/Core/Store/DatabaseManager.swift`
New migration `v8_hook_logs`: create `hook_logs` table with indexes.

### `Sources/Server/EventHandler.swift`
Updated `postEvent` flow:

```
POST /event
  1. Read raw bytes from body
  2. Build a preliminary HookLog(id: UUID, receivedAt: now, hookEventName: "UNKNOWN", sessionId: "", rawPayload: rawString)
  3. try? HookLogStore.insert(log, in: db)   ← fire-and-forget, never throws
  4. JSON decode → HookPayload
       Failure:
         try? update log: hookEventName = "PARSE_ERROR"
         return HTTP 400
       Success:
         try? update log: hookEventName, sessionId, notificationType from payload
         continue existing business logic unchanged
```

Insert errors are always swallowed — the debug log must never block or break hook processing.

Update is done via a direct SQL `UPDATE hook_logs SET … WHERE id = ?` so we don't need to re-fetch.

### `Sources/App/AppState.swift`
Add `HookLogStore.pruneOlderThan(days: retentionDays, in: db)` alongside the existing `EventStore.pruneOlderThan` call in the daily pruning task.

## Testing

- `Tests/StoreTests/HookLogStoreTests.swift` — insert, fetch, prune with in-memory DB
- `Tests/ServerTests/EventHandlerTests.swift` — extend existing tests to assert a `HookLog` row is inserted for each hook type, including parse-error path

## Non-goals

- No UI to browse hook logs (debug only; can be queried directly from SQLite)
- No separate retention period (reuses `retentionDays`)
- No deduplication
