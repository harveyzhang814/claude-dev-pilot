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

    private func makeApp(authToken: String = "test-token") throws -> some ApplicationProtocol {
        let db = try DatabaseManager.openInMemoryDatabase()
        return EventServer.buildApp(db: db, authToken: authToken) { _ in }
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
        let app = try makeApp()
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
        let app = try makeApp()
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
        let app = try makeApp()
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
        let app = try makeApp()
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
        let app = try makeApp(authToken: "correct-token")
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
}
