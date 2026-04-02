import Testing
import Foundation
@testable import Core

@Suite("HookPayload JSON Parsing")
struct HookPayloadTests {

    @Test("Valid JSON with all fields")
    func validFullPayload() throws {
        let json = """
        {
            "session_id": "abc-123",
            "transcript_path": "/Users/dev/.claude/sessions/abc.json",
            "cwd": "/Users/dev/myproject",
            "hook_event_name": "Notification",
            "message": "Task completed successfully",
            "title": "Claude Code",
            "notification_type": "idle_prompt",
            "permission_mode": "default"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload.sessionId == "abc-123")
        #expect(payload.transcriptPath == "/Users/dev/.claude/sessions/abc.json")
        #expect(payload.cwd == "/Users/dev/myproject")
        #expect(payload.hookEventName == "Notification")
        #expect(payload.message == "Task completed successfully")
        #expect(payload.title == "Claude Code")
        #expect(payload.notificationType == "idle_prompt")
        #expect(payload.permissionMode == "default")
    }

    @Test("Valid JSON with only required fields")
    func validMinimalPayload() throws {
        let json = """
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/myproject",
            "hook_event_name": "Notification",
            "message": "Hello"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload.sessionId == "abc-123")
        #expect(payload.title == nil)
        #expect(payload.notificationType == nil)
        #expect(payload.transcriptPath == nil)
        #expect(payload.permissionMode == nil)
    }

    @Test("Malformed JSON returns nil")
    func malformedJson() {
        let json = "not json at all".data(using: .utf8)!
        let payload = try? JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload == nil)
    }

    @Test("Empty JSON object returns nil (missing required fields)")
    func emptyObject() {
        let json = "{}".data(using: .utf8)!
        let payload = try? JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload == nil)
    }

    @Test("Array instead of object returns nil")
    func arrayInsteadOfObject() {
        let json = "[1, 2, 3]".data(using: .utf8)!
        let payload = try? JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload == nil)
    }

    @Test("SessionStart payload with source and model fields")
    func testSessionStartPayloadDecoding() throws {
        let json = """
        {
            "session_id": "abc123",
            "cwd": "/Users/me/Projects/myapp",
            "hook_event_name": "SessionStart",
            "source": "startup",
            "model": "claude-sonnet-4-6"
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload.hookEventName == "SessionStart")
        #expect(payload.source == "startup")
        #expect(payload.model == "claude-sonnet-4-6")
        #expect(payload.message == "")  // default when omitted
    }

    @Test("SessionEnd payload without message field")
    func testSessionEndPayloadDecodingWithoutMessage() throws {
        let json = """
        {
            "session_id": "abc123",
            "cwd": "/Users/me/Projects/myapp",
            "hook_event_name": "SessionEnd"
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload.hookEventName == "SessionEnd")
        #expect(payload.message == "")
        #expect(payload.source == nil)
        #expect(payload.model == nil)
    }

    @Test("Unknown fields are ignored")
    func unknownFieldsIgnored() throws {
        let json = """
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/myproject",
            "hook_event_name": "Notification",
            "message": "Hello",
            "some_future_field": "unknown",
            "another_field": 42
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(HookPayload.self, from: json)
        #expect(payload.sessionId == "abc-123")
    }
}
