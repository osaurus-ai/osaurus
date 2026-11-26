//
//  TakeoverController.swift
//  OsaurusCore — Computer Use
//
//  Shows the user that Computer Use has an app: a glowing shield ordered
//  directly above the window being driven (it swallows clicks and scrolls,
//  and is excluded from screen capture so the model never sees it), a status
//  pill with Stop, and a keyboard guard that turns Esc into Stop. Pointer
//  actions may travel through the HID tap, which hit-tests the topmost
//  window, so the shield goes click-through for exactly the duration of each
//  one. Everything tears down on every run outcome, when the target quits,
//  when Osaurus quits, and when heartbeats stop arriving.
//

import AppKit
import SwiftUI

@MainActor
final class TakeoverController {
    /// Seconds without a heartbeat before the overlay assumes its run is gone.
    static let watchdogSeconds: TimeInterval = ComputerUseLoop.presenceHeartbeatSeconds * 5
    static let trackingInterval: TimeInterval = 0.1

    let locksTarget: Bool
    private let onStop: () -> Void
    private let state = TakeoverViewState()
    private let clock: () -> Date

    private var shield: TakeoverPanel?
    private var pill: TakeoverPanel?
    private var keyboardGuard: KeyboardGuard?
    private var trackingTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private var target: ComputerUsePresenceTarget?
    private var windowId: CGWindowID?
    private var windowFrame: CGRect?
    private var acting = false
    private var lastHeartbeat: Date
    private(set) var isActive = false
    private(set) var isTornDown = false

    init(locksTarget: Bool, clock: @escaping () -> Date = Date.init, onStop: @escaping () -> Void) {
        self.locksTarget = locksTarget
        self.onStop = onStop
        self.clock = clock
        self.lastHeartbeat = clock()
        state.locksTarget = locksTarget
    }

    // MARK: Run events

