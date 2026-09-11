// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Tool permission prompt presentation")
struct ToolPermissionPromptServiceTests {
    @Test("run-scoped approval expires outside the task-local lease")
    func runScopedApprovalExpires() {
        let first = ToolPermissionRunScope()
        ChatExecutionContext.$toolPermissionRunScope.withValue(first) {
            #expect(ChatExecutionContext.toolPermissionRunScope?.allows("shell_run") == false)
            ChatExecutionContext.toolPermissionRunScope?.allow("shell_run")
            #expect(ChatExecutionContext.toolPermissionRunScope?.allows("shell_run") == true)
        }
        #expect(ChatExecutionContext.toolPermissionRunScope == nil)
        #expect(ToolPermissionRunScope().allows("shell_run") == false)
    }

    @Test("a task cancelled before approval is denial-shaped")
    @MainActor
    func cancelledApprovalDoesNotOpenOrGrantALease() async {
        let task = Task { @MainActor in
            await ToolPermissionPromptService.requestApprovalOutcome(
                toolName: "shell_run",
                description: "Run a command",
                argumentsJSON: #"{"command":"true"}"#
            )
        }
        task.cancel()
        #expect(await task.value == .denied)
        #expect(ChatExecutionContext.toolPermissionRunScope == nil)
    }

    @Test("launching app window wins over mouse and fallback displays")
    func launchingWindowScreenHasPriority() {
        #expect(
            ToolPermissionPromptService.preferredPresentationCandidate(
                keyWindow: "key",
                mainWindow: "main",
                mouse: "mouse",
                fallback: "fallback"
            ) == "key"
        )
        #expect(
            ToolPermissionPromptService.preferredPresentationCandidate(
                keyWindow: Optional<String>.none,
                mainWindow: "main",
                mouse: "mouse",
                fallback: "fallback"
            ) == "main"
        )
        #expect(
            ToolPermissionPromptService.preferredPresentationCandidate(
                keyWindow: Optional<String>.none,
                mainWindow: Optional<String>.none,
                mouse: "mouse",
                fallback: "fallback"
            ) == "mouse"
        )
    }

    @Test("Return and Escape require the visible focused prompt in the active app")
    func keyboardShortcutRequiresFocusedPrompt() {
        #expect(
            ToolPermissionPromptService.shouldAcceptKeyboardShortcut(
                isVisible: true,
                isKeyWindow: true,
                isAppActive: true
            )
        )

        for state in [
            (false, true, true),
            (true, false, true),
            (true, true, false),
            (false, false, false),
        ] {
            #expect(
                !ToolPermissionPromptService.shouldAcceptKeyboardShortcut(
                    isVisible: state.0,
                    isKeyWindow: state.1,
                    isAppActive: state.2
                )
            )
        }
    }

    @Test("panel never sizes past the visible screen area")
    func windowSizeClampsToVisibleFrame() {
        let visible = NSSize(width: 1440, height: 875)

        let oversized = ToolPermissionPromptService.clampedWindowSize(
            NSSize(width: 744, height: 2114),
            to: visible
        )
        #expect(oversized == NSSize(width: 744, height: 875))

        let fitting = ToolPermissionPromptService.clampedWindowSize(
            NSSize(width: 480, height: 620),
            to: visible
        )
        #expect(fitting == NSSize(width: 480, height: 620))
    }

    @Test("production prompt has one app-local keyboard monitor")
    func promptDoesNotListenToOtherApps() throws {
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent(
            "Services/ToolPermissionPromptService.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("addGlobalMonitorForEvents"))
        #expect(source.contains("styleMask: [.titled, .fullSizeContentView]"))
        #expect(source.contains("isKeyWindow: weakPanel?.isKeyWindow == true"))
        #expect(source.contains("keyWindow: NSApp.keyWindow?.screen"))
        // Per-request ownership: no shared window slot, no dead spawn picker.
        #expect(!source.contains("static var permissionWindow"))
        #expect(!source.contains("requestSpawnApproval"))
        #expect(source.contains("private static var queue: [PendingPrompt]"))
    }

}

// MARK: - Queue semantics (test presenter, no AppKit panel)

