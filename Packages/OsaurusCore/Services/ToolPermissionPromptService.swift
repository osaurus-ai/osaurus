//
//  ToolPermissionPromptService.swift
//  osaurus
//
//  Presents a modern confirmation dialog when a tool requires user approval.
//
//  One coordinator, one panel at a time. Every approval request becomes a
//  queued entry with its own identity and continuation; exactly one entry is
//  presented, and resolving it (button, keyboard, close, cancellation) tears
//  down exactly its own panel and presents the next entry. Concurrent callers
//  — parallel tool calls whose bodies prompt (`spawn_agent`, image/video
//  billing, the config fallback) or a delegated child prompting while the
//  parent does — therefore never overwrite each other's window.
//
//  History: the previous implementation kept a single static window slot. Two
//  concurrent `spawn_agent` prompts overwrote it; the first panel stayed on
//  screen with dead button handlers after the second resolved, and its Stop
//  cancellation hook was lost, so its continuation could never be resumed.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
enum ToolPermissionPromptService {
    // MARK: - Public outcome vocabularies (unchanged for callers)

    enum PolicyApprovalOutcome: Sendable, Equatable {
        case denied
        case allowOnce
        case alwaysAllow
    }

    enum ApprovalOutcome: Sendable, Equatable {
        case denied
        case allowOnce
        case allowForRun
        case alwaysAllow
    }

    /// Internal resolution shared by every entry point. Public entry points
    /// map it onto their own narrower vocabulary.
    enum PromptResolution: Sendable, Equatable {
        case denied
        case allowOnce
        case allowForRun
        case alwaysAllow
    }

    /// Re-evaluated immediately before an entry is presented. A non-nil value
    /// resolves the entry without showing a panel — e.g. a sibling spawn
    /// prompt already persisted "Always Allow" while this one was queued.
    typealias Revalidation = @Sendable () async -> PromptResolution?

    // MARK: - Queue state

    struct PromptRequest {
        let toolName: String
        let description: String
        let argumentsJSON: String
        let knowledgeWritePreview: KnowledgeWritePreview?
        let perCallApprovalOnly: Bool
        /// Whether the card offers "Allow for This Task". Only the generic
        /// registry prompt has a run lease to grant into.
        let offersRunLease: Bool
    }

    private struct PendingPrompt {
        let id: UUID
        let request: PromptRequest
        let revalidate: Revalidation?
        /// Captured from the requesting task so a test presenter follows its
        /// own requests through the queue regardless of which task pumps.
        let presenter: TestPresenter?
    }

    /// AppKit handles owned by the presented entry. Nil under the test
    /// presenter override, which never constructs a window.
    private struct PanelHandles {
        let panel: NSPanel
        let closeObserver: NSObjectProtocol
        let keyMonitor: Any?
    }

    private enum PresenterSlot {
        /// The head entry is running its `revalidate` hook. The slot is held
        /// so no other entry can present in the meantime.
        case revalidating(UUID)
        case presented(UUID, PanelHandles?)

        var id: UUID {
            switch self {
            case .revalidating(let id), .presented(let id, _): return id
            }
        }
    }

    private static var queue: [PendingPrompt] = []
    private static var continuations: [UUID: CheckedContinuation<PromptResolution, Never>] = [:]
    private static var slot: PresenterSlot?
    /// Card size reported by `onGeometryChange` during the sizing layout
    /// pass, applied once the panel is registered.
    private static var lastRenderedCardSize: CGSize?

    // MARK: - Headless / test seams

    /// A test process has nobody to press the button.
    ///
    /// Every approval entry point blocks on a `withCheckedContinuation` that
    /// is only ever resumed by a panel button, so a test that reaches one
    /// hangs — and because the bundle runs in a single process, every test
    /// behind it hangs too. Observed 2026-08-22: the whole OsaurusCore suite
    /// sat for 40+ minutes with a 0-byte log while a live
    /// `swiftpm-testing-helper` held a 460x478 "Tool Permission" panel on
    /// screen. Denying is the deterministic answer and matches the registry's
    /// "external-surface / headless denials" semantics.
    ///
    /// Tests that exercise the queue itself bind `presentationOverrideForTests`
    /// around their requests, which replaces the AppKit panel with a callback
    /// and lifts this guard for exactly those requests.
    private static var isHeadlessTestProcess: Bool {
        RuntimeEnvironment.isUnderTests && presentationOverrideForTests == nil
    }

