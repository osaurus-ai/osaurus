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

    @Test func allowlistedOriginGetsCorsHeader() async throws {
        // xAI/Grok delivers the code via a cross-origin fetch from auth.x.ai, so
        // the callback response must echo Access-Control-Allow-Origin or the
        // browser blocks it ("Could not establish connection").
        let server = try OAuthLoopbackServer(
            expectedState: "state-cors",
            port: .ephemeral,
            callbackPath: "/callback",
            corsOriginAllowlist: ["auth.x.ai", "accounts.x.ai"]
        )
        try await server.start()
        defer { server.stop() }

        let port = try #require(server.boundPort)
        let task = Task { try await server.waitForCallback() }

        try await Task.sleep(nanoseconds: 100_000_000)
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/callback?state=state-cors&code=auth-code")!
        )
        request.setValue("https://auth.x.ai", forHTTPHeaderField: "Origin")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "https://auth.x.ai")

        let parsed = try await task.value
        #expect(parsed.code == "auth-code")
    }

    @Test func nonAllowlistedOriginGetsNoCorsHeader() async throws {
        let server = try OAuthLoopbackServer(
            expectedState: "state-noorigin",
            port: .ephemeral,
            callbackPath: "/callback",
            corsOriginAllowlist: ["auth.x.ai"]
        )
        try await server.start()
        defer { server.stop() }

        let port = try #require(server.boundPort)
        let task = Task { try await server.waitForCallback() }

        try await Task.sleep(nanoseconds: 100_000_000)
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/callback?state=state-noorigin&code=c")!
        )
        request.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)

        _ = try await task.value
    }

    @Test func unrelatedProbeDoesNotCompleteFlow() async throws {
        // A favicon (or CORS-preflight) probe must not resolve the awaiter; the
        // real callback that arrives afterward should still succeed.
        let server = try OAuthLoopbackServer(
            expectedState: "state-probe",
            port: .ephemeral,
            callbackPath: "/callback"
        )
        try await server.start()
        defer { server.stop() }

        let port = try #require(server.boundPort)
        let task = Task { try await server.waitForCallback() }

        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try? await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try? await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/callback?state=state-probe&code=ok")!
        )

        let parsed = try await task.value
        #expect(parsed.code == "ok")
        #expect(parsed.state == "state-probe")
    }
}
