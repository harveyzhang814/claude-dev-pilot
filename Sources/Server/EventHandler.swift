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

            // Parse HookPayload
            let payload: HookPayload?
            let parseError: Error?
            do {
                payload = try JSONDecoder().decode(HookPayload.self, from: data)
                parseError = nil
            } catch let e {
                payload = nil
                parseError = e
            }

            // Insert HookLog with final state (fire-and-forget)
            let log = HookLog(
                receivedAt: Date(),
                hookEventName: payload?.hookEventName ?? "PARSE_ERROR",
                sessionId: payload?.sessionId ?? "",
                notificationType: payload?.notificationType,
                rawPayload: rawPayload
            )
            try? await db.write { db in try log.insert(db) }

            // If parse failed, return 400
            if let error = parseError {
                throw HTTPError(.badRequest, message: "Invalid JSON payload: \(error.localizedDescription)")
            }

            // payload is guaranteed non-nil here: parseError guard above ensures decode succeeded
            let decoded = payload!

            // SessionStart / SessionEnd → lifecycle only, no DevEvent
            if decoded.hookEventName == "SessionStart" || decoded.hookEventName == "SessionEnd" {
                try SessionLifecycleService.handleSessionLifecycle(payload: decoded, in: db)
                return Response(status: .ok, headers: [:], body: .init())
            }

            // Map payload → DevEvent and persist
            let event = EventMapper.map(decoded)
            try SessionLifecycleService.processEvent(event, sessionTitle: decoded.title, in: db)

            // Feed Stop and Notification events into the stop window
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