    /// Replaces panel construction. Receives the presented entry's id, tool
    /// name, and how many entries are queued behind it; the test resolves the
    /// entry with `resolveForTesting`. Task-local so concurrently running
    /// suites that do not bind it keep the headless denial.
    typealias TestPresenter = @Sendable (_ id: UUID, _ toolName: String, _ queuedBehind: Int) -> Void

    @TaskLocal
    static var presentationOverrideForTests: TestPresenter?

    static func resolveForTesting(id: UUID, outcome: PromptResolution) {
        resolve(id: id, outcome: outcome)
    }

    /// Whether a real AppKit permission panel is currently presented. Exists
    /// so a test can assert that no window outlives an approval call — the
    /// window left behind is the thing that could neither be clicked nor
    /// quit. Test stand-ins (presenter override) are not windows; see
    /// `presentedPromptIDForTesting`.
    static var hasOpenPermissionWindowForTesting: Bool {
        if case .presented(_, let handles?) = slot { return handles.panel.isVisible }
        return false
    }

    static var presentedPromptIDForTesting: UUID? { slot?.id }
    static var queuedPromptCountForTesting: Int { queue.count }

    /// Deny everything outstanding.
    static func resetForTesting() {
        let outstanding = queue.map(\.id) + Array(continuations.keys)
        for id in Set(outstanding) { resolve(id: id, outcome: .denied) }
        if let slot { tearDown(slot) }
        slot = nil
        queue.removeAll()
    }

    // MARK: - Entry points

    static func requestApproval(
        toolName: String,
        description: String,
        argumentsJSON: String,
        knowledgeWritePreview: KnowledgeWritePreview? = nil,
        perCallApprovalOnly: Bool = false
    ) async -> Bool {
        switch await requestApprovalOutcome(
            toolName: toolName,
            description: description,
            argumentsJSON: argumentsJSON,
            knowledgeWritePreview: knowledgeWritePreview,
            perCallApprovalOnly: perCallApprovalOnly
        ) {
        case .denied: return false
        case .allowOnce, .allowForRun, .alwaysAllow: return true
        }
    }

    /// `knowledgeWritePreview` swaps the generic JSON arguments block for a
    /// per-document manifest with diffs. Supplied only by the knowledge write
    /// tools; every other caller leaves it nil and the modal is unchanged.
    ///
    /// `perCallApprovalOnly` suppresses "Allow for This Task" and "Always
    /// Allow" so the call cannot be pre-granted. See `PerCallApprovalTool`.
    static func requestApprovalOutcome(
        toolName: String,
        description: String,
        argumentsJSON: String,
        knowledgeWritePreview: KnowledgeWritePreview? = nil,
        perCallApprovalOnly: Bool = false
    ) async -> ApprovalOutcome {
        if isHeadlessTestProcess { return .denied }
        if Task.isCancelled { return .denied }

        let resolution = await enqueue(
            PromptRequest(
                toolName: toolName,
                description: description,
                argumentsJSON: argumentsJSON,
                knowledgeWritePreview: knowledgeWritePreview,
                perCallApprovalOnly: perCallApprovalOnly,
                offersRunLease: !perCallApprovalOnly
            ),
            revalidate: nil
        )
        switch resolution {
        case .denied:
            return .denied
        case .allowOnce:
            return .allowOnce
        case .allowForRun:
            return .allowForRun
        case .alwaysAllow:
            ToolRegistry.shared.setPolicy(.auto, for: toolName)
            return .alwaysAllow
        }
    }

