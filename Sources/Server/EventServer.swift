import Foundation
import GRDB
import Hummingbird
import Core

/// Builds and starts the HTTP event server.
public enum EventServer {

    /// Builds the Hummingbird Application with routes and middleware configured.
    ///
    /// - Parameters:
    ///   - db: Database writer for persisting events.
    ///   - authToken: Bearer token required for authenticated routes.
    ///   - onEvent: Callback invoked after each event is persisted.
    /// - Returns: Configured `Application`.
    public static func buildApp(
        db: any DatabaseWriter & Sendable,
        authToken: String,
        onEvent: @Sendable @escaping (DevEvent) -> Void
    ) -> some ApplicationProtocol {
        let router = Router()

        // Auth middleware applies to all routes
        router.middlewares.add(AuthMiddleware(expectedToken: authToken))

        // GET /health — no auth required (middleware skips this)
        router.get("/health", use: EventHandler.getHealth())

        // POST /event — requires auth
        router.post("/event", use: EventHandler.postEvent(db: db, onEvent: onEvent))

        return Application(router: router)
    }

    /// Builds the application and configures it to listen on 127.0.0.1:port.
    ///
    /// - Parameters:
    ///   - db: Database writer for persisting events.
    ///   - authToken: Bearer token required for authenticated routes.
    ///   - port: Port to listen on.
    ///   - onEvent: Callback invoked after each event is persisted.
    /// - Returns: Configured `Application` bound to localhost:port.
    public static func start(
        db: any DatabaseWriter & Sendable,
        authToken: String,
        port: Int,
        onEvent: @Sendable @escaping (DevEvent) -> Void
    ) -> some ApplicationProtocol {
        let router = Router()

        router.middlewares.add(AuthMiddleware(expectedToken: authToken))
        router.get("/health", use: EventHandler.getHealth())
        router.post("/event", use: EventHandler.postEvent(db: db, onEvent: onEvent))

        let config = ApplicationConfiguration(
            address: .hostname("127.0.0.1", port: port)
        )
        return Application(router: router, configuration: config)
    }
}
