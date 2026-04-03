import Testing
import Foundation
@testable import Core

@Suite("CursorNormalizer")
struct CursorNormalizerTests {

    // MARK: - Event name normalization

    @Test("sessionStart → SessionStart")
    func sessionStart() {
        #expect(CursorNormalizer.normalizeEventName("sessionStart") == "SessionStart")
    }

    @Test("sessionEnd → SessionEnd")
    func sessionEnd() {
        #expect(CursorNormalizer.normalizeEventName("sessionEnd") == "SessionEnd")
    }

    @Test("stop → Stop")
    func stop() {
        #expect(CursorNormalizer.normalizeEventName("stop") == "Stop")
    }

    @Test("Unknown name passes through unchanged (forward compat)")
    func unknownPassthrough() {
        #expect(CursorNormalizer.normalizeEventName("beforeShellExecution") == "beforeShellExecution")
        #expect(CursorNormalizer.normalizeEventName("afterFileEdit") == "afterFileEdit")
    }

    // MARK: - Full normalize()

    @Test("normalize() maps workspace_roots[0] to cwd")
    func normalizeMapsWorkspaceRootsToCwd() {
        let cursor = makeCursorPayload(
            hookEventName: "stop",
            workspaceRoots: ["/Users/dev/myproject", "/other"]
        )
        let result = CursorNormalizer.normalize(cursor)
        #expect(result.cwd == "/Users/dev/myproject")
    }

    @Test("normalize() with empty workspace_roots → cwd = 'unknown' sentinel")
    func normalizeEmptyWorkspaceRoots() {
        let cursor = makeCursorPayload(hookEventName: "stop", workspaceRoots: [])
        let result = CursorNormalizer.normalize(cursor)
        // "unknown" sentinel prevents blank project name in the UI
        #expect(result.cwd == "unknown")
    }

    @Test("normalize() sets tool = cursor")
    func normalizeSetsToolCursor() {
        let cursor = makeCursorPayload(hookEventName: "sessionStart", workspaceRoots: ["/p"])
        let result = CursorNormalizer.normalize(cursor)
        #expect(result.tool == "cursor")
    }

    @Test("normalize() applies PascalCase event name")
    func normalizePascalCaseEventName() {
        let cursor = makeCursorPayload(hookEventName: "sessionStart", workspaceRoots: ["/p"])
        let result = CursorNormalizer.normalize(cursor)
        #expect(result.hookEventName == "SessionStart")
    }

    @Test("normalize() preserves session_id")
    func normalizePreservesSessionId() {
        let cursor = makeCursorPayload(hookEventName: "stop", workspaceRoots: ["/p"])
        let result = CursorNormalizer.normalize(cursor)
        #expect(result.sessionId == cursor.sessionId)
    }

    @Test("normalize() preserves model")
    func normalizePreservesModel() {
        let cursor = CursorHookPayload(
            sessionId: "s1",
            conversationId: "s1",
            hookEventName: "stop",
            workspaceRoots: ["/p"],
            cursorVersion: "3.0.4",
            model: "claude-4-sonnet",
            isBackgroundAgent: nil,
            composerMode: nil,
            transcriptPath: nil,
            status: nil,
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            command: nil
        )
        let result = CursorNormalizer.normalize(cursor)
        #expect(result.model == "claude-4-sonnet")
    }

    @Test("normalize() clears Claude Code-specific fields")
    func normalizeClearsCCFields() {
        let cursor = makeCursorPayload(hookEventName: "stop", workspaceRoots: ["/p"])
        let result = CursorNormalizer.normalize(cursor)
        #expect(result.tty == nil)
        #expect(result.terminalApp == nil)
        #expect(result.notificationType == nil)
    }

    // MARK: - Helpers

    private func makeCursorPayload(hookEventName: String, workspaceRoots: [String]) -> CursorHookPayload {
        CursorHookPayload(
            sessionId: "test-session-id",
            conversationId: "test-session-id",
            hookEventName: hookEventName,
            workspaceRoots: workspaceRoots,
            cursorVersion: "3.0.4",
            model: nil,
            isBackgroundAgent: nil,
            composerMode: nil,
            transcriptPath: nil,
            status: nil,
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            command: nil
        )
    }
}
