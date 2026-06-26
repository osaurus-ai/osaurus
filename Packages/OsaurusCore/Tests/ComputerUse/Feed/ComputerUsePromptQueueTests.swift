//
//  ComputerUsePromptQueueTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Audit-remediation coverage for the consent surface (P1 "the Stop that
//  doesn't stop" + the confirm-overlay affordances):
//    • A pending confirm resolves as DENIED when the run is torn down
//      (`cancelAll`) — so the feed's Stop button works even while a card is up.
//    • A pending confirm resolves as DENIED when the awaiting Task is
//      cancelled (`withTaskCancellationHandler`), so the loop never hangs.
//    • "Approve, don't ask again" auto-approves same-or-lower-effect actions in
//      the same app for the rest of the run, while higher-effect actions still
//      prompt.
//    • The just-in-time cloud-vision consent prompt resolves and is
//      teardown-safe.
//
//  Drives `ComputerUsePromptQueue.shared` (a MainActor singleton) with
//  per-test tool-call ids so tests don't interfere.
//

import Foundation
import XCTest

@testable import OsaurusCore

@MainActor
final class ComputerUsePromptQueueTests: XCTestCase {
    private var queue: ComputerUsePromptQueue { .shared }

    private func preview(_ app: String = "Notes", effect: EffectClass = .edit) -> ActionPreview {
        ActionPreview(
            appName: app,
            actionLabel: "Type",
            targetLabel: "Body",
            effect: effect,
            note: nil
        )
    }

    /// Spin the run loop until `predicate` holds (the parked child task has run)
    /// or we time out. Sleeping yields the MainActor so the suspended
    /// `requestConfirmation` task gets a turn to append to `pending`.
    private func waitUntil(
        _ predicate: () -> Bool,
        timeout: TimeInterval = 2.0,
        _ what: String = "condition",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    private func pendingId(forToolCallId id: String) -> UUID? {
        queue.pending.first { $0.toolCallId == id }?.id
    }

    // MARK: Confirm resolution

    func testApproveResolvesTrue() async {
        let id = "approve-\(UUID().uuidString)"
        let task = Task { await self.queue.requestConfirmation(self.preview(), toolCallId: id) }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the prompt to park")
        guard let reqId = pendingId(forToolCallId: id) else { return }
        queue.resolve(id: reqId, approved: true)
        let approved = await task.value
        XCTAssertTrue(approved)
        XCTAssertNil(pendingId(forToolCallId: id))
    }

    func testDeclineResolvesFalse() async {
        let id = "decline-\(UUID().uuidString)"
        let task = Task { await self.queue.requestConfirmation(self.preview(), toolCallId: id) }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the prompt to park")
        guard let reqId = pendingId(forToolCallId: id) else { return }
        queue.resolve(id: reqId, approved: false)
        let approved = await task.value
        XCTAssertFalse(approved)
    }

    // MARK: Stop-during-confirm

    /// The feed's Stop calls `cancelAll(forToolCallId:)`; a confirm that's still
    /// on screen must resolve as DENIED and clear, so the loop unblocks.
    func testCancelAllResolvesPendingConfirmAsDenied() async {
        let id = "stop-\(UUID().uuidString)"
        let task = Task { await self.queue.requestConfirmation(self.preview(), toolCallId: id) }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the prompt to park")
        queue.cancelAll(forToolCallId: id)
        let approved = await task.value
        XCTAssertFalse(approved)
        XCTAssertNil(pendingId(forToolCallId: id))
    }

    /// Structured cancellation of the awaiting Task (the loop's own teardown
    /// path) resolves the suspended call as DENIED via the cancellation handler.
    func testTaskCancellationResolvesConfirmAsDenied() async {
        let id = "cancel-\(UUID().uuidString)"
        let task = Task { await self.queue.requestConfirmation(self.preview(), toolCallId: id) }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the prompt to park")
        task.cancel()
        let approved = await task.value
        XCTAssertFalse(approved)
        await waitUntil({ self.pendingId(forToolCallId: id) == nil }, "the prompt to clear")
    }

    // MARK: Approve-remaining

    func testApproveRemainingAutoApprovesSameOrLowerEffectInApp() async {
        let id = "auto-\(UUID().uuidString)"

        // First edit in Notes → approve the rest.
        let first = Task { await self.queue.requestConfirmation(self.preview(), toolCallId: id) }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the first prompt to park")
        guard let firstId = pendingId(forToolCallId: id) else { return }
        queue.resolveApprovingRest(id: firstId)
        let firstApproved = await first.value
        XCTAssertTrue(firstApproved)

        // A second edit in the same app auto-approves WITHOUT ever parking.
        let secondApproved = await queue.requestConfirmation(preview(), toolCallId: id)
        XCTAssertTrue(secondApproved)
        XCTAssertNil(pendingId(forToolCallId: id))

        // A higher-effect action (consequential) still prompts.
        let third = Task {
            await self.queue.requestConfirmation(
                self.preview("Notes", effect: .consequential),
                toolCallId: id
            )
        }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the consequential prompt to park")
        guard let thirdId = pendingId(forToolCallId: id) else { return }
        queue.resolve(id: thirdId, approved: false)
        let thirdApproved = await third.value
        XCTAssertFalse(thirdApproved)

        // Auto-approve is scoped per app: a different app still prompts.
        let other = Task {
            await self.queue.requestConfirmation(self.preview("Mail"), toolCallId: id)
        }
        await waitUntil({ self.pendingId(forToolCallId: id) != nil }, "the other-app prompt to park")
        queue.cancelAll(forToolCallId: id)
        _ = await other.value
    }

    // MARK: Cloud-vision consent

    func testConsentResolvesToChoice() async {
        let id = "consent-\(UUID().uuidString)"
        let task = Task { await self.queue.requestCloudVisionConsent(toolCallId: id) }
        await waitUntil(
            { self.queue.pendingConsent.contains { $0.toolCallId == id } },
            "the consent prompt to park"
        )
        guard let reqId = queue.pendingConsent.first(where: { $0.toolCallId == id })?.id else { return }
        queue.resolveConsent(id: reqId, choice: .allowOnce)
        let choice = await task.value
        XCTAssertEqual(choice, .allowOnce)
        XCTAssertFalse(queue.pendingConsent.contains { $0.toolCallId == id })
    }

    func testCancelAllResolvesPendingConsentAsDeny() async {
        let id = "consent-stop-\(UUID().uuidString)"
        let task = Task { await self.queue.requestCloudVisionConsent(toolCallId: id) }
        await waitUntil(
            { self.queue.pendingConsent.contains { $0.toolCallId == id } },
            "the consent prompt to park"
        )
        queue.cancelAll(forToolCallId: id)
        let choice = await task.value
        XCTAssertEqual(choice, .deny)
    }
}
