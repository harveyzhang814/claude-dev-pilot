import Foundation

public enum AuthTokenService {
    public static var defaultTokenPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".agentpilot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("token").path
    }

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func save(token: String, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try token.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public static func load(from path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func ensureToken(at path: String? = nil) throws -> String {
        let tokenPath = path ?? defaultTokenPath
        if FileManager.default.fileExists(atPath: tokenPath) {
            return try load(from: tokenPath)
        }
        let token = generateToken()
        try save(token: token, to: tokenPath)
        return token
    }
}
