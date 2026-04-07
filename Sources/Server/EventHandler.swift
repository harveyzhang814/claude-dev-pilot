import Foundation
import GRDB
import Hummingbird
import Core

/// Route handlers for the event server.
enum EventHandler {

    /// POST /event — receives a HookPayload, routes it through HookStreamCoordinator,
    /// and feeds any resulting DevEvent into the onEvent callback.
    static func postEvent(
        db: any DatabaseWriter & Sendable,
        coordinator: HookStreamCoordinator,
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

            // If HookPayload decode failed, check whether it's a Cursor-format payload
            // delivered to the wrong endpoint. Cursor (or its extensions) appear to
            // POST agent events to /event in addition to /cursor-event. Log it with a
            // dedicated event name and return 200 OK to avoid noisy 400 errors.
            if parseError != nil,
               let _ = try? JSONDecoder().decode(CursorHookPayload.self, from: data) {
                let misdirectedLog = HookLog(
                    receivedAt: Date(),
                    hookEventName: "cursor_misdirected",
                    sessionId: "",
                    notificationType: nil,
                    rawPayload: rawPayload,
                    endpoint: "/event"
                )
                try? await db.write { db in try misdirectedLog.insert(db) }
                return Response(status: .ok, headers: [:], body: .init())
            }

            let log = HookLog(
                receivedAt: Date(),
                hookEventName: payload?.hookEventName ?? "PARSE_ERROR",
                sessionId: payload?.sessionId ?? "",
                notificationType: payload?.notificationType,
                rawPayload: rawPayload,
                endpoint: "/event"
            )
            try? await db.write { db in try log.insert(db) }

            if let error = parseError {
                throw HTTPError(.badRequest, message: "Invalid JSON payload: \(error.localizedDescription)")
            }

            let decoded = payload!

            await coordinator.process(decoded)

            // Notify the app of any new events (for NotificationBatcher)
            if let latest = try await db.read({ db in
                try DevEvent
                    .filter(DevEvent.Columns.sessionId == decoded.sessionId)
                    .order(DevEvent.Columns.timestamp.desc)
                    .fetchOne(db)
            }) {
                onEvent(latest)
            }

            return Response(status: .ok, headers: [:], body: .init())
        }
    }

    /// POST /cursor-event — receives a CursorHookPayload, normalizes it to HookPayload,
    /// then routes through HookStreamCoordinator identical to /event.
    static func postCursorEvent(
        db: any DatabaseWriter & Sendable,
        coordinator: HookStreamCoordinator,
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
                rawPayload: rawPayload,
                endpoint: "/cursor-event"
            )
            try? await db.write { db in try log.insert(db) }

            if let error = parseError {
                throw HTTPError(.badRequest, message: "Invalid JSON payload: \(error.localizedDescription)")
            }

            let cursor = cursorPayload!

            // Normalize Cursor payload → shared HookPayload (injects tool="cursor", PascalCase names)
            let decoded = CursorNormalizer.normalize(cursor)

            await coordinator.process(decoded)

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
