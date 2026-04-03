import Testing
import Foundation
import GRDB
import NIOCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import Server
@testable import Core

@Suite("CursorEventHandler")
struct CursorEventHandlerTests {

    // MARK: - Helpers

    private func makeApp(authToken: String = "test-token") throws -> (some ApplicationProtocol, any DatabaseWriter & Sendable) {
        let db = try DatabaseManager.openInMemoryDatabase()
        let stopWindow = StopWindowService(db: db)
        let app = EventServer.buildApp(db: db, authToken: authToken, stopWindow: stopWindow) { _ in }
        return (app, db)
    }

    private func sessionStartPayload(sessionId: String = "cursor-sess-1") -> String {
        """
        {
          "session_id": "\(sessionId)",
          "conversation_id": "\(sessionId)",
          "hook_event_name": "sessionStart",
          "cursor_version": "3.0.4",
          "workspace_roots": ["/Users/test/myproject"],
          "model": "default",
          "is_background_agent": false
        }
        """
    }

    private func stopPayload(sessionId: String = "cursor-sess-1") -> String {
        """
        {
          "session_id": "\(sessionId)",
          "conversation_id": "\(sessionId)",
          "hook_event_name": "stop",
          "cursor_version": "3.0.4",
          "workspace_roots": ["/Users/test/myproject"],
          "status": "completed",
          "input_tokens": 1000,
          "output_tokens": 200
        }
        """
    }

    // MARK: - Auth

    @Test("POST /cursor-event with no auth returns 401")
    func postCursorEventNoAuth() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: sessionStartPayload())
            let response = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                body: body
            )
            #expect(response.status == .unauthorized)
        }
    }

    @Test("POST /cursor-event with wrong token returns 401")
    func postCursorEventWrongToken() async throws {
        let (app, _) = try makeApp(authToken: "correct-token")
        try await app.test(.router) { client in
            let body = ByteBuffer(string: sessionStartPayload())
            let response = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                headers: [.authorization: "Bearer wrong-token"],
                body: body
            )
            #expect(response.status == .unauthorized)
        }
    }

    // MARK: - Parsing

    @Test("POST /cursor-event with malformed JSON returns 400")
    func postCursorEventMalformedJSON() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: "{not valid json")
            let response = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: body
            )
            #expect(response.status == .badRequest)
        }
    }

    // MARK: - Lifecycle

    @Test("POST /cursor-event sessionStart creates session with tool=cursor")
    func postCursorSessionStartCreatesTool() async throws {
        let (app, db) = try makeApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: sessionStartPayload(sessionId: "cursor-tool-test"))
            let response = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: body
            )
            #expect(response.status == .ok)
        }

        let session = try await db.read { try DevSession.fetchOne($0, key: "cursor-tool-test") }
        #expect(session != nil)
        #expect(session?.tool == "cursor")
        #expect(session?.project == "myproject")
    }

    @Test("POST /cursor-event stop → session transitions to idle via stop window")
    func postCursorStopEvent() async throws {
        let (app, db) = try makeApp()
        let sessionId = "cursor-stop-test"

        try await app.test(.router) { client in
            // SessionStart first
            let startBody = ByteBuffer(string: sessionStartPayload(sessionId: sessionId))
            _ = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: startBody
            )

            // Stop event
            let stopBody = ByteBuffer(string: stopPayload(sessionId: sessionId))
            let response = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: stopBody
            )
            #expect(response.status == .ok)
        }

        // Verify a stop event was persisted
        let events = try await db.read { try DevEvent.fetchAll($0) }
        let stopEvent = events.first { $0.sessionId == sessionId && $0.type == .agentStopped }
        #expect(stopEvent != nil)
    }

    @Test("POST /cursor-event sessionEnd → session status = completed")
    func postCursorSessionEnd() async throws {
        let (app, db) = try makeApp()
        let sessionId = "cursor-end-test"

        try await app.test(.router) { client in
            // SessionStart
            let startBody = ByteBuffer(string: sessionStartPayload(sessionId: sessionId))
            _ = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: startBody
            )

            // SessionEnd
            let endJson = """
            {
              "session_id": "\(sessionId)",
              "conversation_id": "\(sessionId)",
              "hook_event_name": "sessionEnd",
              "cursor_version": "3.0.4",
              "workspace_roots": ["/Users/test/myproject"]
            }
            """
            let endBody = ByteBuffer(string: endJson)
            let response = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: endBody
            )
            #expect(response.status == .ok)
        }

        let session = try await db.read { try DevSession.fetchOne($0, key: sessionId) }
        #expect(session?.status == .completed)
    }

    @Test("POST /cursor-event valid sessionStart returns 200")
    func postCursorEventValidPayload() async throws {
        let (app, _) = try makeApp()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: sessionStartPayload())
            let response = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: body
            )
            #expect(response.status == .ok)
        }
    }

    @Test("POST /cursor-event unknown hook event returns 200 and creates no DevEvent")
    func postCursorUnknownEventDropped() async throws {
        let (app, db) = try makeApp()
        let sessionId = "cursor-unknown-event"

        try await app.test(.router) { client in
            // SessionStart first
            let startBody = ByteBuffer(string: sessionStartPayload(sessionId: sessionId))
            _ = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: startBody
            )

            // Unknown future event
            let unknownJson = """
            {
              "session_id": "\(sessionId)",
              "conversation_id": "\(sessionId)",
              "hook_event_name": "beforeShellExecution",
              "cursor_version": "3.1.0",
              "workspace_roots": ["/Users/test/myproject"],
              "command": "ls -la"
            }
            """
            let unknownBody = ByteBuffer(string: unknownJson)
            let response = try await client.execute(
                uri: "/cursor-event",
                method: .post,
                headers: [.authorization: "Bearer test-token"],
                body: unknownBody
            )
            #expect(response.status == .ok)
        }

        // No DevEvent should be created for the unknown hook
        let events = try await db.read { try DevEvent.fetchAll($0) }
        let unknownEvent = events.first { $0.sessionId == sessionId }
        #expect(unknownEvent == nil, "Unknown Cursor hook events must not create DevEvent records")
    }
}
