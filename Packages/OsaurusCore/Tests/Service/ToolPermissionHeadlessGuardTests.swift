//
//  ToolPermissionHeadlessGuardTests.swift
//  OsaurusCoreTests
//
//  A modal that nobody can answer is not a slow test — it is a wedged suite.
//
//  Observed 2026-08-22: the whole OsaurusCore suite sat for over 40 minutes
//  with a 0-byte log. It was not slow. `CGWindowListCopyWindowInfo` showed a
//  live `swiftpm-testing-helper` process holding a 460x478 window titled
//  "Tool Permission" at layer 8, and the arguments in it read
//  `"resolved_model": "test-model"` — a test fixture. All three approval entry
//  points block on a `withCheckedContinuation` that only a panel button
//  resumes, so the first test to reach one stops every test behind it.
//
//  The guard it needed already existed: `RuntimeEnvironment.isUnderTests`
//  documents "creates an `NSPanel` without a display server" as precisely its
//  purpose and already matches `swiftpm-testing-helper`. The service just
//  never consulted it. Correct code, never reached — which is why the
//  assertion below is about REACHABILITY, not about the boolean.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("tool permission headless guard")
struct ToolPermissionHeadlessGuardTests {

    /// The precondition. If this ever goes false, every assertion below is
    /// vacuous and the suite can wedge again without any test turning red.
    @Test func testProcessIsDetectedAsUnderTests() {
        #expect(
            RuntimeEnvironment.isUnderTests,
            "the headless guard keys off this; if it is false here the suite can hang on a modal")
    }

    /// The real proof: calling the approval path RETURNS instead of hanging.
    ///
    /// Before the guard this call never came back. A test that completes at
    /// all is therefore the assertion — the returned value is secondary.
    @Test func approvalRequestReturnsInsteadOfPresentingAPanel() async {
        let approved = await ToolPermissionPromptService.requestApproval(
            toolName: "image",
            description: "Create or edit an image with the user's configured image model.",
            argumentsJSON: #"{"backend":"Local","resolved_model":"test-model"}"#
        )

        // Denial is the deterministic headless answer, and it matches the
        // registry's existing "external-surface / headless denials" semantics.
        #expect(!approved)
    }

    @Test func approvalOutcomeIsDeniedHeadless() async {
        let outcome = await ToolPermissionPromptService.requestApprovalOutcome(
            toolName: "image",
            description: "d",
            argumentsJSON: "{}"
        )
        #expect(outcome == .denied)
    }

    @Test func policyApprovalIsDeniedHeadless() async {
        let outcome = await ToolPermissionPromptService.requestPolicyApproval(
            toolName: "spawn_agent",
            description: "d",
            argumentsJSON: "{}"
        )
        #expect(outcome == .denied)
    }

    /// The policy path with a revalidate hook is what spawn uses. Headless it
    /// must deny before the hook runs — nothing may enqueue.
    @Test func policyApprovalWithRevalidateIsDeniedHeadlessWithoutRunningTheHook() async {
        let hookRan = LockedFlag()
        let outcome = await ToolPermissionPromptService.requestPolicyApproval(
            toolName: "spawn_agent",
            description: "d",
            argumentsJSON: #"{"resolved_model":"test-model"}"#,
            revalidate: {
                hookRan.set()
                return nil
            }
        )
        #expect(outcome == .denied)
        // The hook only runs from inside the queue's pump, so an unrun hook
        // proves nothing was enqueued. (The global queue depth is shared with
        // the queue suite's presenter stand-in and is not asserted here.)
        #expect(!hookRan.value, "headless denial must not enqueue or revalidate")
    }

    /// No panel may be left behind. A window that outlives the call is the
    /// thing Eric could not click or quit.
    @Test func noPermissionPanelSurvivesTheCall() async {
        _ = await ToolPermissionPromptService.requestApproval(
            toolName: "image", description: "d", argumentsJSON: "{}")

        let stillOpen = await MainActor.run {
            ToolPermissionPromptService.hasOpenPermissionWindowForTesting
        }
        #expect(!stillOpen, "an approval call left a panel on screen")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
