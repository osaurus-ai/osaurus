import Foundation
import XCTest

@testable import OsaurusCLICore

final class MCPBundleManifestTests: XCTestCase {
    /// Decode a minimal manifest whose entry point carries the given env map.
    private func manifest(env: [String: String]) throws -> MCPBundleManifest {
        let entries = env.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ",")
        let json = """
            {
              "mcpVersion": "0.1.0",
              "name": "test",
              "version": "1.0.0",
              "entry": { "command": "node", "args": [], "env": { \(entries) } }
            }
            """
        return try JSONDecoder().decode(MCPBundleManifest.self, from: Data(json.utf8))
    }

    /// Embedded token: `${env:VAR}` inside a larger string must be substituted.
    func testResolveEnvironmentSubstitutesEmbeddedToken() throws {
        setenv("OSAURUS_TEST_HOST", "example.com", 1)
        defer { unsetenv("OSAURUS_TEST_HOST") }

        let m = try manifest(env: ["URL": "https://${env:OSAURUS_TEST_HOST}/path"])
        XCTAssertEqual(m.resolveEnvironment()["URL"], "https://example.com/path")
    }

    /// Multiple tokens in one value must each be substituted.
    func testResolveEnvironmentSubstitutesMultipleTokens() throws {
        setenv("OSAURUS_TEST_A", "x", 1)
        setenv("OSAURUS_TEST_B", "y", 1)
        defer {
            unsetenv("OSAURUS_TEST_A")
            unsetenv("OSAURUS_TEST_B")
        }

        let m = try manifest(env: ["PAIR": "${env:OSAURUS_TEST_A}:${env:OSAURUS_TEST_B}"])
        XCTAssertEqual(m.resolveEnvironment()["PAIR"], "x:y")
    }

    /// Regression guard: a whole-value token still resolves (the path that worked before).
    func testResolveEnvironmentSubstitutesWholeValueToken() throws {
        setenv("OSAURUS_TEST_TOKEN", "secret", 1)
        defer { unsetenv("OSAURUS_TEST_TOKEN") }

        let m = try manifest(env: ["TOKEN": "${env:OSAURUS_TEST_TOKEN}"])
        XCTAssertEqual(m.resolveEnvironment()["TOKEN"], "secret")
    }

    /// Regression guard: a literal value with no token is returned unchanged.
    func testResolveEnvironmentLeavesLiteralUnchanged() throws {
        let m = try manifest(env: ["PLAIN": "just-a-value"])
        XCTAssertEqual(m.resolveEnvironment()["PLAIN"], "just-a-value")
    }

    /// An unset variable resolves to the empty string (documents the missing-var policy).
    func testResolveEnvironmentMissingVariableResolvesEmpty() throws {
        unsetenv("OSAURUS_TEST_DEFINITELY_UNSET")

        let m = try manifest(env: ["X": "${env:OSAURUS_TEST_DEFINITELY_UNSET}"])
        XCTAssertEqual(m.resolveEnvironment()["X"], "")
    }

    /// The pure helper is directly unit-testable with an injected environment.
    func testSubstituteEnvTokensPureFunction() {
        let env = ["A": "x", "B": "y", "HOST": "example.com"]
        XCTAssertEqual(
            MCPBundleManifest.substituteEnvTokens("${env:A}:${env:B}", environment: env),
            "x:y"
        )
        XCTAssertEqual(
            MCPBundleManifest.substituteEnvTokens("https://${env:HOST}/p", environment: env),
            "https://example.com/p"
        )
        XCTAssertEqual(
            MCPBundleManifest.substituteEnvTokens("plain", environment: env),
            "plain"
        )
        XCTAssertEqual(
            MCPBundleManifest.substituteEnvTokens("${env:MISSING}", environment: env),
            ""
        )
    }
}
