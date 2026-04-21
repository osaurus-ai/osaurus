//
//  HostAPIPluginCreateTests.swift
//  osaurusTests
//
//  Covers the public surface that `POST /api/plugin/create` relies on
//  in `HostAPIBridgeServer.handlePlugin`: HTTP status mapping for each
//  registration failure kind, and that the shared registration pipeline
//  is what actually performs validation / persistence (not a parallel
//  drift-prone implementation).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
@MainActor
struct HostAPIPluginCreateTests {

    // MARK: - HTTP status mapping

    @Test
    func errorMapsToHttpStatusCodes() {
        #expect(SandboxPluginRegistrationError.invalidArgs("x").httpStatusCode == 400)
        #expect(SandboxPluginRegistrationError.unavailable("x").httpStatusCode == 503)
        #expect(SandboxPluginRegistrationError.rateLimited("x").httpStatusCode == 429)
        #expect(
            SandboxPluginRegistrationError
                .executionError("x", retryable: false).httpStatusCode == 500
        )
    }

    @Test
    func errorRetryableDefaultsMatchEnvelopeContract() {
        #expect(SandboxPluginRegistrationError.invalidArgs("x").retryable == false)
        #expect(SandboxPluginRegistrationError.unavailable("x").retryable == true)
        #expect(SandboxPluginRegistrationError.rateLimited("x").retryable == true)
        #expect(
            SandboxPluginRegistrationError
                .executionError("x", retryable: true).retryable == true
        )
        #expect(
            SandboxPluginRegistrationError
                .executionError("x", retryable: false).retryable == false
        )
    }

    // MARK: - Source metadata mapping

    @Test
    func sourceMetadataValueAlwaysIdentifiesAsAgent() {
        // Both call sites stamp `created_by = "agent"`. The `source` enum
        // carries the call-site for `created_via` but must never demote the
        // ownership label — the library UI uses `created_by` to decide
        // whether to surface "agent-created" badges.
        #expect(SandboxPluginRegistrationSource.agentTool.metadataValue == "agent")
        #expect(SandboxPluginRegistrationSource.hostBridge.metadataValue == "agent")
    }

    // MARK: - End-to-end gates that the HTTP path inherits

    /// The HTTP endpoint refuses to register before the gates pass: when
    /// the sandbox isn't running the registration pipeline raises
    /// `.unavailable`, which maps to HTTP 503. Without this guarantee the
    /// previous "fire-and-forget Task" version would have returned 200
    /// with `installing` and lost the failure entirely.
    @Test
    func registerSurfacesUnavailableWhenContainerNotRunning() async {
        let plugin = SandboxPlugin(
            name: "Status Probe Plugin",
            description: "Used to verify the unavailable gate"
        )
        // Tests run with no real container — `SandboxManager.shared.status()`
        // returns `.notProvisioned`/`.stopped`, both of which fail the
        // `isRunning` guard inside `register`. Validation passes (no setup,
        // no tools, no secrets) so the only remaining gate is the sandbox
        // check we want to exercise.
        do {
            _ = try await SandboxPluginRegistration.register(
                plugin: plugin,
                agentId: UUID().uuidString,
                source: .hostBridge,
                skipRateLimit: true
            )
            Issue.record("expected .unavailable error")
        } catch let error as SandboxPluginRegistrationError {
            guard case .unavailable = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
            #expect(error.httpStatusCode == 503)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
