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
}
