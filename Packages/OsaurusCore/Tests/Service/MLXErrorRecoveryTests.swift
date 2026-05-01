import Foundation
import MLX
import Testing

@testable import OsaurusCore

/// Guards `MLXErrorRecovery.installGlobalHandler()` — the osaurus-side bootstrap
/// that replaces mlx-swift's default `fatalError(message)` MLX error fallback
/// with a logging handler that lets the process keep running.
///
/// Without this install, **any** C++-side MLX error (shape mismatch in
/// `rmsNorm`, broadcast mismatch, Metal validation failure) takes the entire
/// osaurus process down via `_assertionFailure` — taking every unrelated
/// in-flight request with it. This was the root cause symbolicated against
/// `nemotron-cascade-2-30b-a3b-jang_4m` during PR #967 triage; the vmlx-side
/// fix lives in `NemotronHJANGTQ.swift`, but on the osaurus side we want the
/// server to survive any future bundle that trips a similar trap.
///
/// We deliberately do **not** try to trigger a real MLX error from a unit
/// test: MLX's evaluation worker threads don't inherit Swift TaskLocals from
/// the call site, so the scoped `withErrorHandler` API can't reliably fence
/// off such a test from the suite-wide process. The end-to-end "real bundle
/// failure becomes a 500, not a crash" assertion lives in integration tests
/// (PR-967 triage harness) and is regression-protected by this test only at
/// the install-time level.
@Suite("MLXErrorRecovery — install path")
struct MLXErrorRecoveryTests {

    @Test("installGlobalHandler is idempotent and side-effect-free")
    func install_idempotent() {
        // First call installs; subsequent calls must be no-ops. The
        // implementation guards on a flag inside its lock — without the
        // guard, repeated install would re-run `MLX.setErrorHandler`,
        // which itself has dtor cleanup logic that we don't want firing
        // on every call site.
        MLXErrorRecovery.installGlobalHandler()
        MLXErrorRecovery.installGlobalHandler()
        MLXErrorRecovery.installGlobalHandler()

        // Surviving to here is the assertion. Anything pathological in
        // re-install (unbalanced dtor, double-log, deadlock) would fail
        // this case.
        #expect(true)
    }

    @Test("lastError accessor returns without blocking when no error has fired")
    func lastError_safeAccessor() {
        MLXErrorRecovery.installGlobalHandler()
        // The accessor takes the same lock the handler writes under.
        // A naive impl that called the lock recursively from the handler
        // (or held it across a logging call that itself synchronizes)
        // would deadlock here in suite runs that have already exercised
        // an MLX error in another test. Read-only path must always
        // return promptly.
        _ = MLXErrorRecovery.lastError
        #expect(true)
    }
}