    /// Approval prompt for a caller-owned policy. Unlike `requestApproval`,
    /// choosing "Always Allow" does NOT mutate `ToolRegistry`: the caller owns
    /// the policy namespace and persists that outcome in its own store.
    ///
    /// Cancellation is terminal and denial-shaped. This is required by spawn
    /// preparation, where the feed's Stop control can fire while the panel is
    /// open (or while the request is still queued behind another prompt); the
    /// continuation must be resumed and the modal dismissed rather than
    /// stranding the tool call.
    ///
    /// `revalidate` runs right before this request would be presented. Return
    /// a resolution to settle it silently (the caller's policy changed while it
    /// waited in the queue), or nil to show the panel.
    static func requestPolicyApproval(
        toolName: String,
        description: String,
        argumentsJSON: String,
        revalidate: (@Sendable () async -> PolicyApprovalOutcome?)? = nil
    ) async -> PolicyApprovalOutcome {
        if isHeadlessTestProcess { return .denied }
        if Task.isCancelled { return .denied }

        var mappedRevalidate: Revalidation?
        if let hook = revalidate {
            mappedRevalidate = { () async -> PromptResolution? in
                guard let outcome = await hook() else { return nil }
                return Self.resolution(for: outcome)
            }
        }
        let resolution = await enqueue(
            PromptRequest(
                toolName: toolName,
                description: description,
                argumentsJSON: argumentsJSON,
                knowledgeWritePreview: nil,
                perCallApprovalOnly: false,
                offersRunLease: false
            ),
            revalidate: mappedRevalidate
        )
        switch resolution {
        case .denied: return .denied
        case .allowOnce, .allowForRun: return .allowOnce
        case .alwaysAllow: return .alwaysAllow
        }
    }

    nonisolated private static func resolution(
        for outcome: PolicyApprovalOutcome
    ) -> PromptResolution {
        switch outcome {
        case .denied: return .denied
        case .allowOnce: return .allowOnce
        case .alwaysAllow: return .alwaysAllow
        }
    }

    // MARK: - Queue core

