//
//  SandboxDiagnosticHintTests.swift
//  OsaurusCoreTests
//
//  Covers `SandboxManager.sandboxDiagnosticHint`, the pure mapping that turns
//  a terse failed `exec` result into the actionable, human-readable string the
//  Diagnostics panel shows. The function is side-effect free (a `static`
//  member sits outside the actor's isolation domain), so these run without a
//  guest VM. We assert on the explanatory prefix plus that the raw exit
//  code / stderr is preserved for power users.
//

#if os(macOS)

    import Foundation
    import Testing

    @testable import OsaurusCore

    @Suite("Sandbox Diagnostic Hints")
    struct SandboxDiagnosticHintTests {

        // MARK: - vsock-bridge classification

        @Test
        func vsockBridge_authRejection_isClassifiedAsAuthFailure() {
            // The bridge fails closed with HTTP 401; the shim surfaces it as
            // `osaurus-host: error 401: <body>` and exits 1.
            let hint = SandboxManager.sandboxDiagnosticHint(
                check: "vsock-bridge",
                exitCode: 1,
                stderr: "osaurus-host: error 401: Bridge token missing or unrecognised"
            )
            #expect(hint.contains("authentication failed"))
            // Raw signal preserved so power users still see the underlying error.
            #expect(hint.contains("exit 1"))
            #expect(hint.contains("Bridge token missing or unrecognised"))
        }

        @Test
        func vsockBridge_localTokenMissing_isClassifiedAsNotProvisioned() {
            // The shim's own pre-flight check when the token file is absent —
            // distinct from a 401 returned by the bridge.
            let hint = SandboxManager.sandboxDiagnosticHint(
                check: "vsock-bridge",
                exitCode: 1,
                stderr: "osaurus-host: bridge token for agent-diag missing (host has not provisioned this agent yet)"
            )
            #expect(hint.contains("token not provisioned"))
            #expect(!hint.contains("authentication failed"))
        }

        @Test
        func vsockBridge_connectionRefused_isClassifiedAsUnreachable() {
            let hint = SandboxManager.sandboxDiagnosticHint(
                check: "vsock-bridge",
                exitCode: 7,
                stderr: "curl: (7) Failed to connect to localhost port 80: Connection refused"
            )
            #expect(hint.contains("socket unreachable"))
        }

        @Test
        func vsockBridge_shimMissing_isClassifiedAsMissingShim() {
            let hint = SandboxManager.sandboxDiagnosticHint(
                check: "vsock-bridge",
                exitCode: 127,
                stderr: "/bin/sh: osaurus-host: not found"
            )
            #expect(hint.contains("shim missing"))
        }

        @Test
        func vsockBridge_unknownFailure_fallsBackToGenericButKeepsStderr() {
            let hint = SandboxManager.sandboxDiagnosticHint(
                check: "vsock-bridge",
                exitCode: 1,
                stderr: "osaurus-host: error 500: Inference failed"
            )
            #expect(hint.contains("round-trip failed"))
            #expect(hint.contains("error 500"))
        }

        // MARK: - network-dependent checks

        @Test
        func natNetworking_pointsAtNetworkAccessSetting() {
            let hint = SandboxManager.sandboxDiagnosticHint(
                check: "nat-networking",
                exitCode: 0,
                stderr: ""
            )
            #expect(hint.contains("Network Access"))
            // A clean exit with no stderr should not tack on a noisy suffix.
            #expect(!hint.contains("exit"))
            #expect(!hint.contains("("))
        }

        @Test
        func apkInstall_pointsAtNetworkAccessSettingAndKeepsStderr() {
            let hint = SandboxManager.sandboxDiagnosticHint(
                check: "apk-install",
                exitCode: 1,
                stderr: "ERROR: unable to select packages"
            )
            #expect(hint.contains("Network Access"))
            #expect(hint.contains("exit 1"))
            #expect(hint.contains("unable to select packages"))
        }

        // MARK: - decoration

        @Test
        func decoration_omitsExitCodeWhenZeroAndStderrEmpty() {
            let hint = SandboxManager.sandboxDiagnosticHint(
                check: "vsock-bridge",
                exitCode: 0,
                stderr: ""
            )
            #expect(!hint.contains("exit"))
            #expect(!hint.contains("("))
        }
    }

#endif
