import Foundation
import GRDB
import Hummingbird
import Core

/// Route handlers for the event server.
enum EventHandler {

    /// POST /event — receives a HookPayload, routes it, persists a DevEvent where appropriate,
    /// and feeds Stop/Notification events into the StopWindowService.
    static func postEvent(
        db: any DatabaseWriter & Sendable,
        stopWindow: StopWindowService,
        onEvent: @Sendable @escaping (DevEvent) -> Void
    ) -> @Sendable (Request, BasicRequestContext) async throws -> Response {
        return { @Sendable request, context in
            let buffer = try await request.body.collect(upTo: 64 * 1024)
            let data = Data(buffer: buffer)
            let rawPayload = String(data: data, encoding: .utf8) ?? "[non-UTF-8 body]"

            let payload: HookPayload?
            let parseError: Error?
            do {
                payload = try JSONDecoder().decode(HookPayload.self, from: data)
                parseError = nil
            } catch let e {
                payload = nil
                parseError = e
            }

            let log = HookLog(
                receivedAt: Date(),
                hookEventName: payload?.hookEventName ?? "PARSE_ERROR",
                sessionId: payload?.sessionId ?? "",
                notificationType: payload?.notificationType,
                rawPayload: rawPayload
            )
            try? await db.write { db in try log.insert(db) }

            if let error = parseError {
                throw HTTPError(.badRequest, message: "Invalid JSON payload: \(error.localizedDescription)")
            }

            let decoded = payload!

            if decoded.hookEventName == "SessionStart" || decoded.hookEventName == "SessionEnd" {
                try SessionLifecycleService.handleSessionLifecycle(payload: decoded, in: db)
                return Response(status: .ok, headers: [:], body: .init())
            }

            let event = EventMapper.map(decoded)
            // Always use "claude-code" — do not trust the tool field from the wire.
            // The /event endpoint is exclusively for Claude Code hooks; tool identity
            // is determined by endpoint, not by the client-supplied payload.
            try SessionLifecycleService.processEvent(event, sessionTitle: decoded.title, tool: "claude-code", in: db)

            switch decoded.hookEventName {
            case "Stop":
                await stopWindow.recordStop(sessionId: decoded.sessionId)
            case "Notification":
                switch decoded.notificationType {
                case "permission_prompt", "elicitation_dialog":
                    await stopWindow.recordNotification(sessionId: decoded.sessionId)
                case "idle_prompt":
                    await stopWindow.recordStop(sessionId: decoded.sessionId)
                default:
                    break
                }
            default:
                break
            }

            onEvent(event)
            return Response(status: .ok, headers: [:], body: .init())
        }
    }

    /// POST /cursor-event — receives a CursorHookPayload, normalizes it to HookPayload,
    /// then routes through the shared pipeline identical to /event.
    static func postCursorEvent(
        db: any DatabaseWriter & Sendable,
        stopWindow: StopWindowService,
        onEvent: @Sendable @escaping (DevEvent) -> Void
    ) -> @Sendable (Request, BasicRequestContext) async throws -> Response {
        return { @Sendable request, context in
            let buffer = try await request.body.collect(upTo: 64 * 1024)
            let data = Data(buffer: buffer)
            let rawPayload = String(data: data, encoding: .utf8) ?? "[non-UTF-8 body]"

            // Parse as CursorHookPayload (Cursor-specific wire format)
            let cursorPayload: CursorHookPayload?
            let parseError: Error?
            do {
                cursorPayload = try JSONDecoder().decode(CursorHookPayload.self, from: data)
                parseError = nil
            } catch let e {
                cursorPayload = nil
                parseError = e
            }

            // Log raw payload before normalization (preserves original camelCase names)
            let log = HookLog(
                receivedAt: Date(),
                hookEventName: cursorPayload?.hookEventName ?? "PARSE_ERROR",
                sessionId: cursorPayload?.sessionId ?? "",
                notificationType: nil,
                rawPayload: rawPayload
            )
            try? await db.write { db in try log.insert(db) }

            if let error = parseError {
                throw HTTPError(.badRequest, message: "Invalid JSON payload: \(error.localizedDescription)")
            }

            let cursor = cursorPayload!

            // Normalize Cursor payload → shared HookPayload (injects tool="cursor", PascalCase names)
            let decoded = CursorNormalizer.normalize(cursor)

            if decoded.hookEventName == "SessionStart" || decoded.hookEventName == "SessionEnd" {
                try SessionLifecycleService.handleSessionLifecycle(payload: decoded, in: db)
                return Response(status: .ok, headers: [:], body: .init())
            }

            // Only handle known event types. Unknown events (future Cursor hooks) are
            // silently acknowledged to avoid creating spurious agentStopped events.
            guard decoded.hookEventName == "Stop" else {
                return Response(status: .ok, headers: [:], body: .init())
            }

            let event = EventMapper.map(decoded)
            // Pass tool="cursor" explicitly so the fallback session path tags correctly
            try SessionLifecycleService.processEvent(event, sessionTitle: nil, tool: "cursor", in: db)

            // Feed stop into the window; Cursor has no Notification hook equivalent
            await stopWindow.recordStop(sessionId: decoded.sessionId)

            onEvent(event)
            return Response(status: .ok, headers: [:], body: .init())
        }
    }

    /// GET /health — returns version and status.
    static func getHealth() -> @Sendable (Request, BasicRequestContext) async throws -> Response {
        return { @Sendable _, _ in
            let body = #"{"version":"1.0.0","status":"running"}"#
            let buffer = ByteBuffer(string: body)
            return Response(
                status: .ok,
                headers: HTTPFields(dictionaryLiteral: (.contentType, "application/json")),
                body: .init(byteBuffer: buffer)
            )
        }
    }
}