    private static func enqueue(
        _ request: PromptRequest,
        revalidate: Revalidation?
    ) async -> PromptResolution {
        let id = UUID()
        let presenter = presentationOverrideForTests
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[id] = continuation
                queue.append(
                    PendingPrompt(
                        id: id,
                        request: request,
                        revalidate: revalidate,
                        presenter: presenter
                    )
                )
                // Cancellation can race the MainActor hop into this
                // continuation. Re-check after the entry is registered so the
                // hook below (or this check) always finds something to deny.
                if Task.isCancelled {
                    resolve(id: id, outcome: .denied)
                    return
                }
                pump()
            }
        } onCancel: {
            Task { @MainActor in
                resolve(id: id, outcome: .denied)
            }
        }
    }

    /// Present the head of the queue if nothing is presented. Re-entrant safe:
    /// a resolution that happens synchronously inside presentation (headless
    /// guard, immediate cancellation) simply pumps again.
    private static func pump() {
        guard slot == nil else { return }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            // Resolved (cancelled) while it was still queued.
            guard continuations[next.id] != nil else { continue }

            if let revalidate = next.revalidate {
                slot = .revalidating(next.id)
                Task { @MainActor in
                    let early = await revalidate()
                    // Resolved during the re-check: `resolve` already
                    // released the slot and pumped.
                    guard case .revalidating(let heldId)? = slot, heldId == next.id else { return }
                    if let early {
                        resolve(id: next.id, outcome: early)
                    } else {
                        present(next)
                    }
                }
                return
            }

            present(next)
            return
        }
    }

    private static func resolve(id: UUID, outcome: PromptResolution) {
        queue.removeAll { $0.id == id }
        if let current = slot, current.id == id {
            tearDown(current)
            slot = nil
        }
        if let continuation = continuations.removeValue(forKey: id) {
            continuation.resume(returning: outcome)
        }
        pump()
    }

    private static func tearDown(_ slot: PresenterSlot) {
        guard case .presented(_, let handles?) = slot else { return }
        NotificationCenter.default.removeObserver(handles.closeObserver)
        if let monitor = handles.keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        handles.panel.orderOut(nil)
        lastRenderedCardSize = nil
    }

    // MARK: - Presentation

    private static func present(_ entry: PendingPrompt) {
        let id = entry.id
        let request = entry.request
        let queuedBehind = queue.count

        if let override = entry.presenter {
            slot = .presented(id, nil)
            override(id, request.toolName, queuedBehind)
            return
        }

        let onAllow = { resolve(id: id, outcome: .allowOnce) }
        let onDeny = { resolve(id: id, outcome: .denied) }
        let onAlwaysAllow = { resolve(id: id, outcome: .alwaysAllow) }
        let onAllowForRun: (() -> Void)? =
            request.offersRunLease && !request.perCallApprovalOnly
            ? { resolve(id: id, outcome: .allowForRun) }
            : nil

        let themeManager = ThemeManager.shared
        let permissionView = ToolPermissionView(
            toolName: request.toolName,
            description:
                request.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "This action requires your approval."
                : request.description,
            argumentsJSON: request.argumentsJSON,
            onAllow: onAllow,
            onDeny: onDeny,
            onAlwaysAllow: onAlwaysAllow,
            onAllowForRun: onAllowForRun,
            knowledgeWritePreview: request.knowledgeWritePreview,
            perCallApprovalOnly: request.perCallApprovalOnly,
            queuedBehind: queuedBehind
        )
        .environment(\.theme, themeManager.currentTheme)

        let handles = makePanel(view: permissionView, onAllow: onAllow, onDeny: onDeny)
        slot = .presented(id, handles)
        // Apply the card size reported during the sizing layout pass, when
        // the panel was not yet registered and the callback could not act.
        if let renderedSize = lastRenderedCardSize {
            resizePanelToRenderedContent(renderedSize)
        }
        NSApp.activate(ignoringOtherApps: true)
        handles.panel.makeKeyAndOrderFront(nil)
        let panel = handles.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            panel.makeKey()
            if let contentView = panel.contentView { panel.makeFirstResponder(contentView) }
        }
    }

    /// Builds a centered borderless modal panel hosting `view`, wires
    /// Enter→allow / Esc→deny key handling, and a close-safety-net that denies.
    /// Every handle is returned to the caller; nothing is stored in a shared
    /// static, so a second panel can never orphan the first.
    private static func makePanel<V: View>(
        view: V,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) -> PanelHandles {
        // `fittingSize` measures the card at its ideal size, but the
        // description/arguments ScrollViews report their full content height
        // as ideal while rendering capped. Sizing the window from that
        // measurement leaves transparent slack around the card whose edge
        // shows as a scribbled outline. Track the rendered size instead and
        // keep the window glued to it.
        let sizedView = view.onGeometryChange(for: CGSize.self, of: \.size) { size in
            // The first report arrives during the sizing layout pass, before
            // the panel is registered; stash it so presentation can apply it.
            lastRenderedCardSize = size
            resizePanelToRenderedContent(size)
        }
        let hostingController = NSHostingController(rootView: sizedView)
        // The hidden title bar must not become a SwiftUI safe-area inset:
        // it pushes the card down and leaves a transparent strip at the top
        // of the panel where the window edge shows through.
        hostingController.safeAreaRegions = []
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Tool Permission")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Follow the app theme, not the system appearance: otherwise the
        // scroll indicators render for the wrong appearance (white thumb on
        // the light card).
        panel.appearance = NSAppearance(
            named: ThemeManager.shared.currentTheme.isDark ? .darkAqua : .aqua
        )
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .alertPanel
        panel.contentViewController = hostingController

        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        let windowSize = NSSize(
            width: max(fittingSize.width, 480),
            height: max(fittingSize.height, 300)
        )
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first {
            NSMouseInRect(mouse, $0.frame, false)
        }
        // Keep the decision on the launching app window's display. Falling
        // back to the mouse display can make a security prompt appear on a
        // different monitor than the chat that is visibly blocked on it.
        let targetScreen = preferredPresentationCandidate(
            keyWindow: NSApp.keyWindow?.screen,
            mainWindow: NSApp.mainWindow?.screen,
            mouse: mouseScreen,
            fallback: NSScreen.main
        )
        if let screen = targetScreen {
            let vf = screen.visibleFrame
            // The approval buttons must stay reachable: never size the panel
            // taller (or wider) than the visible screen area. With
            // .fullSizeContentView the content fills the whole frame, so the
            // fitting size is the frame size; adding a title-bar conversion
            // here over-sizes the window and leaves empty strips.
            let frameSize = clampedWindowSize(windowSize, to: vf.size)
            panel.setFrame(
                NSRect(
                    x: vf.origin.x + (vf.width - frameSize.width) / 2,
                    y: vf.origin.y + (vf.height - frameSize.height) / 2,
                    width: frameSize.width,
                    height: frameSize.height
                ),
                display: false
            )
        } else {
            panel.setContentSize(windowSize)
            panel.center()
        }

        nonisolated(unsafe) let onDenyForClose = onDeny
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in onDenyForClose() }

        let handleKeyEvent: (NSEvent) -> Bool = { event in
            if event.keyCode == 36 { onAllow(); return true }
            if event.keyCode == 53 { onDeny(); return true }
            return false
        }
        weak var weakPanel = panel
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard shouldAcceptKeyboardShortcut(
                isVisible: weakPanel?.isVisible == true,
                isKeyWindow: weakPanel?.isKeyWindow == true,
                isAppActive: NSApp.isActive
            ) else {
                return event
            }
            return handleKeyEvent(event) ? nil : event
        }
        return PanelHandles(panel: panel, closeObserver: closeObserver, keyMonitor: keyMonitor)
    }

    private static var presentedPanel: NSPanel? {
        guard case .presented(_, let handles?) = slot else { return nil }
        return handles.panel
    }

    /// Snaps the panel to the card's actually rendered size, recentered on
    /// its screen and clamped to the visible frame so the approval buttons
    /// stay reachable. Called from `onGeometryChange`, so the window follows
    /// the card if its layout settles differently than first measured.
    private static func resizePanelToRenderedContent(_ size: CGSize) {
        guard let panel = presentedPanel, size.width > 1, size.height > 1 else { return }
        var target = NSSize(width: size.width, height: size.height)
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame
        if let vf { target = clampedWindowSize(target, to: vf.size) }
        guard abs(panel.frame.width - target.width) > 0.5
            || abs(panel.frame.height - target.height) > 0.5
        else { return }
        let origin: NSPoint
        if let vf {
            origin = NSPoint(
                x: vf.origin.x + (vf.width - target.width) / 2,
                y: vf.origin.y + (vf.height - target.height) / 2
            )
        } else {
            origin = panel.frame.origin
        }
        panel.setFrame(NSRect(origin: origin, size: target), display: true)
        panel.invalidateShadow()
    }

    // MARK: - Pure seams

    /// Pure seams keep the security-sensitive screen and key-event policy
    /// deterministic in tests without constructing AppKit windows.
    nonisolated static func clampedWindowSize(_ size: NSSize, to visible: NSSize) -> NSSize {
        NSSize(
            width: min(size.width, visible.width),
            height: min(size.height, visible.height)
        )
    }

    nonisolated static func preferredPresentationCandidate<T>(
        keyWindow: T?,
        mainWindow: T?,
        mouse: T?,
        fallback: T?
    ) -> T? {
        keyWindow ?? mainWindow ?? mouse ?? fallback
    }

    nonisolated static func shouldAcceptKeyboardShortcut(
        isVisible: Bool,
        isKeyWindow: Bool,
        isAppActive: Bool
    ) -> Bool {
        isVisible && isKeyWindow && isAppActive
    }
}
