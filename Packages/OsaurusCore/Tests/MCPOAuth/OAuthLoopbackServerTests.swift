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
    @Test func ephemeralPortBoundAfterStart() async throws {
        let server = try OAuthLoopbackServer(
            expectedState: "state-abc",
            port: .ephemeral,
            callbackPath: "/callback"
        )
        try server.start()
        defer { server.stop() }

        // NWListener reports its port asynchronously after `start()`. Spin briefly.
        var port: UInt16?
        for _ in 0 ..< 20 {
            if let bound = server.boundPort, bound != 0 {
                port = bound
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let resolved = try #require(port)
        #expect(resolved > 1024)
    }

    @Test func successCallbackResolvesAwaiter() async throws {
        let server = try OAuthLoopbackServer(
            expectedState: "expected-state",
            port: .ephemeral,
            callbackPath: "/callback"
        )
        try server.start()
        defer { server.stop() }

        // Wait for the listener to be ready before connecting.
        var port: UInt16?
        for _ in 0 ..< 40 {
            if let bound = server.boundPort, bound != 0 {
                port = bound
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let resolved = try #require(port)

        let task = Task { try await server.waitForCallback() }

        // Hit the loopback URL after a small delay so the server is actually listening.
        try await Task.sleep(nanoseconds: 100_000_000)
        let callbackURL = URL(
            string: "http://127.0.0.1:\(resolved)/callback?state=expected-state&code=auth-code"
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
        try server.start()
        defer { server.stop() }

        var port: UInt16?
        for _ in 0 ..< 40 {
            if let bound = server.boundPort, bound != 0 {
                port = bound
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let resolved = try #require(port)

        let task = Task { try await server.waitForCallback() }

        try await Task.sleep(nanoseconds: 100_000_000)
        let badURL = URL(
            string: "http://127.0.0.1:\(resolved)/callback?state=tampered&code=x"
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
