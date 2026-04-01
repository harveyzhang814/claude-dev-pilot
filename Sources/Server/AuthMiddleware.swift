import Foundation
import Hummingbird

/// Middleware that validates Bearer token authentication on all routes except GET /health.
struct AuthMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext

    let expectedToken: String

    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        // Allow GET /health without auth
        if request.method == .get && request.uri.path == "/health" {
            return try await next(request, context)
        }

        // Validate Bearer token
        guard let authHeader = request.headers[.authorization] else {
            throw HTTPError(.unauthorized, message: "Missing Authorization header")
        }

        let prefix = "Bearer "
        guard authHeader.hasPrefix(prefix) else {
            throw HTTPError(.unauthorized, message: "Invalid Authorization header format")
        }

        let token = String(authHeader.dropFirst(prefix.count))
        guard token == expectedToken else {
            throw HTTPError(.unauthorized, message: "Invalid token")
        }

        return try await next(request, context)
    }
}
