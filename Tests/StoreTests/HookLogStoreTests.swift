import Testing
import Foundation
import GRDB
@testable import Core

@Suite("HookLogStore")
struct HookLogStoreTests {

    private func makeDB() throws -> DatabaseQueue {
        try DatabaseManager.openInMemoryDatabase()
    }

    @Test("insert and fetch by session")
    func insertAndFetchBySession() async throws {
        let db = try makeDB()
        let log = HookLog(
            id: "log-001",
            receivedAt: Date(),
            hookEventName: "Notification",
            sessionId: "sess-abc",
            notificationType: "permission_prompt",
            rawPayload: #"{"hook_event_name":"Notification"}"#
        )
        try HookLogStore.insert(log, in: db)

        let results = try HookLogStore.fetchForSession("sess-abc", in: db)
        #expect(results.count == 1)
        #expect(results[0].id == "log-001")
        #expect(results[0].hookEventName == "Notification")
        #expect(results[0].notificationType == "permission_prompt")
    }

    @Test("fetchForSession returns logs newest-first")
    func fetchForSessionOrdering() async throws {
        let db = try makeDB()
        let now = Date()
        let older = HookLog(
            receivedAt: now.addingTimeInterval(-10),
            hookEventName: "Stop",
            sessionId: "sess-order",
            notificationType: nil,
            rawPayload: "{}"
        )
        let newer = HookLog(
            receivedAt: now,
            hookEventName: "Notification",
            sessionId: "sess-order",
            notificationType: nil,
            rawPayload: "{}"
        )
        try HookLogStore.insert(older, in: db)
        try HookLogStore.insert(newer, in: db)

        let results = try HookLogStore.fetchForSession("sess-order", in: db)
        #expect(results.count == 2)
        #expect(results[0].hookEventName == "Notification")  // newer first
        #expect(results[1].hookEventName == "Stop")
    }

    @Test("fetchRecent returns logs newest-first up to limit")
    func fetchRecentOrdered() async throws {
        let db = try makeDB()
        let now = Date()
        for i in 1...3 {
            let log = HookLog(
                receivedAt: now.addingTimeInterval(Double(i)),
                hookEventName: "Stop",
                sessionId: "sess-\(i)",
                notificationType: nil,
                rawPayload: "{}"
            )
            try HookLogStore.insert(log, in: db)
        }

        let results = try HookLogStore.fetchRecent(limit: 2, in: db)
        #expect(results.count == 2)
        #expect(results[0].sessionId == "sess-3")  // newest first
        #expect(results[1].sessionId == "sess-2")
    }

    @Test("pruneOlderThan deletes old logs, keeps recent")
    func pruneOlderThan() async throws {
        let db = try makeDB()
        let old = HookLog(
            receivedAt: Date(timeIntervalSinceNow: -40 * 24 * 3600),  // 40 days ago
            hookEventName: "SessionStart",
            sessionId: "sess-old",
            notificationType: nil,
            rawPayload: "{}"
        )
        let recent = HookLog(
            receivedAt: Date(),
            hookEventName: "SessionStart",
            sessionId: "sess-new",
            notificationType: nil,
            rawPayload: "{}"
        )
        try HookLogStore.insert(old, in: db)
        try HookLogStore.insert(recent, in: db)

        let deleted = try HookLogStore.pruneOlderThan(days: 30, in: db)
        #expect(deleted == 1)

        let remaining = try HookLogStore.fetchRecent(limit: 10, in: db)
        #expect(remaining.count == 1)
        #expect(remaining[0].sessionId == "sess-new")
    }
}