/// Records what the coordinator presents. Requests are issued inside a
/// `presentationOverrideForTests` binding, so the process never constructs a
/// panel and the headless guard is lifted for exactly these requests.
private final class PromptPresenterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(id: UUID, toolName: String, queuedBehind: Int)] = []

    var presented: [(id: UUID, toolName: String, queuedBehind: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var presenter: ToolPermissionPromptService.TestPresenter {
        { [self] id, name, behind in
            lock.lock()
            entries.append((id, name, behind))
            lock.unlock()
        }
    }

    /// Yield until the coordinator has presented `count` cards.
    func waitForPresented(_ count: Int) async {
        for _ in 0 ..< 400 where presented.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Suite("Tool permission prompt queue", .serialized)
struct ToolPermissionPromptQueueTests {
    private typealias Outcome = ToolPermissionPromptService.PolicyApprovalOutcome

    /// One queued policy request, issued under the probe's presenter.
    @MainActor
    private func request(
        _ probe: PromptPresenterProbe,
        _ description: String,
        revalidate: (@Sendable () async -> Outcome?)? = nil
    ) -> Task<Outcome, Never> {
        ToolPermissionPromptService.$presentationOverrideForTests.withValue(probe.presenter) {
            Task { @MainActor in
                await ToolPermissionPromptService.requestPolicyApproval(
                    toolName: "spawn_agent",
                    description: description,
                    argumentsJSON: "{\"d\":\"\(description)\"}",
                    revalidate: revalidate
                )
            }
        }
    }

    @Test("two concurrent requests present one card at a time and each resolves its own request")
    @MainActor
    func concurrentRequestsAreSerialisedAndIndependentlyResolved() async {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let probe = PromptPresenterProbe()

        let first = request(probe, "A")
        let second = request(probe, "B")

        await probe.waitForPresented(1)
        // Let the second request enqueue behind the first.
        for _ in 0 ..< 100 where ToolPermissionPromptService.queuedPromptCountForTesting < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(probe.presented.count == 1, "the second card must wait for the first")
        #expect(ToolPermissionPromptService.queuedPromptCountForTesting == 1)
        #expect(ToolPermissionPromptService.presentedPromptIDForTesting != nil)

        ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .alwaysAllow)
        #expect(await first.value == .alwaysAllow)

        await probe.waitForPresented(2)
        #expect(probe.presented.count == 2, "resolving the first presents the second")
        #expect(probe.presented[1].id != probe.presented[0].id)
        #expect(probe.presented[1].queuedBehind == 0)

        ToolPermissionPromptService.resolveForTesting(id: probe.presented[1].id, outcome: .denied)
        #expect(await second.value == .denied)
        #expect(ToolPermissionPromptService.presentedPromptIDForTesting == nil)
        #expect(ToolPermissionPromptService.queuedPromptCountForTesting == 0)
    }

    @Test("the presented card reports how many requests wait behind it")
    @MainActor
    func presentedCardReportsQueueDepth() async {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let probe = PromptPresenterProbe()

        // Enqueue B and C first without presenting by holding the slot with A.
        let a = request(probe, "A")
        await probe.waitForPresented(1)
        let b = request(probe, "B")
        let c = request(probe, "C")
        for _ in 0 ..< 100 where ToolPermissionPromptService.queuedPromptCountForTesting < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(ToolPermissionPromptService.queuedPromptCountForTesting == 2)

        ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .allowOnce)
        _ = await a.value
        await probe.waitForPresented(2)
        #expect(probe.presented[1].queuedBehind == 1, "B is presented with C behind it")

        ToolPermissionPromptService.resolveForTesting(id: probe.presented[1].id, outcome: .allowOnce)
        _ = await b.value
        await probe.waitForPresented(3)
        #expect(probe.presented[2].queuedBehind == 0)
        ToolPermissionPromptService.resolveForTesting(id: probe.presented[2].id, outcome: .allowOnce)
        _ = await c.value
    }

    @Test("resolving a stale id is a no-op for the presented card")
    @MainActor
    func staleResolutionDoesNotTouchThePresentedCard() async {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let probe = PromptPresenterProbe()

        let task = request(probe, "A")
        await probe.waitForPresented(1)
        ToolPermissionPromptService.resolveForTesting(id: UUID(), outcome: .alwaysAllow)
        #expect(ToolPermissionPromptService.presentedPromptIDForTesting != nil)
        #expect(ToolPermissionPromptService.presentedPromptIDForTesting == probe.presented[0].id)

        ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .allowOnce)
        #expect(await task.value == .allowOnce)
    }

    @Test("cancelling a queued request resolves it denied without disturbing the presented card")
    @MainActor
    func cancellingQueuedRequestLeavesPresentedCardAlone() async {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let probe = PromptPresenterProbe()

        let presentedTask = request(probe, "A")
        await probe.waitForPresented(1)
        let queuedTask = request(probe, "B")
        for _ in 0 ..< 100 where ToolPermissionPromptService.queuedPromptCountForTesting < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(ToolPermissionPromptService.queuedPromptCountForTesting == 1)

        queuedTask.cancel()
        #expect(await queuedTask.value == .denied)
        for _ in 0 ..< 100 where ToolPermissionPromptService.queuedPromptCountForTesting > 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(ToolPermissionPromptService.queuedPromptCountForTesting == 0)
        #expect(probe.presented.count == 1)
        #expect(ToolPermissionPromptService.presentedPromptIDForTesting == probe.presented[0].id)

        ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .allowOnce)
        #expect(await presentedTask.value == .allowOnce)
    }

    @Test("cancelling the presented request dismisses it and presents the next")
    @MainActor
    func cancellingPresentedRequestPromotesTheNext() async {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let probe = PromptPresenterProbe()

        let presentedTask = request(probe, "A")
        await probe.waitForPresented(1)
        let queuedTask = request(probe, "B")
        for _ in 0 ..< 100 where ToolPermissionPromptService.queuedPromptCountForTesting < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        presentedTask.cancel()
        #expect(await presentedTask.value == .denied)
        await probe.waitForPresented(2)
        #expect(probe.presented.count == 2)
        #expect(ToolPermissionPromptService.presentedPromptIDForTesting == probe.presented[1].id)

        ToolPermissionPromptService.resolveForTesting(id: probe.presented[1].id, outcome: .allowOnce)
        #expect(await queuedTask.value == .allowOnce)
    }

    @Test("a queued request whose revalidate hook settles it never presents a card")
    @MainActor
    func revalidateSettlesQueuedRequestSilently() async {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let probe = PromptPresenterProbe()

        let first = request(probe, "A")
        await probe.waitForPresented(1)
        let second = request(probe, "B", revalidate: { .allowOnce })
        for _ in 0 ..< 100 where ToolPermissionPromptService.queuedPromptCountForTesting < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .alwaysAllow)
        #expect(await first.value == .alwaysAllow)
        #expect(await second.value == .allowOnce)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(probe.presented.count == 1, "the revalidated sibling must not show a second card")
        #expect(ToolPermissionPromptService.presentedPromptIDForTesting == nil)
    }

    @Test("a revalidate hook that returns nil still presents the card")
    @MainActor
    func revalidateNilPresentsTheCard() async {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let probe = PromptPresenterProbe()

        let task = request(probe, "A", revalidate: { nil })
        await probe.waitForPresented(1)
        #expect(probe.presented.count == 1)
        ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .denied)
        #expect(await task.value == .denied)
    }

    @Test("cancelling a request while its revalidate hook runs resolves it denied and releases the slot")
    @MainActor
    func cancellingDuringRevalidateReleasesTheSlot() async {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let probe = PromptPresenterProbe()

        let slow = request(
            probe, "A",
            revalidate: {
                try? await Task.sleep(for: .milliseconds(150))
                return nil
            }
        )
        try? await Task.sleep(for: .milliseconds(30))
        #expect(probe.presented.isEmpty, "still revalidating")
        slow.cancel()
        #expect(await slow.value == .denied)

        // The slot is free: the next request presents immediately.
        let next = request(probe, "B")
        await probe.waitForPresented(1)
        #expect(probe.presented.count == 1)
        #expect(probe.presented[0].toolName == "spawn_agent")
        ToolPermissionPromptService.resolveForTesting(id: probe.presented[0].id, outcome: .allowOnce)
        #expect(await next.value == .allowOnce)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(probe.presented.count == 1, "the cancelled request must never present after its hook returns")
    }
}
