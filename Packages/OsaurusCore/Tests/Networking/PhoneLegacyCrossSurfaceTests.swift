//
//  PhoneLegacyCrossSurfaceTests.swift
//  OsaurusCoreTests
//
//  For one release a run from the 6-digit-paired iPhone parks its cards
//  where both that iPhone (over HTTP) and the owner's other devices (Sync's
//  attention feed, the Mac) can answer them. Every card is one
//  `AttentionCenter` item, so the first answer wins on every surface and a
//  later one finds nothing pending.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0 ..< 400 where !predicate() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func syncAnswer(_ id: UUID, action: String) {
    var applied: Set<String> = []
    SyncAttentionFeed.apply(
        [
            .init(
                id: id.uuidString,
                answer: .init(action: action, answeredMs: SyncHostedRunContract.nowMs()),
                deviceLabel: "iPhone"
            )
        ],
        applied: &applied
    )
}

@MainActor
private func surface(of id: UUID) -> AttentionSurface? {
    if case .resolved(let resolution)? = AttentionCenter.shared.item(id: id)?.state { return resolution.surface }
    return nil
}

@Suite("Paired-phone cards settle across surfaces", .serialized)
@MainActor
struct PhoneLegacyCrossSurfaceTests {
    private func preview() -> ActionPreview {
        ActionPreview(appName: "Notes", actionLabel: "Type", targetLabel: "Body", effect: .edit, note: nil)
    }

    private func parkComputerUse(_ toolCallId: String) async -> (Task<Bool, Never>, UUID?) {
        let queue = ComputerUsePromptQueue.shared
        let preview = preview()
        let task = ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
            Task { @MainActor in await queue.requestConfirmation(preview, toolCallId: toolCallId) }
        }
        await waitUntil { queue.pending.contains { $0.toolCallId == toolCallId } }
        return (task, queue.pending.first { $0.toolCallId == toolCallId }?.id)
    }

    @Test func computerUseAnsweredOverHTTPSettlesTheSyncItem() async throws {
        let queue = ComputerUsePromptQueue.shared
        let (task, parked) = await parkComputerUse("cu-http-\(UUID().uuidString)")
        let id = try #require(parked)
        #expect(String(decoding: queue.pairedPhoneListJSON(), as: UTF8.self).contains(id.uuidString))

        #expect(queue.resolveFromPairedPhone(id: id, decision: "approve") == .answered)
        #expect(await task.value)
        #expect(surface(of: id) == .phone)

        syncAnswer(id, action: "deny")
        #expect(queue.resolveFromPairedPhone(id: id, decision: "deny") == .notPending)
    }

    @Test func computerUseAnsweredOverSyncLeavesNothingForHTTP() async throws {
        let queue = ComputerUsePromptQueue.shared
        let (task, parked) = await parkComputerUse("cu-sync-\(UUID().uuidString)")
        let id = try #require(parked)

        syncAnswer(id, action: "deny")
        #expect(await task.value == false)
        #expect(queue.resolveFromPairedPhone(id: id, decision: "approve") == .notPending)
        #expect(!String(decoding: queue.pairedPhoneListJSON(), as: UTF8.self).contains(id.uuidString))
    }

    @Test func aTypoIsRefusedAndTheCardStaysUp() async throws {
        let queue = ComputerUsePromptQueue.shared
        let (task, parked) = await parkComputerUse("cu-typo-\(UUID().uuidString)")
        let id = try #require(parked)

        #expect(queue.resolveFromPairedPhone(id: id, decision: "allow") == .invalidDecision)
        #expect(AttentionCenter.shared.item(id: id)?.isPending == true)
        #expect(queue.resolveFromPairedPhone(id: id, decision: "deny") == .answered)
        #expect(await task.value == false)
    }

    @Test func secretSentOverHTTPSettlesTheItem() async throws {
        let queue = RemoteSecretPromptQueue.shared
        let key = "KEY_\(UUID().uuidString.prefix(6))"
        let task = Task { @MainActor in await queue.request(key: key, description: "d", instructions: "i") }
        await waitUntil { queue.pending.contains { $0.key == key } }
        let id = try #require(queue.pending.first { $0.key == key }?.id)

        #expect(queue.resolve(id: id, value: "s3cret"))
        #expect(await task.value == "s3cret")
        #expect(surface(of: id) == .phone)
        #expect(!queue.resolve(id: id, value: "again"))
    }

    @Test func secretDismissedOnTheMacCancelsTheHTTPPrompt() async throws {
        let queue = RemoteSecretPromptQueue.shared
        let key = "KEY_\(UUID().uuidString.prefix(6))"
        let task = Task { @MainActor in await queue.request(key: key, description: "d", instructions: "i") }
        await waitUntil { queue.pending.contains { $0.key == key } }
        let id = try #require(queue.pending.first { $0.key == key }?.id)

        AttentionCenter.shared.resolve(id: id, with: AttentionResolution(outcome: .dismissed, surface: .desktop))
        #expect(await task.value == nil)
        #expect(!queue.resolve(id: id, value: "late"))
        #expect(!String(decoding: queue.listJSON(), as: UTF8.self).contains(id.uuidString))
    }
}

// These drive the process-wide tool prompt queue, so they join its
// serialized suite rather than running concurrently against it.
extension ToolPermissionPromptQueueTests {
    @MainActor
    private func parkPhoneApproval() async -> (Task<ToolPermissionPromptService.ApprovalOutcome, Never>, UUID?) {
        let presenter: ToolPermissionPromptService.TestPresenter = { _, _, _ in }
        let task = ToolPermissionPromptService.$presentationOverrideForTests.withValue(presenter) {
            ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                Task { @MainActor in
                    await ToolPermissionPromptService.requestApprovalOutcome(
                        toolName: "web_fetch", description: "Fetch", argumentsJSON: #"{"url":"https://example.com"}"#)
                }
            }
        }
        await waitUntil { !ToolPermissionPromptService.remotePrompts.isEmpty }
        return (task, ToolPermissionPromptService.remotePrompts.first?.id)
    }

    @Test("a paired-phone approval answered over HTTP settles the Sync item")
    @MainActor
    func phoneApprovalOverHTTP() async throws {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let (task, parked) = await parkPhoneApproval()
        let id = try #require(parked)
        let decision = try #require(HTTPHandler.promptResolution(for: "allow_once"))

        #expect(ToolPermissionPromptService.resolveRemotely(id: id, outcome: decision))
        #expect(await task.value == .allowOnce)
        #expect(surface(of: id) == .phone)
        #expect(!ToolPermissionPromptService.resolveRemotely(id: id, outcome: .denied))
    }

    @Test("a paired-phone approval answered over Sync leaves nothing for HTTP")
    @MainActor
    func phoneApprovalOverSync() async throws {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let (task, parked) = await parkPhoneApproval()
        let id = try #require(parked)

        syncAnswer(id, action: "deny")
        #expect(await task.value == .denied)
        #expect(!ToolPermissionPromptService.resolveRemotely(id: id, outcome: .allowOnce))
        #expect(ToolPermissionPromptService.remotePrompts.isEmpty)
    }
}
