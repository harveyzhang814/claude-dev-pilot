import Testing
import Foundation
@testable import Core

@Suite("CursorHookPayload JSON Parsing")
struct CursorHookPayloadTests {

    // MARK: - Real spike payloads

    @Test("Parse sessionStart payload (spike sample)")
    func sessionStartPayload() throws {
        let json = """
        {
            "conversation_id": "8f09333b-c2ee-49dc-85c1-f73bebbbb1ae",
            "generation_id": "",
            "model": "default",
            "is_background_agent": false,
            "composer_mode": "agent",
            "session_id": "8f09333b-c2ee-49dc-85c1-f73bebbbb1ae",
            "hook_event_name": "sessionStart",
            "cursor_version": "3.0.4",
            "workspace_roots": ["/Users/dev/Projects/myproject"],
            "transcript_path": null
        }
        """
        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: Data(json.utf8))
        #expect(payload.sessionId == "8f09333b-c2ee-49dc-85c1-f73bebbbb1ae")
        #expect(payload.conversationId == "8f09333b-c2ee-49dc-85c1-f73bebbbb1ae")
        #expect(payload.hookEventName == "sessionStart")
        #expect(payload.workspaceRoots == ["/Users/dev/Projects/myproject"])
        #expect(payload.cursorVersion == "3.0.4")
        #expect(payload.model == "default")
        #expect(payload.isBackgroundAgent == false)
        #expect(payload.transcriptPath == nil)
    }

    @Test("Parse stop payload with token counts (spike sample)")
    func stopPayloadWithTokens() throws {
        let json = """
        {
            "conversation_id": "8f09333b-c2ee-49dc-85c1-f73bebbbb1ae",
            "status": "completed",
            "loop_count": 0,
            "input_tokens": 177728,
            "output_tokens": 945,
            "cache_read_tokens": 161280,
            "cache_write_tokens": 16448,
            "session_id": "8f09333b-c2ee-49dc-85c1-f73bebbbb1ae",
            "hook_event_name": "stop",
            "cursor_version": "3.0.4",
            "workspace_roots": ["/Users/dev/Projects/myproject"]
        }
        """
        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: Data(json.utf8))
        #expect(payload.hookEventName == "stop")
        #expect(payload.status == "completed")
        #expect(payload.inputTokens == 177728)
        #expect(payload.outputTokens == 945)
        #expect(payload.cacheReadTokens == 161280)
        #expect(payload.cacheWriteTokens == 16448)
    }

    @Test("Parse sessionEnd payload")
    func sessionEndPayload() throws {
        let json = """
        {
            "conversation_id": "sess-end-123",
            "session_id": "sess-end-123",
            "hook_event_name": "sessionEnd",
            "cursor_version": "3.0.4",
            "workspace_roots": ["/Users/dev/Projects/myproject"]
        }
        """
        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: Data(json.utf8))
        #expect(payload.hookEventName == "sessionEnd")
        #expect(payload.sessionId == "sess-end-123")
    }

    @Test("Unknown fields are ignored (forward compat)")
    func unknownFieldsIgnored() throws {
        let json = """
        {
            "session_id": "abc",
            "conversation_id": "abc",
            "hook_event_name": "sessionStart",
            "workspace_roots": [],
            "unknown_future_field": "someValue",
            "another_future_field": 42
        }
        """
        // Should not throw
        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: Data(json.utf8))
        #expect(payload.sessionId == "abc")
    }

    @Test("Empty workspace_roots array")
    func emptyWorkspaceRoots() throws {
        let json = """
        {
            "session_id": "abc",
            "conversation_id": "abc",
            "hook_event_name": "stop",
            "workspace_roots": []
        }
        """
        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: Data(json.utf8))
        #expect(payload.workspaceRoots.isEmpty)
    }

    @Test("Missing workspace_roots key defaults to empty array (forward compat)")
    func missingWorkspaceRootsDefaultsToEmpty() throws {
        let json = """
        {
            "session_id": "abc",
            "conversation_id": "abc",
            "hook_event_name": "sessionStart"
        }
        """
        let payload = try JSONDecoder().decode(CursorHookPayload.self, from: Data(json.utf8))
        #expect(payload.workspaceRoots.isEmpty)
    }
}
