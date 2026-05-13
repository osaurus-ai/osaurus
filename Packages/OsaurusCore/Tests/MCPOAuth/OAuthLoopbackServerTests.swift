//
//  OAuthLoopbackServerTests.swift
//  osaurusTests
//
//  Smoke tests for the shared OAuth loopback server.
//  We only test the success / state-mismatch paths because the bind+listen
//  flow needs real Network framework state.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("OAuth loopback server")
struct OAuthLoopbackServerTests {
    @Test func startReturnsBoundPortImmediately() async throws {
        // Regression: `start()` must await `.ready` before returning. The OAuth flow
        // builds the redirect URI from `boundPort` on the very next line, and a
        // returned-too-early `start()` produces `http://127.0.0.1:0/callback`,
        // which Chrome rejects with ERR_UNSAFE_PORT.
        let server = try OAuthLoopbackServer(
            expectedState: "state-abc",
            port: .ephemeral,
            callbackPath: "/callback"
        )
        try await server.start()
        defer { server.stop() }

        let port = try #require(server.boundPort)
        #expect(port != 0, "boundPort must be the kernel-assigned port, not the requested .any (0)")
        #expect(port > 1024, "ephemeral ports should be in the unprivileged range")
    }

    @Test func successCallbackResolvesAwaiter() async throws {
        let server = try OAuthLoopbackServer(
            expectedState: "expected-state",
            port: .ephemeral,
            callbackPath: "/callback"
        )
        try await server.start()
        defer { server.stop() }

        let port = try #require(server.boundPort)
        let task = Task { try await server.waitForCallback() }

        // Hit the loopback URL after a small delay so the callback handler is wired.
        try await Task.sleep(nanoseconds: 100_000_000)
        let callbackURL = URL(
            string: "http://127.0.0.1:\(port)/callback?state=expected-state&code=auth-code"
        )!
        _ = try? await URLSession.shared.data(from: callbackURL)

        let parsed = try await task.value
        #expect(parsed.code == "auth-code")
        #expect(parsed.state == "expected-state")
    }

    @Test func stateMismatchRejectsCallback() async throws {
        let server = try OAuthLoopbackServer(
            expectedState: "real-state",
            port: .ephemeral,
            callbackPath: "/callback"
        )
        try await server.start()
        defer { server.stop() }

        let port = try #require(server.boundPort)
        let task = Task { try await server.waitForCallback() }

        try await Task.sleep(nanoseconds: 100_000_000)
        let badURL = URL(
            string: "http://127.0.0.1:\(port)/callback?state=tampered&code=x"
        )!
        _ = try? await URLSession.shared.data(from: badURL)

        var threwExpectedError = false
        do {
            _ = try await task.value
        } catch is OAuthLoopbackError {
            threwExpectedError = true
        } catch {
            // Some other error type — unexpected.
        }
        #expect(threwExpectedError, "expected loopback to reject state-mismatched callback")
    }
}
