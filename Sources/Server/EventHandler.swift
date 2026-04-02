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
            // Collect body (max 64 KB)
            let buffer = try await request.body.collect(upTo: 64 * 1024)
            let data = Data(buffer: buffer)
            let rawPayload = String(data: data, encoding: .utf8) ?? "[non-UTF-8 body]"

            // Insert preliminary log before any business logic
            let logId = UUID().uuidString
            let log = HookLog(
                id: logId,
                receivedAt: Date(),
                hookEventName: "UNKNOWN",
                sessionId: "",
                notificationType: nil,
                rawPayload: rawPayload
            )
            try? HookLogStore.insert(log, in: db)

            // Parse HookPayload
            let payload: HookPayload
            do {
                payload = try JSONDecoder().decode(HookPayload.self, from: data)
            } catch {
                try? await db.write { db in
                    try db.execute(
                        sql: "UPDATE hook_logs SET hook_event_name = 'PARSE_ERROR' WHERE id = ?",
                        arguments: [logId]
                    )
                }
                throw HTTPError(.badRequest, message: "Invalid JSON payload: \(error.localizedDescription)")
            }

            // Update log with decoded fields
            try? await db.write { db in
                try db.execute(
                    sql: """
                        UPDATE hook_logs
                        SET hook_event_name = ?, session_id = ?, notification_type = ?
                        WHERE id = ?
                        """,
                    arguments: [payload.hookEventName, payload.sessionId,
                                payload.notificationType, logId]
                )
            }

            // SessionStart / SessionEnd → lifecycle only, no DevEvent
            if payload.hookEventName == "SessionStart" || payload.hookEventName == "SessionEnd" {
                try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)
                return Response(status: .ok, headers: [:], body: .init())
            }

            // Map payload → DevEvent and persist
            let event = EventMapper.map(payload)
            try SessionLifecycleService.processEvent(event, sessionTitle: payload.title, in: db)

            // Feed Stop and Notification events into the stop window
            switch payload.hookEventName {
            case "Stop":
                await stopWindow.recordStop(sessionId: payload.sessionId)
            case "Notification":
                switch payload.notificationType {
                case "permission_prompt", "elicitation_dialog":
                    await stopWindow.recordNotification(sessionId: payload.sessionId)
                case "idle_prompt":
                    await stopWindow.recordStop(sessionId: payload.sessionId)
                default:
                    break
                }
            default:
                break
            }

            // Notify callback (drives NotificationBatcher → native notifications)
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
