import Testing
import Foundation
@testable import AgentDevPilot

@Suite("AuthTokenService")
struct AuthTokenServiceTests {

    private let testDir: String = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-dev-pilot-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    @Test("Generate token creates 32-byte hex string")
    func generateToken() {
        let token = AuthTokenService.generateToken()
        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })
    }

    @Test("Save and load token roundtrip")
    func saveAndLoad() throws {
        let tokenPath = "\(testDir)/token"
        let token = AuthTokenService.generateToken()
        try AuthTokenService.save(token: token, to: tokenPath)
        let loaded = try AuthTokenService.load(from: tokenPath)
        #expect(loaded == token)
    }

    @Test("Token file has restricted permissions (owner read-write only)")
    func filePermissions() throws {
        let tokenPath = "\(testDir)/token2"
        let token = AuthTokenService.generateToken()
        try AuthTokenService.save(token: token, to: tokenPath)
        let attrs = try FileManager.default.attributesOfItem(atPath: tokenPath)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("ensureToken creates token if missing, reuses if exists")
    func ensureToken() throws {
        let tokenPath = "\(testDir)/token3"
        let first = try AuthTokenService.ensureToken(at: tokenPath)
        let second = try AuthTokenService.ensureToken(at: tokenPath)
        #expect(first == second)
        #expect(first.count == 64)
    }
}