    func begin(goal: String) {
        guard !isTornDown, !isActive else { return }
        isActive = true
        lastHeartbeat = clock()
        if locksTarget {
            let guardInstance = KeyboardGuard { [weak self] in self?.requestStop() }
            guardInstance.install()
            keyboardGuard = guardInstance
        }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.end() }
            }
        )
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                MainActor.assumeIsolated { self?.targetTerminated(pid: pid) }
            }
        )
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshFrontmost() } }
        )
        showPill()
        let timer = Timer(timeInterval: Self.trackingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    func targetChanged(_ newTarget: ComputerUsePresenceTarget?) {
        guard isActive, let newTarget else { return }
        let pidChanged = newTarget.pid != target?.pid
        target = newTarget
        state.appName = newTarget.app
        keyboardGuard?.targetPid = newTarget.pid
        refreshFrontmost()
        if pidChanged || windowId == nil || !framesClose(newTarget.windowFrame, windowFrame) {
            resolveWindow(near: newTarget.windowFrame)
        }
    }

    func willAct(_ act: ComputerUsePresenceAct) {
        guard isActive else { return }
        if let point = act.point, let frame = windowFrame {
            state.cursorPoint = TargetWindowLocator.localPoint(point, in: frame)
        }
        acting = act.movesPointer
        shield?.ignoresMouseEvents = shieldPassesMouse
    }

    func didAct() {
        guard isActive else { return }
        acting = false
        shield?.ignoresMouseEvents = shieldPassesMouse
    }

    func confirmPending(_ pending: Bool) {
        guard isActive else { return }
        state.confirmPending = pending
        shield?.ignoresMouseEvents = shieldPassesMouse
    }

    func heartbeat() {
        lastHeartbeat = clock()
    }

    /// Idempotent; every exit path funnels here.
    func end() {
        guard !isTornDown else { return }
        isTornDown = true
        isActive = false
        trackingTimer?.invalidate()
        trackingTimer = nil
        keyboardGuard?.uninstall()
        keyboardGuard = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        shield?.orderOut(nil)
        shield = nil
        pill?.orderOut(nil)
        pill = nil
    }

    // MARK: Inputs

    func requestStop() {
        guard isActive, !state.stopping else { return }
        state.stopping = true
        onStop()
    }

    private func review() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Mouse reaches the app when the lock is off, while a pointer action
    /// posts, and never otherwise; a pending confirmation keeps the shield
    /// solid so its click can bring the approval prompt forward.
    var shieldPassesMouse: Bool {
        if state.confirmPending { return false }
        return !locksTarget || acting
    }

    // MARK: Tracking

    private func tick() {
        guard isActive else { return }
        if clock().timeIntervalSince(lastHeartbeat) > Self.watchdogSeconds {
            ComputerUseTraceLog.note("takeover: heartbeat watchdog fired; tearing down")
            end()
            return
        }
        guard let windowId else {
            if target != nil { resolveWindow(near: windowFrame ?? target?.windowFrame) }
            return
        }
        guard let live = TargetWindowLocator.window(id: windowId) else {
            hideShield()
            self.windowId = nil
            return
        }
        if live.bounds != windowFrame {
            windowFrame = live.bounds
            placeShield(over: live)
            placePill()
        } else if !shieldSitsDirectlyAbove(windowId) {
            shield?.order(.above, relativeTo: Int(windowId))
        }
    }

    private func resolveWindow(near frame: CGRect?) {
        guard let target else { return }
        guard let match = TargetWindowLocator.bestMatch(
            for: frame,
            among: TargetWindowLocator.windows(pid: target.pid)
        ) else {
            hideShield()
            windowId = nil
            return
        }
        windowId = match.id
        windowFrame = match.bounds
        placeShield(over: match)
        placePill()
    }

    private func targetTerminated(pid: Int32?) {
        guard let pid, pid == target?.pid else { return }
        hideShield()
        windowId = nil
        keyboardGuard?.targetPid = nil
    }

    private func refreshFrontmost() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        state.targetIsFrontmost = frontmost != nil && frontmost == target?.pid
    }

    private func framesClose(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
            && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    private func shieldSitsDirectlyAbove(_ windowId: CGWindowID) -> Bool {
        guard let shield, shield.isVisible, shield.windowNumber > 0 else { return false }
        let below =
            (CGWindowListCopyWindowInfo(.optionOnScreenBelowWindow, CGWindowID(shield.windowNumber))
                as? [[CFString: Any]]) ?? []
        guard let next = below.first(where: { ($0[kCGWindowLayer] as? Int ?? 0) == 0 }) else { return false }
        return (next[kCGWindowNumber] as? Int).map { CGWindowID($0) } == windowId
    }

    // MARK: Panels

    private func placeShield(over window: WindowServerWindow) {
        let frame = TargetWindowLocator.appKitFrame(
            fromTopLeft: window.bounds,
            primaryScreenHeight: TargetWindowLocator.primaryScreenHeight
        )
        let panel = shield ?? makeShield(frame: frame)
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = shieldPassesMouse
        panel.order(.above, relativeTo: Int(window.id))
    }

    private func makeShield(frame: NSRect) -> TakeoverPanel {
        let panel = TakeoverPanel(contentRect: frame)
        panel.level = .normal
        let view = TakeoverShieldView(state: state, onReview: { [weak self] in self?.review() })
            .environment(\.theme, ThemeManager.shared.currentTheme)
        panel.contentView = NSHostingView(rootView: view)
        shield = panel
        return panel
    }

    private func hideShield() {
        shield?.orderOut(nil)
        state.cursorPoint = nil
    }

    private func showPill() {
        let panel = TakeoverPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44))
        panel.level = .floating
        panel.collectionBehavior.insert(.canJoinAllSpaces)
        let view = TakeoverStatusPillView(
            state: state,
            onStop: { [weak self] in self?.requestStop() },
            onReview: { [weak self] in self?.review() }
        )
        .environment(\.theme, ThemeManager.shared.currentTheme)
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        pill = panel
        placePill()
        panel.orderFrontRegardless()
    }

    /// Top-center of the screen holding the target window, under the menu bar.
    private func placePill() {
        guard let pill, let hosting = pill.contentView else { return }
        let size = hosting.fittingSize
        let screen = screenForTarget() ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10)
        pill.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func screenForTarget() -> NSScreen? {
        guard let windowFrame else { return nil }
        let frame = TargetWindowLocator.appKitFrame(
            fromTopLeft: windowFrame,
            primaryScreenHeight: TargetWindowLocator.primaryScreenHeight
        )
        return NSScreen.screens.max { a, b in
            a.frame.intersection(frame).area < b.frame.intersection(frame).area
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// `ComputerUsePresenting` adapter that forwards to a main-actor controller.
struct TakeoverPresenter: ComputerUsePresenting {
    let controller: TakeoverController

    func begin(goal: String) async { await controller.begin(goal: goal) }
    func targetChanged(_ target: ComputerUsePresenceTarget?) async { await controller.targetChanged(target) }
    func willAct(_ act: ComputerUsePresenceAct) async { await controller.willAct(act) }
    func didAct() async { await controller.didAct() }
    func confirmPending(_ pending: Bool) async { await controller.confirmPending(pending) }
    func heartbeat() async { await controller.heartbeat() }
    func end(_ outcome: RunOutcome) async { await controller.end() }
}
