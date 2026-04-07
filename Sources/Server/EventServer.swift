import Foundation
import GRDB
import Hummingbird
import Core

/// Builds and starts the HTTP event server.
public enum EventServer {

    /// Builds the Hummingbird Application with routes and middleware configured.
    /// Used by tests (does not bind to a port).
    public static func buildApp(
        db: any DatabaseWriter & Sendable,
        authToken: String,
        coordinator: HookStreamCoordinator,
        onEvent: @Sendable @escaping (DevEvent) -> Void
    ) -> some ApplicationProtocol {
        let router = Router()
        configureRoutes(router, db: db, authToken: authToken, coordinator: coordinator, onEvent: onEvent)
        return Application(router: router)
    }

    /// Builds the application and configures it to listen on 127.0.0.1:port.
    public static func start(
        db: any DatabaseWriter & Sendable,
        authToken: String,
        port: Int,
        coordinator: HookStreamCoordinator,
        onEvent: @Sendable @escaping (DevEvent) -> Void
    ) -> some ApplicationProtocol {
        let router = Router()
        configureRoutes(router, db: db, authToken: authToken, coordinator: coordinator, onEvent: onEvent)
        let config = ApplicationConfiguration(address: .hostname("127.0.0.1", port: port))
        return Application(router: router, configuration: config)
    }

    // MARK: - Private

    /// Registers all routes and middleware on the given router.
    /// Single source of truth — both buildApp() and start() call this.
    private static func configureRoutes(
        _ router: Router<BasicRequestContext>,
        db: any DatabaseWriter & Sendable,
        authToken: String,
        coordinator: HookStreamCoordinator,
        onEvent: @Sendable @escaping (DevEvent) -> Void
    ) {
        router.middlewares.add(AuthMiddleware(expectedToken: authToken))
        router.get("/health", use: EventHandler.getHealth())
        router.post("/event", use: EventHandler.postEvent(db: db, coordinator: coordinator, onEvent: onEvent))
        router.post("/cursor-event", use: EventHandler.postCursorEvent(db: db, coordinator: coordinator, onEvent: onEvent))
    }
}
