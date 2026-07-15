//
//  ComputerUseLoopRunTests.swift
//  OsaurusCoreTests — Computer Use
//
//  End-to-end `ComputerUseLoop.run` coverage WITHOUT a live model, using the
//  injectable `AgentStepProvider` seam + `MockMacDriver`. These pin the loop's
//  control flow — the termination + recovery policy the production run depends
//  on — deterministically:
//   • terminal verbs (done / give_up),
//   • the max-steps cap,
//   • the consecutive-invalid re-ask budget (malformed shape AND no tool call),
//   • reobserve → dead-end,
//   • cancellation via `InterruptToken`,
//   • gate confirm-decline (action is NOT executed), and
//   • a provider recovering from a rejection using the transcript feedback.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ComputerUseLoopRunTests: XCTestCase {

    // MARK: - Fixtures

    private func el(_ id: String, _ role: String, _ label: String?, value: String? = nil) -> CUElement {
        CUElement(id: id, role: role, label: label, value: value)
    }

    /// A driver with one focused app (so `currentPid` is non-nil from the
    /// start) serving a single steady-state snapshot.
    private func driver(
        _ elements: [CUElement],
        pid: Int32 = 4242,
        app: String = "Demo"
    ) -> MockMacDriver {
        let snap = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: app,
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)],
            elements: elements,
            image: nil
        )
        return MockMacDriver(
            activeWindow: CUActiveWindow(pid: pid, app: app, title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: [snap]]
        )
    }

    private func run(
        _ driver: MockMacDriver,
        provider: @escaping AgentStepProvider,
        gate: ComputerUseGating = HardwiredGate(),
        confirm: @escaping @Sendable (ActionPreview) async -> Bool = { _ in true },
        interrupt: InterruptToken = InterruptToken(),
        limits: RunLimits = RunLimits(wallClockSeconds: 30),
        feed: SubagentFeed? = nil
    ) async -> ComputerUseRunResult {
        let activityFeed = feed ?? SubagentFeed(toolCallId: "t", kindId: "computer_use", title: "test goal")
        return await ComputerUseLoop.run(
            goal: "test goal",
            modelId: "test-model",
            driver: driver,
            gate: gate,
            feed: activityFeed,
            interrupt: interrupt,
            confirm: confirm,
            limits: limits,
            sessionId: "cu-test",
            nextAction: provider
        )
    }

    // MARK: - Terminal verbs

    func testClickThenDoneSucceeds() async {
        let d = driver([el("go", "button", "Go")])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "click go"),
                AgentAction(verb: .done, reason: "all done"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess, "Expected done; got \(result.outcome)")
        let clicks = await d.elementActions
        XCTAssertEqual(clicks.count, 1, "The click should have been executed exactly once")
        XCTAssertGreaterThanOrEqual(result.metrics.actsAttempted, 1)
    }

    func testGiveUpTerminatesWithReason() async {
        let d = driver([el("go", "button", "Go")])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([AgentAction(verb: .giveUp, reason: "cannot")])
        )
        guard case .gaveUp(let reason) = result.outcome else {
            return XCTFail("Expected gaveUp; got \(result.outcome)")
        }
        XCTAssertEqual(reason, "cannot")
    }

    // MARK: - Browser submission boundary

    func testAutonomousBrowserSubmitStillRequiresExactOneShotApproval() async {
        let d = driver([el("submit", "button", "Submit request")], app: "Safari")
        let recorder = ActionPreviewRecorder()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                AgentAction(verb: .done, reason: "submitted"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return true
            }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let previews = await recorder.values
        XCTAssertEqual(previews.count, 1)
        guard case .oneShot(let binding) = previews.first?.approvalScope else {
            return XCTFail("Submit approval must be exact and one-shot")
        }
        XCTAssertEqual(binding.snapshotId, 1)
        XCTAssertEqual(binding.appName, "Safari")
        XCTAssertEqual(binding.verb, .click)
        XCTAssertEqual(binding.targetLabel, "button \"Submit request\"")
        XCTAssertNotNil(binding.targetFingerprint)
        XCTAssertFalse(previews[0].allowsApproveRemaining)
        XCTAssertEqual(result.formEvidence.submissionState, .acted)
        let actions = await d.elementActions
        XCTAssertEqual(actions.count, 1)
    }

    func testDeclinedBrowserSubmitStopsReadyForReviewWithoutDriverAction() async {
        let d = driver([el("submit", "button", "Submit request")], app: "Safari")
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                AgentAction(verb: .done, reason: "must not reach"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in false }
        )

        guard case .done(let summary) = result.outcome else {
            return XCTFail("Declining submit should stop at a reviewable success state")
        }
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("unsubmitted"))
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
        let actions = await d.elementActions
        XCTAssertTrue(actions.isEmpty)
    }

    func testPlainReturnInBrowserRequiresOneShotApproval() async {
        let focused = CUElement(
            id: "email",
            role: "textfield",
            label: "Email",
            focused: true
        )
        let d = driver([focused], app: "Google Chrome")
        let recorder = ActionPreviewRecorder()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .pressKey, key: "Return"),
                AgentAction(verb: .done, reason: "submitted"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return true
            }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let previews = await recorder.values
        XCTAssertEqual(previews.count, 1)
        XCTAssertFalse(previews[0].allowsApproveRemaining)
        let actions = await d.elementActions
        XCTAssertEqual(actions.count, 1)
    }

    func testTypedNewlineInBrowserRequiresOneShotApproval() async {
        let field = CUElement(
            id: "notes",
            role: "textfield",
            label: "Notes",
            focused: true
        )
        let d = driver([field], app: "Safari")
        let recorder = ActionPreviewRecorder()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .type,
                    target: AgentTarget(mark: 1),
                    text: "First line\nSecond line"
                ),
                AgentAction(verb: .done, reason: "typed"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return false
            }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let previews = await recorder.values
        XCTAssertEqual(previews.count, 1)
        XCTAssertFalse(previews[0].allowsApproveRemaining)
        let actions = await d.elementActions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
    }

    func testSecureFieldValueIsNotExposedInSubmissionBinding() {
        let secret = "correct horse battery staple"
        let secureField = CUElement(
            id: "password",
            role: "AXSecureTextField",
            value: secret,
            focused: true
        )
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: 4242,
            app: "Safari",
            focusedWindow: "Sign in",
            tier: .ax,
            truncated: false,
            windows: [],
            elements: [secureField],
            image: nil
        )

        let binding = SubmissionBoundary.binding(
            action: AgentAction(verb: .pressKey, key: "Return"),
            element: secureField,
            snapshot: snapshot,
            appName: "Safari",
            effect: .consequential
        )

        XCTAssertNotNil(binding)
        XCTAssertFalse(binding?.targetLabel?.contains(secret) ?? false)
        XCTAssertEqual(binding?.targetLabel, "AXSecureTextField")
        let changedSecret = CUElement(
            id: "password",
            role: "AXSecureTextField",
            value: "different secret",
            focused: true
        )
        let changedSnapshot = CUSnapshot(
            snapshotId: 2,
            pid: 4242,
            app: "Safari",
            focusedWindow: "Sign in",
            tier: .ax,
            truncated: false,
            windows: [],
            elements: [changedSecret],
            image: nil
        )
        XCTAssertNil(
            binding.flatMap {
                SubmissionBoundary.revalidatedElement(
                    for: $0,
                    action: AgentAction(verb: .pressKey, key: "Return"),
                    snapshot: changedSnapshot
                )
            }
        )
    }

    func testSpaceOnFocusedSubmitButtonRequiresOneShotApproval() async {
        let focusedSubmit = CUElement(
            id: "submit",
            role: "button",
            label: "Submit request",
            focused: true
        )
        let d = driver([focusedSubmit], app: "Safari")
        let recorder = ActionPreviewRecorder()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .pressKey, key: "space"),
                AgentAction(verb: .done, reason: "submitted"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return true
            }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let previews = await recorder.values
        XCTAssertEqual(previews.count, 1)
        XCTAssertFalse(previews[0].allowsApproveRemaining)
        let actions = await d.elementActions
        XCTAssertEqual(actions.count, 1)
    }

    func testSpaceInFocusedBrowserTextFieldDoesNotBecomeSubmission() async {
        let field = CUElement(id: "notes", role: "textfield", label: "Notes", focused: true)
        let d = driver([field], app: "Safari")
        let recorder = ActionPreviewRecorder()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .pressKey, key: "space"),
                AgentAction(verb: .done, reason: "inserted a space"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return true
            }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let previews = await recorder.values
        let actions = await d.elementActions
        XCTAssertTrue(previews.isEmpty)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(result.formEvidence.submissionState, .notEncountered)
    }

    func testGenericContinueControlRequiresSubmissionApproval() async {
        let control = CUElement(id: "continue", role: "group", label: "Continue")
        let d = driver([control], app: "Safari")
        let recorder = ActionPreviewRecorder()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                AgentAction(verb: .done, reason: "must not reach"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return false
            }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let previews = await recorder.values
        let actions = await d.elementActions
        XCTAssertEqual(previews.count, 1)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
    }

    func testOrdinaryBrowserButtonDoesNotBecomeSubmissionBoundary() async {
        let control = CUElement(id: "cancel", role: "button", label: "Cancel")
        let d = driver([control], app: "Safari")
        let recorder = ActionPreviewRecorder()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                AgentAction(verb: .done, reason: "cancelled"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return false
            }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let previews = await recorder.values
        let actions = await d.elementActions
        XCTAssertTrue(previews.isEmpty)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(result.formEvidence.submissionState, .notEncountered)
    }

    func testMixedSubmitAndDismissalLabelStillRequiresApproval() async {
        let control = CUElement(id: "save-close", role: "button", label: "Save and close")
        let d = driver([control], app: "Safari")
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in false }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let actions = await d.elementActions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
    }

    func testSecureTypedTextNeverAppearsInActivityFeed() async {
        let canary = "activity-feed-secret-canary"
        let field = CUElement(
            id: "password",
            role: "AXSecureTextField",
            label: "Password",
            focused: true
        )
        let d = driver([field], app: "Safari")
        let feed = SubagentFeed(toolCallId: "secure", kindId: "computer_use", title: "secure input")
        _ = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .type, target: AgentTarget(mark: 1), text: canary),
                AgentAction(verb: .done, reason: "entered"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            feed: feed
        )

        let rendered = feed.currentEvents()
            .flatMap { [$0.title, $0.detail ?? ""] }
            .joined(separator: "\n")
        XCTAssertFalse(rendered.contains(canary))
    }

    func testModelAuthoredNoteNeverAppearsInActivityFeed() async {
        let canary = "note-secret-canary"
        let d = driver([el("go", "button", "Go")])
        let feed = SubagentFeed(toolCallId: "note", kindId: "computer_use", title: "note redaction")
        _ = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: canary),
                AgentAction(verb: .done, reason: "complete"),
            ]),
            feed: feed
        )

        let rendered = feed.currentEvents()
            .flatMap { [$0.title, $0.detail ?? ""] }
            .joined(separator: "\n")
        XCTAssertFalse(rendered.contains(canary))
    }

    func testBrowserSubmissionNoteNeverAppearsInActivityFeed() async {
        let canary = "submission-note-secret-canary"
        let d = driver([el("submit", "button", "Submit request")], app: "Safari")
        let feed = SubagentFeed(toolCallId: "submit-note", kindId: "computer_use", title: "submit")
        _ = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .click,
                    target: AgentTarget(mark: 1),
                    note: canary
                ),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in false },
            feed: feed
        )

        let rendered = feed.currentEvents()
            .flatMap { [$0.title, $0.detail ?? ""] }
            .joined(separator: "\n")
        XCTAssertFalse(rendered.contains(canary))
    }

    func testTypedNewlineSubmissionValueNeverAppearsInActivityFeedOrBindingLabel() async {
        let canary = "typed-value-secret-canary\n"
        let field = CUElement(
            id: "message",
            role: "AXTextField",
            label: "Message",
            focused: true
        )
        let d = driver([field], app: "Safari")
        let feed = SubagentFeed(toolCallId: "typed-submit", kindId: "computer_use", title: "submit")
        let recorder = ActionPreviewRecorder()
        _ = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .type, target: AgentTarget(mark: 1), text: canary),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return false
            },
            feed: feed
        )

        let rendered = feed.currentEvents()
            .flatMap { [$0.title, $0.detail ?? ""] }
            .joined(separator: "\n")
        XCTAssertFalse(rendered.contains(canary.trimmingCharacters(in: .newlines)))
        let previews = await recorder.values
        XCTAssertEqual(previews.first?.actionLabel, "Enter text")
        guard case .oneShot(let binding) = previews.first?.approvalScope else {
            return XCTFail("Typed newline submission must remain one-shot")
        }
        XCTAssertEqual(binding.actionLabel, "Enter text")
        XCTAssertFalse(binding.actionLabel.contains(canary.trimmingCharacters(in: .newlines)))
    }

    func testAutonomousBrowserCommitControlsRequireOneShotApproval() async {
        for (role, label) in [
            ("button", "Buy now"),
            ("button", "OK"),
            ("button", "Save"),
            ("button", "Done"),
            ("button", "Subscribe"),
            ("button", "Get started"),
            ("button", "Login"),
            ("button", "Go"),
            ("button", "Search"),
            ("button", "Signup"),
            ("button", "送信"),
            ("AXButton", nil),
        ] as [(String, String?)] {
            let d = driver([el("commit", role, label)], app: "Safari")
            let recorder = ActionPreviewRecorder()
            let result = await run(
                d,
                provider: ComputerUseLoop.scriptedProvider([
                    AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                    AgentAction(verb: .done, reason: "must not reach"),
                ]),
                gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
                confirm: { preview in
                    await recorder.record(preview)
                    return false
                }
            )

            XCTAssertTrue(result.outcome.isSuccess, "Expected review stop for \(label ?? "icon-only control")")
            let previews = await recorder.values
            let actions = await d.elementActions
            XCTAssertEqual(previews.count, 1)
            XCTAssertTrue(actions.isEmpty)
            XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
        }
    }

    func testSetValueNewlineInBrowserRequiresOneShotApproval() async {
        let d = driver([el("notes", "textfield", "Notes")], app: "Safari")
        let recorder = ActionPreviewRecorder()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .setValue, target: AgentTarget(mark: 1), text: "First line\nSecond line"),
                AgentAction(verb: .done, reason: "must not reach"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return false
            }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let previews = await recorder.values
        let actions = await d.elementActions
        XCTAssertEqual(previews.count, 1)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
    }

    func testApprovedNewlineEditDoesNotClaimSubmission() async {
        let d = driver([el("notes", "textarea", "Notes")], app: "Safari")
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .setValue, target: AgentTarget(mark: 1), text: "First line\nSecond line"),
                AgentAction(verb: .done, reason: "submitted"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in true }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(result.formEvidence.submissionState, .actionExecutedUnverified)
        let mapped = try? ComputerUseKind.mapOutcome(result, model: "test-model")
        XCTAssertEqual(mapped?.payload["submission_performed"] as? Bool, false)
        XCTAssertEqual(mapped?.payload["submission_verified"] as? Bool, false)
        XCTAssertEqual(mapped?.payload["submission_may_have_occurred"] as? Bool, true)
        XCTAssertTrue(mapped?.summary?.localizedCaseInsensitiveContains("may have submitted") == true)
    }

    func testGenericRoleSubmitSignalRequiresOneShotApproval() async {
        let control = CUElement(id: "custom-submit", role: "AXGroup", label: "Submit request")
        let d = driver([control], app: "Safari")
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in false }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let actions = await d.elementActions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
    }

    func testLocalizedLinkInsideFormRequiresOneShotApproval() async {
        let control = CUElement(
            id: "localized-submit",
            role: "link",
            label: "Enviar",
            path: "AXWebArea/form/actions"
        )
        let d = driver([control], app: "Safari")
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in false }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let actions = await d.elementActions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
    }

    func testLocalizedRoleDescriptionButtonRequiresOneShotApproval() async {
        let control = CUElement(
            id: "localized-submit",
            role: "AXGroup",
            roleDescription: "button",
            label: "Enviar"
        )
        let d = driver([control], app: "Safari")
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in false }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let actions = await d.elementActions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
    }

    func testInterruptAfterApprovedActionPreservesSubmissionEvidence() async throws {
        let d = driver([el("submit", "button", "Submit request")], app: "Safari")
        let token = InterruptToken()
        await d.setAfterNextAction { token.interrupt() }
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in true },
            interrupt: token
        )

        XCTAssertEqual(result.outcome, .interrupted)
        XCTAssertEqual(result.formEvidence.submissionState, .acted)
        do {
            _ = try ComputerUseKind.mapOutcome(result, model: "test-model")
            XCTFail("Interrupted run should map to a structured failure")
        } catch let error as SubagentError {
            let data = try XCTUnwrap(error.envelope(tool: "subagent").data(using: .utf8))
            let envelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(envelope["kind"] as? String, "user_denied")
            XCTAssertEqual(envelope["retryable"] as? Bool, false)
            XCTAssertEqual(envelope["submission_state"] as? String, "acted")
            XCTAssertEqual(envelope["submission_performed"] as? Bool, true)
            XCTAssertEqual(envelope["submission_may_have_occurred"] as? Bool, false)
        }
    }

    func testFailureAfterApprovedActionPreservesSubmissionEvidence() async throws {
        let d = driver([el("submit", "button", "Submit request")], app: "Safari")
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                AgentAction(verb: .giveUp, reason: "verification unavailable"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in true }
        )

        XCTAssertEqual(result.formEvidence.submissionState, .acted)
        do {
            _ = try ComputerUseKind.mapOutcome(result, model: "test-model")
            XCTFail("Failed run should map to a structured failure")
        } catch let error as SubagentError {
            let data = try XCTUnwrap(error.envelope(tool: "subagent").data(using: .utf8))
            let envelope = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(envelope["kind"] as? String, "execution_error")
            XCTAssertEqual(envelope["retryable"] as? Bool, false)
            XCTAssertEqual(envelope["submission_state"] as? String, "acted")
            XCTAssertEqual(envelope["submission_performed"] as? Bool, true)
        }
    }

    func testSecureNewlinePreviewOmitsTypedSecret() async {
        let secret = "correct horse\nbattery staple"
        let secure = CUElement(
            id: "password",
            role: "AXSecureTextField",
            label: "Password",
            focused: true
        )
        let d = driver([secure], app: "Safari")
        let recorder = ActionPreviewRecorder()
        _ = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .type, target: AgentTarget(mark: 1), text: secret),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return false
            }
        )

        let previews = await recorder.values
        XCTAssertEqual(previews.count, 1)
        XCTAssertNil(previews.first?.typedText)
        XCTAssertFalse(previews.first?.summary.contains(secret) ?? false)
    }

    func testSecureEditConfirmationOmitsTypedSecretAndModelNote() async {
        let secret = "ordinary-secure-edit-canary"
        let secure = CUElement(
            id: "password",
            role: "AXSecureTextField",
            label: "Password",
            focused: true
        )
        let recorder = ActionPreviewRecorder()
        _ = await run(
            driver([secure], app: "Safari"),
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .type,
                    target: AgentTarget(mark: 1),
                    text: secret,
                    note: "Use \(secret)"
                ),
            ]),
            gate: HardwiredGate(),
            confirm: { preview in
                await recorder.record(preview)
                return false
            }
        )

        let preview = await recorder.values.first
        XCTAssertNil(preview?.typedText)
        XCTAssertNil(preview?.note)
        XCTAssertFalse(preview?.summary.contains(secret) ?? false)
        XCTAssertEqual(preview?.actionLabel, "Enter protected text")
    }

    func testKeyboardSubmissionRestoresApprovedTargetFocus() async {
        let pid: Int32 = 4242
        func snapshot(_ id: Int, focused: Bool) -> CUSnapshot {
            CUSnapshot(
                snapshotId: id,
                pid: pid,
                app: "Safari",
                focusedWindow: "Request",
                tier: .ax,
                truncated: false,
                windows: [],
                elements: [
                    CUElement(
                        id: "submit",
                        role: "button",
                        label: "Submit request",
                        focused: focused
                    )
                ],
                image: nil
            )
        }
        let d = MockMacDriver(
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Request",
                x: 0,
                y: 0,
                w: 800,
                h: 600
            ),
            snapshots: [pid: [snapshot(1, focused: true), snapshot(2, focused: false)]]
        )
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .pressKey, key: "space"),
                AgentAction(verb: .done, reason: "submitted"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in true }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let actions = await d.elementActions
        XCTAssertEqual(actions.count, 2)
        guard case .focus(let id) = actions[0] else {
            return XCTFail("Expected the approved target to be focused before the key press")
        }
        XCTAssertEqual(id, "submit")
        guard case .pressKey = actions[1] else {
            return XCTFail("Expected the approved key press after focus restoration")
        }
    }

    func testMappedReadyForReviewOutcomeReportsNoSubmission() throws {
        var evidence = ComputerUseFormEvidence()
        evidence.preparationState = .readyForReview
        evidence.submissionState = .readyForReview
        let runResult = ComputerUseRunResult(
            outcome: .done(summary: "The form is ready for review."),
            metrics: ComputerUseRunMetrics(),
            formEvidence: evidence
        )

        let mapped = try ComputerUseKind.mapOutcome(runResult, model: "test-model")

        XCTAssertEqual(mapped.payload["form_preparation_state"] as? String, "ready_for_review")
        XCTAssertEqual(mapped.payload["submission_state"] as? String, "ready_for_review")
        XCTAssertEqual(mapped.payload["submission_performed"] as? Bool, false)
        XCTAssertEqual(mapped.payload["submission_verified"] as? Bool, false)
    }

    func testInterruptDuringSubmitApprovalPreventsPostCancelAction() async {
        let d = driver([el("submit", "button", "Submit request")], app: "Safari")
        let token = InterruptToken()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1))
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in
                token.interrupt()
                return true
            },
            interrupt: token
        )

        XCTAssertEqual(result.outcome, .interrupted)
        let actions = await d.elementActions
        XCTAssertTrue(actions.isEmpty)
    }

    func testChangedFormExpiresApprovalBeforeDriverAction() async {
        let pid: Int32 = 4242
        func snapshot(_ id: Int, submitLabel: String) -> CUSnapshot {
            CUSnapshot(
                snapshotId: id,
                pid: pid,
                app: "Safari",
                focusedWindow: "Request",
                tier: .ax,
                truncated: false,
                windows: [],
                elements: [el("submit-\(id)", "button", submitLabel)],
                image: nil
            )
        }
        let d = MockMacDriver(
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Request",
                x: 0,
                y: 0,
                w: 800,
                h: 600
            ),
            snapshots: [pid: [snapshot(1, submitLabel: "Submit request"), snapshot(2, submitLabel: "Pay now")]]
        )
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                AgentAction(verb: .done, reason: "stopped after refresh"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in true }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
        let actions = await d.elementActions
        XCTAssertTrue(actions.isEmpty)
    }

    func testTargetlessReturnCanExecuteAfterExactSnapshotApproval() async {
        let field = CUElement(id: "email", role: "textfield", label: "Email", focused: false)
        let d = driver([field], app: "Safari")
        let recorder = ActionPreviewRecorder()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .pressKey, key: "Return"),
                AgentAction(verb: .done, reason: "submitted"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return true
            }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let previews = await recorder.values
        let actions = await d.elementActions
        XCTAssertEqual(previews.count, 1)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(result.formEvidence.submissionState, .acted)
    }

    func testLocalizedUnknownSubmitLabelStopsWhenFormInputsArePresent() async {
        let field = CUElement(id: "name", role: "textfield", label: "姓名")
        let submit = CUElement(id: "submit", role: "button", label: "提交")
        let d = driver([field, submit], app: "Safari")
        let recorder = ActionPreviewRecorder()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(describe: "提交")),
                AgentAction(verb: .done, reason: "must not submit"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { preview in
                await recorder.record(preview)
                return false
            }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let previews = await recorder.values
        let actions = await d.elementActions
        XCTAssertEqual(previews.count, 1)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
    }

    func testUnrelatedDynamicPageValueDoesNotExpireExactApproval() async {
        let pid: Int32 = 4242
        func snapshot(_ id: Int, clock: String) -> CUSnapshot {
            CUSnapshot(
                snapshotId: id,
                pid: pid,
                app: "Safari",
                focusedWindow: "Checkout",
                tier: .ax,
                truncated: false,
                windows: [],
                elements: [
                    CUElement(id: "name-\(id)", role: "textfield", label: "Name", value: "Ada"),
                    CUElement(id: "submit-\(id)", role: "button", label: "Submit"),
                    CUElement(id: "clock-\(id)", role: "statictext", label: "Clock", value: clock),
                ],
                image: nil
            )
        }
        let d = MockMacDriver(
            activeWindow: CUActiveWindow(
                pid: pid,
                app: "Safari",
                title: "Checkout",
                x: 0,
                y: 0,
                w: 800,
                h: 600
            ),
            snapshots: [
                pid: [
                    snapshot(1, clock: "10:00"),
                    snapshot(2, clock: "10:01"),
                    snapshot(3, clock: "10:02"),
                ],
            ]
        )
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(describe: "Submit")),
                AgentAction(verb: .done, reason: "submitted"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in true }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let actions = await d.elementActions
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(result.formEvidence.submissionState, .acted)
    }

    func testApprovedStaleTargetNeverFallsBackToBlindCoordinates() async {
        let submit = CUElement(
            id: "submit",
            role: "button",
            label: "Submit",
            x: 100,
            y: 100,
            w: 100,
            h: 40
        )
        let d = driver([submit], app: "Safari")
        await d.enqueueActionResults([
            CUActionResult(success: false, error: "stale", stale: true),
        ])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1)),
                AgentAction(verb: .done, reason: "stopped safely"),
            ]),
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            confirm: { _ in true }
        )

        XCTAssertTrue(result.outcome.isSuccess)
        let coordinateActions = await d.coordinateActions
        let elementActions = await d.elementActions
        XCTAssertTrue(coordinateActions.isEmpty)
        XCTAssertEqual(elementActions.count, 1)
        XCTAssertEqual(result.formEvidence.submissionState, .readyForReview)
    }

    // MARK: - Step cap

    func testMaxStepsCapReached() async {
        let d = driver([el("go", "button", "Go")])
        // `observe` never terminates; the scripted cursor repeats it.
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([AgentAction(verb: .observe)]),
            limits: RunLimits(maxSteps: 3, wallClockSeconds: 30)
        )
        guard case .stepCapReached = result.outcome else {
            return XCTFail("Expected stepCapReached; got \(result.outcome)")
        }
        XCTAssertEqual(result.metrics.steps, 3)
    }

    // MARK: - Re-ask budget

    func testConsecutiveInvalidShapesGiveUp() async {
        let d = driver([el("go", "button", "Go")])
        let bad: AgentStepProvider = { _ in ModelActionCall(id: "x", arguments: "{not valid json") }
        let result = await run(
            d,
            provider: bad,
            limits: RunLimits(maxConsecutiveInvalid: 2, wallClockSeconds: 30)
        )
        guard case .gaveUp(let reason) = result.outcome else {
            return XCTFail("Expected gaveUp; got \(result.outcome)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("valid action"))
    }

    func testNoToolCallGivesUp() async {
        let d = driver([el("go", "button", "Go")])
        let none: AgentStepProvider = { _ in nil }
        let result = await run(
            d,
            provider: none,
            limits: RunLimits(maxConsecutiveInvalid: 2, wallClockSeconds: 30)
        )
        guard case .gaveUp = result.outcome else {
            return XCTFail("Expected gaveUp; got \(result.outcome)")
        }
    }

    // MARK: - Reobserve → dead-end

    func testUnresolvableTargetDeadEnds() async {
        let d = driver([el("go", "button", "Go")])  // mark 1 exists; mark 99 doesn't
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 99), note: "miss")
            ]),
            limits: RunLimits(
                maxSteps: 10,
                maxConsecutiveReobserve: 1,
                maxConsecutiveDeadEnd: 1,
                wallClockSeconds: 30
            )
        )
        guard case .deadEnd = result.outcome else {
            return XCTFail("Expected deadEnd; got \(result.outcome)")
        }
        let clicks = await d.elementActions
        XCTAssertTrue(clicks.isEmpty, "An unresolved target must never reach the driver")
    }

    // MARK: - Cancellation

    func testInterruptTerminatesAsInterrupted() async {
        let d = driver([el("go", "button", "Go")])
        let token = InterruptToken()
        token.interrupt()
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([AgentAction(verb: .observe)]),
            interrupt: token
        )
        guard case .interrupted = result.outcome else {
            return XCTFail("Expected interrupted; got \(result.outcome)")
        }
    }

    // MARK: - Gate decline

    func testDeclinedActionIsNotExecuted() async {
        let d = driver([el("field", "textfield", "Note", value: "")])
        // `type` is an edit → HardwiredGate confirms it → confirm returns false.
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .type, text: "hello", note: "fill note"),
                AgentAction(verb: .giveUp, reason: "declined"),
            ]),
            confirm: { _ in false }
        )
        guard case .gaveUp = result.outcome else {
            return XCTFail("Expected gaveUp; got \(result.outcome)")
        }
        XCTAssertEqual(result.metrics.confirmsRequested, 1)
        XCTAssertEqual(result.metrics.confirmsDeclined, 1)
        let edits = await d.elementActions
        XCTAssertTrue(edits.isEmpty, "A declined action must not be sent to the driver")
    }

    // MARK: - Recovery via transcript feedback

    func testProviderRecoversFromRejectionUsingToolResult() async {
        let d = driver([el("go", "button", "Go")])
        // First step: an invalid click (no target). Second step: the provider
        // sees the "rejected" tool result and recovers with `done`.
        let provider: AgentStepProvider = { input in
            if input.lastToolResult?.localizedCaseInsensitiveContains("rejected") ?? false {
                return ModelActionCall(
                    id: "recover",
                    arguments: AgentAction(verb: .done, reason: "recovered").argumentsJSON()
                )
            }
            return ModelActionCall(id: "bad", arguments: AgentAction(verb: .click).argumentsJSON())
        }
        let result = await run(
            d,
            provider: provider,
            limits: RunLimits(maxConsecutiveInvalid: 3, wallClockSeconds: 30)
        )
        XCTAssertTrue(result.outcome.isSuccess, "Provider should recover to done; got \(result.outcome)")
    }

    // MARK: - New verbs (Phase 2)

    func testWaitReperceivesThenContinues() async {
        let d = driver([el("go", "button", "Go")])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                // seconds:0 keeps the test instant; the verb still re-perceives.
                AgentAction(verb: .wait, seconds: 0, note: "let it settle"),
                AgentAction(verb: .done, reason: "ok"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess, "wait then done should succeed; got \(result.outcome)")
        let captures = await d.captureCount
        XCTAssertGreaterThanOrEqual(captures, 2, "wait must re-perceive the app after pausing")
    }

    func testDragResolvesBothEndpointsAndDrives() async {
        // marks 1 (card) and 2 (trash).
        let d = driver([el("card", "cell", "Card"), el("trash", "button", "Trash")])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(
                    verb: .drag,
                    target: AgentTarget(mark: 1),
                    to: AgentTarget(mark: 2),
                    note: "card to trash"
                ),
                AgentAction(verb: .done, reason: "moved"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess, "drag then done should succeed; got \(result.outcome)")
        let coords = await d.coordinateActions
        XCTAssertEqual(coords.count, 1, "drag should issue exactly one coordinate drag")
        guard case .drag = coords.first else {
            return XCTFail("Expected a coordinate drag; got \(coords)")
        }
    }

    func testFindRoutesToDriverAndNarrowsToActionableMatches() async {
        // Three elements; find "Send" should narrow to the one Send button via
        // the driver's server-side query, and that match must stay clickable.
        let d = driver([
            el("go", "button", "Go"),
            el("send", "button", "Send"),
            el("note", "textfield", "Note", value: ""),
        ])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .find, query: "Send", note: "locate send"),
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "click the only match"),
                AgentAction(verb: .done, reason: "sent"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess, "find→click→done should succeed; got \(result.outcome)")
        let clicks = await d.elementActions
        XCTAssertEqual(clicks.count, 1, "Exactly the matched element should be clicked")
        guard case let .click(id, _, _) = clicks.first else {
            return XCTFail("Expected an element click; got \(clicks)")
        }
        XCTAssertEqual(id, "send", "The narrowed mark 1 must resolve to the Send button from the find result")
    }

    func testFindWithNoMatchesFallsBackToFullView() async {
        let d = driver([el("go", "button", "Go")])
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .find, query: "Nonexistent", note: "miss"),
                AgentAction(verb: .done, reason: "gave up finding"),
            ])
        )
        XCTAssertTrue(result.outcome.isSuccess)
    }

    func testDragWithUnresolvableDestinationDoesNotDrive() async {
        let d = driver([el("card", "cell", "Card")])  // only mark 1; destination mark 9 is missing
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .drag, target: AgentTarget(mark: 1), to: AgentTarget(mark: 9), note: "miss"),
                AgentAction(verb: .giveUp, reason: "no destination"),
            ]),
            limits: RunLimits(maxSteps: 10, wallClockSeconds: 30)
        )
        guard case .gaveUp = result.outcome else {
            return XCTFail("Expected gaveUp; got \(result.outcome)")
        }
        let coords = await d.coordinateActions
        XCTAssertTrue(coords.isEmpty, "An unresolved drag destination must never reach the driver")
    }

    // MARK: - Loop robustness (Phase 3)

    func testModelStepTimeoutFailsWhenInferenceHangs() async {
        let d = driver([el("go", "button", "Go")])
        // A provider that never returns within the per-step budget.
        let hang: AgentStepProvider = { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return ModelActionCall(id: "late", arguments: AgentAction(verb: .observe).argumentsJSON())
        }
        let result = await run(
            d,
            provider: hang,
            limits: RunLimits(
                wallClockSeconds: 30,
                modelStepTimeoutSeconds: 0.1,
                maxInferenceRetries: 0
            )
        )
        guard case .failed(let reason) = result.outcome else {
            return XCTFail("Expected failed on timeout; got \(result.outcome)")
        }
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("timed out"),
            "Expected a timeout reason; got: \(reason)"
        )
    }

    func testInferenceRetrySucceedsAfterTransientThrows() async {
        let d = driver([el("go", "button", "Go")])
        let counter = AttemptCounter()
        // Throw on the first two attempts, then return `done`.
        let flaky: AgentStepProvider = { _ in
            let n = await counter.bump()
            if n < 3 { throw TestInferenceError() }
            return ModelActionCall(id: "ok", arguments: AgentAction(verb: .done, reason: "recovered").argumentsJSON())
        }
        let result = await run(
            d,
            provider: flaky,
            limits: RunLimits(wallClockSeconds: 30, modelStepTimeoutSeconds: 0, maxInferenceRetries: 2)
        )
        XCTAssertTrue(result.outcome.isSuccess, "Retries should recover; got \(result.outcome)")
        let attempts = await counter.value
        XCTAssertEqual(attempts, 3, "Two retries after the initial attempt = three tries total")
    }

    func testInferenceFailsAfterExhaustingRetries() async {
        let d = driver([el("go", "button", "Go")])
        let counter = AttemptCounter()
        let always: AgentStepProvider = { _ in
            _ = await counter.bump()
            throw TestInferenceError()
        }
        let result = await run(
            d,
            provider: always,
            limits: RunLimits(wallClockSeconds: 30, modelStepTimeoutSeconds: 0, maxInferenceRetries: 2)
        )
        guard case .failed = result.outcome else {
            return XCTFail("Expected failed after exhausting retries; got \(result.outcome)")
        }
        let attempts = await counter.value
        XCTAssertEqual(attempts, 3, "Initial try + two retries before failing")
    }

    func testRepeatedActionStallDeadEnds() async {
        let d = driver([el("go", "button", "Go")])
        // The model keeps clicking the same (resolvable) button forever.
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "click go")
            ]),
            limits: RunLimits(maxSteps: 20, wallClockSeconds: 30, maxRepeatedActions: 3)
        )
        guard case .deadEnd(let reason) = result.outcome else {
            return XCTFail("Expected a stall dead-end; got \(result.outcome)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("repeated"), "got: \(reason)")
        let clicks = await d.elementActions
        XCTAssertEqual(clicks.count, 2, "Two clicks land before the third identical proposal stalls")
    }

    func testRepeatedScrollDoesNotStall() async {
        let d = driver([el("go", "button", "Go")])
        // Scroll is exempt (paging a list is real progress), so a repeated
        // scroll should ride out to the step cap rather than stall-dead-end.
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([
                AgentAction(verb: .scroll, direction: .down, note: "page down")
            ]),
            limits: RunLimits(maxSteps: 5, wallClockSeconds: 30, maxRepeatedActions: 3)
        )
        guard case .stepCapReached = result.outcome else {
            return XCTFail("Repeated scroll should not stall; got \(result.outcome)")
        }
    }

    // MARK: - Empty-AX escalation

    /// A driver that serves an empty AX snapshot first, then a populated one —
    /// the Electron / custom-drawn-UI shape the empty-AX escalation targets.
    private func emptyThenPopulated(screenRecording: Bool, pid: Int32 = 4242) -> MockMacDriver {
        let window = CUWindowSummary(id: 1, title: "Main", focused: true, x: 0, y: 0, w: 800, h: 600)
        let empty = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Electron",
            focusedWindow: "Main",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: [],
            image: nil
        )
        let populated = CUSnapshot(
            snapshotId: 2,
            pid: pid,
            app: "Electron",
            focusedWindow: "Main",
            tier: .som,
            truncated: false,
            windows: [window],
            elements: [el("send", "button", "Send")],
            image: CUImage(base64: "", mimeType: "image/png", width: 1, height: 1)
        )
        return MockMacDriver(
            availability: MacDriverAvailability(
                accessibility: true,
                screenRecording: screenRecording,
                skyLight: true
            ),
            activeWindow: CUActiveWindow(pid: pid, app: "Electron", title: "Main", x: 0, y: 0, w: 800, h: 600),
            snapshots: [pid: [empty, populated]]
        )
    }

    func testEmptyAXEscalatesToSomWhenPixelsAvailable() async {
        let d = emptyThenPopulated(screenRecording: true)
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([AgentAction(verb: .done, reason: "ok")])
        )
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(
            result.metrics.maxTier,
            .som,
            "An empty AX view with Screen Recording should escalate ax→som"
        )
    }

    func testEmptyAXStaysAtAxWithoutScreenRecording() async {
        let d = emptyThenPopulated(screenRecording: false)
        let result = await run(
            d,
            provider: ComputerUseLoop.scriptedProvider([AgentAction(verb: .done, reason: "ok")])
        )
        XCTAssertEqual(
            result.metrics.maxTier,
            .ax,
            "No Screen Recording means there is no tier to escalate an empty view to"
        )
    }
}

// MARK: - Robustness test support

/// Thread-safe attempt counter for the inference-retry tests (the provider is
/// `@Sendable` and may be invoked across hops).
private actor AttemptCounter {
    private(set) var value = 0
    func bump() -> Int {
        value += 1
        return value
    }
}

private struct TestInferenceError: Error {}

private actor ActionPreviewRecorder {
    private(set) var values: [ActionPreview] = []

    func record(_ preview: ActionPreview) {
        values.append(preview)
    }
}
