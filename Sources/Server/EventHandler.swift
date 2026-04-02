import Foundation
import GRDB
import Hummingbird
import Core

/// Route handlers for the event server.
enum EventHandler {

    /// POST /event — receives a HookPayload, maps it to a DevEvent, persists it, and calls the callback.
    static func postEvent(
        db: any DatabaseWriter & Sendable,
        onEvent: @Sendable @escaping (DevEvent) -> Void
    ) -> @Sendable (Request, BasicRequestContext) async throws -> Response {
        return { @Sendable request, context in
            // Collect body (max 64 KB)
            let buffer = try await request.body.collect(upTo: 64 * 1024)
            let data = Data(buffer: buffer)

            // Parse HookPayload
            let payload: HookPayload
            do {
                payload = try JSONDecoder().decode(HookPayload.self, from: data)
            } catch {
                throw HTTPError(.badRequest, message: "Invalid JSON payload: \(error.localizedDescription)")
            }

            // Route session lifecycle hooks directly — they never create DevEvent records
            let sessionHooks: Set<String> = ["SessionStart", "SessionEnd"]
            if sessionHooks.contains(payload.hookEventName) {
                try SessionLifecycleService.handleSessionLifecycle(payload: payload, in: db)
                return Response(status: .ok, headers: [:], body: .init())
            }

            // Task / notification hooks → existing pipeline
            let event = EventMapper.map(payload)

            // Persist via SessionLifecycleService
            try SessionLifecycleService.processEvent(event, in: db)

            // Notify callback
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
