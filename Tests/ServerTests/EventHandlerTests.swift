import Testing
import Foundation
import GRDB
import NIOCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import Server
@testable import Core

@Suite("EventHandler")
struct EventHandlerTests {

    // MARK: - Helpers

    private func makeApp(authToken: String = "test-token") throws -> (some ApplicationProtocol, any DatabaseWriter & Sendable) {
        let db = try DatabaseManager.openInMemoryDatabase()
        let app = EventServer.buildApp(db: db, authToken: authToken) { _ in }
        return (app, db)
    }

    private func validPayload() -> String {
        """
        {
          "session_id": "abc123",
          "cwd": "/Users/test/myproject",
          "hook_event_name": "Notification",
          "message": "Task completed successfully"
        }
        """
    }

    // MARK: - Tests

    @Test("POST /event with valid JSON returns 200")
    func postEventValidJSON() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: validPayload())
            let response = try await client.execute(
                uri: "/event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: body
            )
            #expect(response.status == .ok)
        }
    }

    @Test("POST /event with malformed JSON returns 400")
    func postEventMalformedJSON() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: "not valid json {{{")
            let response = try await client.execute(
                uri: "/event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: body
            )
            #expect(response.status == .badRequest)
        }
    }

    @Test("GET /health returns 200 with version")
    func getHealth() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/health",
                method: .get
            )
            #expect(response.status == .ok)
            let bodyString = String(buffer: response.body)
            #expect(bodyString.contains("1.0.0"))
            #expect(bodyString.contains("running"))
        }
    }

    @Test("POST /event without auth returns 401")
    func postEventNoAuth() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: validPayload())
            let response = try await client.execute(
                uri: "/event",
                method: .post,
                body: body
            )
            #expect(response.status == .unauthorized)
        }
    }

    @Test("POST /event with wrong token returns 401")
    func postEventWrongToken() async throws {
        let (app, _) = try makeApp(authToken: "correct-token")
        try await app.test(.router) { client in
            let body = ByteBuffer(string: validPayload())
            let response = try await client.execute(
                uri: "/event",
                method: .post,
                headers: [.authorization: "Bearer wrong-token"],
                body: body
            )
            #expect(response.status == .unauthorized)
        }
    }

    @Test("POST /event with SessionStart returns 200, no DevEvent, session created with status running")
    func postEventSessionStart() async throws {
        let (app, db) = try makeApp()
        try await app.test(.router) { client in
            let payload = """
            {
              "session_id": "sess-start-001",
              "cwd": "/Users/test/myproject",
              "hook_event_name": "SessionStart"
            }
            """
            let body = ByteBuffer(string: payload)
            let response = try await client.execute(
                uri: "/event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: body
            )
            #expect(response.status == .ok)

            let eventCount = try await db.read { try DevEvent.fetchCount($0) }
            #expect(eventCount == 0, "SessionStart must not create any DevEvent records")

            let session = try await db.read { try DevSession.fetchOne($0, key: "sess-start-001") }
            #expect(session != nil, "SessionStart must create a DevSession")
            #expect(session?.status == .running, "Session status must be running after SessionStart")
        }
    }

    @Test("POST /event with SessionEnd returns 200, no DevEvent, session marked completed")
    func postEventSessionEnd() async throws {
        let (app, db) = try makeApp()

        // Pre-create a running session so SessionEnd has something to close
        try await db.write { db in
            var session = DevSession(
                id: "sess-end-001",
                project: "myproject",
                cwd: "/Users/test/myproject",
                tool: "claude-code",
                status: .running,
                startedAt: Date(),
                endedAt: nil,
                totalTokens: nil,
                lastEventTitle: nil
            )
            try session.insert(db)
        }

        try await app.test(.router) { client in
            let payload = """
            {
              "session_id": "sess-end-001",
              "cwd": "/Users/test/myproject",
              "hook_event_name": "SessionEnd"
            }
            """
            let body = ByteBuffer(string: payload)
            let response = try await client.execute(
                uri: "/event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: body
            )
            #expect(response.status == .ok)

            let eventCount = try await db.read { try DevEvent.fetchCount($0) }
            #expect(eventCount == 0, "SessionEnd must not create any DevEvent records")

            let session = try await db.read { try DevSession.fetchOne($0, key: "sess-end-001") }
            #expect(session?.status == .completed, "Session status must be completed after SessionEnd")
        }
    }
}
