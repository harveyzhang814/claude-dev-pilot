import Testing
@testable import Core

@Suite("JournalEventNormalizerTests")
struct JournalEventNormalizerTests {

    // MARK: - UserPromptSubmit

    @Test("user entry with plain string content → UserPromptSubmit")
    func userPlainString() {
        let entry: [String: Any] = [
            "type": "user",
            "sessionId": "sess-1",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:00:00.000Z",
            "message": ["role": "user", "content": "hello"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "UserPromptSubmit")
        #expect(payload?.sessionId == "sess-1")
        #expect(payload?.cwd == "/tmp/proj")
        #expect(payload?.eventSource == .fileWatcher)
    }

    @Test("user entry with list content (tool_result) → nil")
    func userToolResult() {
        let entry: [String: Any] = [
            "type": "user",
            "sessionId": "sess-1",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:00:00.000Z",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "x"]]]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    // MARK: - AskUserQuestion

    @Test("assistant entry with AskUserQuestion tool_use → Notification/permissionNeeded")
    func assistantAskUserQuestion() {
        let entry: [String: Any] = [
            "type": "assistant",
            "sessionId": "sess-2",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:01:00.000Z",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "tool_use", "name": "AskUserQuestion", "id": "t1", "input": ["question": "proceed?"]]
                ]
            ]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "Notification")
        #expect(payload?.notificationType == "permission_prompt")
        #expect(payload?.sessionId == "sess-2")
        #expect(payload?.eventSource == .fileWatcher)
    }

    @Test("assistant entry with other tool_use → nil")
    func assistantOtherTool() {
        let entry: [String: Any] = [
            "type": "assistant",
            "sessionId": "sess-2",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:01:00.000Z",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "tool_use", "name": "Bash", "id": "t2", "input": ["command": "ls"]]
                ]
            ]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    // MARK: - Stop (new format v2.1.92+)

    @Test("system entry with stop_hook_summary subtype → Stop")
    func systemStopHookSummary() {
        // Real structure: subtype is a top-level field, no message dict
        let entry: [String: Any] = [
            "type": "system",
            "subtype": "stop_hook_summary",
            "sessionId": "sess-3",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:02:00.000Z",
            "hookCount": 0
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "Stop")
        #expect(payload?.sessionId == "sess-3")
        #expect(payload?.eventSource == .fileWatcher)
    }

    @Test("system entry with other subtype → nil")
    func systemOtherSubtype() {
        let entry: [String: Any] = [
            "type": "system",
            "subtype": "turn_duration",
            "sessionId": "sess-3",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:02:00.000Z"
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    // MARK: - Legacy hook events (progress entries, v≤2.1.81)

    @Test("progress entry with hookEvent=SessionStart → SessionStart")
    func progressSessionStart() {
        let entry: [String: Any] = [
            "type": "progress",
            "sessionId": "sess-4",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:03:00.000Z",
            "data": ["type": "hook_progress", "hookEvent": "SessionStart", "hookName": "SessionStart:startup"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "SessionStart")
        #expect(payload?.eventSource == .fileWatcher)
    }

    @Test("progress entry with hookEvent=Stop → Stop")
    func progressStop() {
        let entry: [String: Any] = [
            "type": "progress",
            "sessionId": "sess-4",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:03:01.000Z",
            "data": ["type": "hook_progress", "hookEvent": "Stop", "hookName": "Stop:stop"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "Stop")
        #expect(payload?.eventSource == .fileWatcher)
    }

    @Test("progress entry with hookEvent=UserPromptSubmit → UserPromptSubmit")
    func progressUserPromptSubmit() {
        let entry: [String: Any] = [
            "type": "progress",
            "sessionId": "sess-4",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:03:02.000Z",
            "data": ["type": "hook_progress", "hookEvent": "UserPromptSubmit"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload?.hookEventName == "UserPromptSubmit")
    }

    @Test("progress entry with hookEvent=PostToolUse → nil")
    func progressPostToolUse() {
        let entry: [String: Any] = [
            "type": "progress",
            "sessionId": "sess-4",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:03:03.000Z",
            "data": ["type": "hook_progress", "hookEvent": "PostToolUse"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    // MARK: - Missing fields

    @Test("entry missing sessionId → nil")
    func missingSessionId() {
        let entry: [String: Any] = [
            "type": "user",
            "cwd": "/tmp/proj",
            "timestamp": "2026-04-16T10:00:00.000Z",
            "message": ["role": "user", "content": "hi"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    @Test("entry with empty cwd → nil")
    func emptyCwd() {
        let entry: [String: Any] = [
            "type": "user",
            "sessionId": "sess-1",
            "cwd": "",
            "timestamp": "2026-04-16T10:00:00.000Z",
            "message": ["role": "user", "content": "hi"]
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }

    @Test("unknown entry type → nil")
    func unknownType() {
        let entry: [String: Any] = [
            "type": "file-history-snapshot",
            "sessionId": "sess-1",
            "cwd": "/tmp/proj"
        ]
        let payload = JournalEventNormalizer.normalize(entry)
        #expect(payload == nil)
    }
}
