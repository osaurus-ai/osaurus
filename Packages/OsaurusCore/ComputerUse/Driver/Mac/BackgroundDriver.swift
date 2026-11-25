//
//  BackgroundDriver.swift
//  OsaurusCore — Computer Use
//
//  Native macOS driver, brought in-core from osaurus-ai/osaurus-macos-use.
//  Per-pid input layer that defaults to backgrounded routing (no cursor warp)
//  and selects exactly one transport for each target app class.
//

import AppKit
import CoreGraphics
import Darwin
import Foundation
import MLXLMCommon
import os

// MARK: - Input Diagnostics

/// Gated diagnostics for the input-routing layer. Off unless the app is
/// launched with `OSAURUS_CU_INPUT_DEBUG=1`. Logs the raw `SLEventPostToPid`
/// return value and the transport `route` actually used, so transport bugs
/// (like the SkyLight + `postToPid` double-delivery this flag was added to
/// diagnose) are visible without guessing from a transcript. Writes to the
/// unified log and to stderr so it surfaces whether launched via Console.app
/// or a terminal.
enum InputDebug {
    static let isEnabled = ProcessInfo.processInfo.environment["OSAURUS_CU_INPUT_DEBUG"] == "1"
    private static let logger = Logger(subsystem: "com.osaurus.computeruse", category: "input")

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
        RuntimeDiagnostics.write(Data("[cu-input] \(text)\n".utf8))
    }
}

// MARK: - Routing Telemetry

/// Tells the caller (and tests) which transport the driver actually used.
/// The selected transport. A synthesized event must never be submitted to a
/// second transport after the first call: SkyLight's return value is not a
/// reliable delivery acknowledgement, and retrying can deliver the event twice.
public enum InputRoute: String, Codable, Sendable {
    /// `SLEventPostToPid`. No cursor warp; trusted by Chromium renderers.
    case skyLight
    /// `CGEvent.postToPid`. No cursor warp; works for most Cocoa apps but
    /// rejected by Chromium web content.
    case perPid
    /// `CGEvent.post(tap: .cghidEventTap)`. **Warps the user's cursor.**
    /// Only used as a last resort for canvas/Blender/Unity-style apps that
    /// filter per-pid event routes entirely.
    case hidFallback
}

// MARK: - App Class Detection

/// Coarse classification of a target app — drives whether we need the
/// Chromium "primer click" trick and whether SkyLight routing is worth
/// trying first.
enum AppClass {
    case chromium
    case cocoa
    case unknown
}

enum BundleClass {

    // pid → AppClass cache. Apps don't change bundle ids during their
    // lifetime, so a one-time lookup is safe.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [pid_t: AppClass] = [:]

    /// Known Chromium-derived browser bundle ids. These are the ones the
    /// background-driver recipe explicitly targets with the renderer-IPC
    /// primer click.
    private static let chromiumBundles: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
    ]

    /// Prune threshold: pids recycle over time, so entries for dead
    /// processes are both stale (a reused pid could classify wrongly) and a
    /// slow leak. When the cache crosses this size, drop dead-pid entries.
    private static let pruneThreshold = 64

    static func classify(pid: pid_t) -> AppClass {
        lock.lock()
        if let cached = cache[pid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = computeClass(for: pid)

        lock.lock()
        if cache.count >= pruneThreshold {
            // `NSRunningApplication(processIdentifier:)` returns nil for dead
            // pids; that also evicts any entry a recycled pid would have hit.
            cache = cache.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
        }
        cache[pid] = result
        lock.unlock()
        return result
    }

    static func isChromium(pid: pid_t) -> Bool {
        return classify(pid: pid) == .chromium
    }

    private static func computeClass(for pid: pid_t) -> AppClass {
        guard let app = NSRunningApplication(processIdentifier: pid),
            let bundleId = app.bundleIdentifier
        else { return .unknown }

        if chromiumBundles.contains(bundleId) {
            return .chromium
        }
        // Generic Electron detection: an Electron Framework lives inside the
        // app bundle's Frameworks folder.
        if let bundleURL = app.bundleURL {
            let electron = bundleURL.appendingPathComponent(
                "Contents/Frameworks/Electron Framework.framework",
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: electron.path) {
                return .chromium
            }
        }
        return .cocoa
    }
}

// MARK: - Background Driver

/// Per-pid input layer that defaults to backgrounded routing.
///
/// Routing is mutually exclusive by target app class:
///   - Cocoa/unknown GUI apps use public `CGEvent.postToPid` only.
///   - Chromium apps use SkyLight when its symbol is available, otherwise HID.
///   - Explicit HID callers (for example a drag already begun on HID) stay HID.
///
/// Never call SkyLight and then fall through to another transport based on its
/// ambiguous status code. A completed call can deliver even when it returns 0;
/// retrying that event through CoreGraphics caused doubled TextEdit input.
final class BackgroundDriver: @unchecked Sendable {
    static let shared = BackgroundDriver()

    /// Seam over the external transports `route`/`prepareForKeyboard` depend on.
    /// Production uses `.live`; tests inject spies to assert that each event is
    /// delivered through exactly one transport — the regression guard for the
    /// SkyLight + `postToPid` double-delivery that doubled every keystroke.
    struct Transports: Sendable {
        var isWindowServerVisible: @Sendable (pid_t) -> Bool
        var skyLightAvailable: @Sendable () -> Bool
        var skyLightPost: @Sendable (CGEvent, pid_t) -> Bool
        var postToPid: @Sendable (CGEvent, pid_t) -> Void
        var hidPost: @Sendable (CGEvent) -> Void
        var isChromium: @Sendable (pid_t) -> Bool
        var focusWithoutRaise: @Sendable (pid_t, CGWindowID?) -> Void
        /// The target's frontmost on-screen window containing a point, for
        /// pointer events whose caller doesn't know the window.
        var windowAt: @Sendable (pid_t, CGPoint) -> CGWindowID?
        var pause: @Sendable (TimeInterval) -> Void

        static let live = Transports(
            isWindowServerVisible: { SkyLightBridge.isWindowServerVisible(pid: $0) },
            skyLightAvailable: { SkyLightBridge.isAvailable },
            skyLightPost: { SkyLightBridge.postEvent($0, toPid: $1) },
            postToPid: { $0.postToPid($1) },
            hidPost: { $0.post(tap: .cghidEventTap) },
            isChromium: { BundleClass.isChromium(pid: $0) },
            focusWithoutRaise: { _ = SkyLightBridge.focusWithoutRaise(pid: $0, windowId: $1) },
            windowAt: { WindowBinding.window(ownedBy: $0, containing: $1) },
            pause: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    private let transports: Transports

    /// Diagnostics: most-recent route used. Tests assert against this; agents
    /// can read it via the `routeUsed` field returned in action results.
    private let routeLock = NSLock()
    private var _lastRoute: InputRoute = .skyLight
    var lastRoute: InputRoute {
        routeLock.lock()
        defer { routeLock.unlock() }
        return _lastRoute
    }

    init(transports: Transports = .live) {
        self.transports = transports
    }

    // MARK: - Event source

    /// One shared `CGEventSource` for everything we synthesize. SkyLight does
    /// not require a particular source — it stamps its own trust envelope on
    /// post — but reusing one source keeps modifier state coherent across
    /// successive calls.
    nonisolated(unsafe) private let source: CGEventSource = {
        return CGEventSource(stateID: .hidSystemState) ?? CGEventSource(stateID: .privateState)!
    }()

    // MARK: - Routing primitive

    /// Post a fully-built `CGEvent` to `pid` through one selected transport.
    ///
    /// `forceHID` is the single escape hatch for callers who *must* hit the
    /// HID tap (e.g. drag, where each step must continue from the previous
    /// mouseDown that we already posted via HID).
    @discardableResult
    private func route(event: CGEvent, pid: pid_t, forceHID: Bool = false) -> InputRoute {
        ComputerUseEventTag.mark(event)
        if forceHID {
            transports.hidPost(event)
            record(route: .hidFallback)
            InputDebug.log("route pid=\(pid) -> hidFallback (forceHID)")
            return .hidFallback
        }

        // Guard against pids that don't correspond to a WindowServer-visible
        // GUI app. Both SkyLight's SLEventPostToPid and CoreGraphics'
        // postToPid have been observed to segfault when handed a stale,
        // never-existed, or CLI-only pid.
        guard transports.isWindowServerVisible(pid) else {
            record(route: .perPid)
            InputDebug.log("route pid=\(pid) -> perPid (not window-server-visible)")
            return .perPid
        }

        // Chromium/Electron web content silently drops public per-pid events.
        // SkyLight is therefore its preferred background route. Its status is
        // deliberately ignored after the call: live macOS builds have returned
        // zero while still delivering, so a same-event fallback is unsafe.
        if transports.isChromium(pid) {
            if transports.skyLightAvailable() {
                _ = transports.skyLightPost(event, pid)
                InputDebug.log("route pid=\(pid) -> skyLight (Chromium; terminal call)")
                record(route: .skyLight)
                return .skyLight
            }
            transports.hidPost(event)
            InputDebug.log("route pid=\(pid) -> hidFallback (Chromium; SkyLight unavailable)")
            record(route: .hidFallback)
            return .hidFallback
        }

        // Cocoa and unknown GUI apps take the public CoreGraphics path without
        // first attempting SkyLight. This is the crucial no-double-delivery
        // invariant: exactly one transport receives each event.
        transports.postToPid(event, pid)
        InputDebug.log("route pid=\(pid) -> perPid (Cocoa/unknown; exclusive)")
        record(route: .perPid)
        return .perPid
    }

    private func record(route: InputRoute) {
        routeLock.lock()
        _lastRoute = route
        routeLock.unlock()
    }

    // MARK: - Public API: clicks

    /// Click at a point in global screen coordinates, addressed to `pid`.
    /// The events are bound to `windowId` (else the target's window under the
    /// point) so, with several windows open, they land in that window rather
    /// than wherever macOS routes an unbound event; focus-without-raise is
    /// aimed at the same window.
    func click(
        pid: pid_t,
        point: CGPoint,
        button: MouseButton = .left,
        clickCount: Int = 1,
        windowId: CGWindowID? = nil
    ) -> InputResult {
        let window = windowId ?? transports.windowAt(pid, point)
        transports.focusWithoutRaise(pid, window)

        if transports.isChromium(pid) {
            // (-1, -1) decoy click ticks Chromium's user-activation gate so the
            // real click that follows is treated as a trusted user gesture.
            // The renderer drops the decoy because no window claims that pixel.
            _ = postClickPair(pid: pid, point: CGPoint(x: -1, y: -1), button: .left, clickCount: 1, windowId: nil)
            // Small gap so the renderer has a chance to update its activation
            // state before the real click arrives.
            transports.pause(0.01)
        }

        return postClickPair(pid: pid, point: point, button: button, clickCount: clickCount, windowId: window)
    }

    func doubleClick(
        pid: pid_t,
        point: CGPoint,
        button: MouseButton = .left,
        windowId: CGWindowID? = nil
    ) -> InputResult {
        let window = windowId ?? transports.windowAt(pid, point)
        let r1 = click(pid: pid, point: point, button: button, clickCount: 1, windowId: window)
        if !r1.success { return r1 }
        transports.pause(0.05)
        return click(pid: pid, point: point, button: button, clickCount: 2, windowId: window)
    }

    /// Build the down/up event pair and route both to `pid`.
    private func postClickPair(
        pid: pid_t,
        point: CGPoint,
        button: MouseButton,
        clickCount: Int,
        windowId: CGWindowID?
    ) -> InputResult {
        let downType: CGEventType
        let upType: CGEventType
        let mouseButton: CGMouseButton

        switch button {
        case .left:
            downType = .leftMouseDown
            upType = .leftMouseUp
            mouseButton = .left
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
            mouseButton = .right
        case .center:
            downType = .otherMouseDown
            upType = .otherMouseUp
            mouseButton = .center
        }

        guard
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: downType,
                mouseCursorPosition: point,
                mouseButton: mouseButton
            ),
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: upType,
                mouseCursorPosition: point,
                mouseButton: mouseButton
            )
        else {
            return .fail("Failed to create mouse events")
        }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        WindowBinding.bind(down, to: windowId)
        WindowBinding.bind(up, to: windowId)

        _ = route(event: down, pid: pid)
        _ = route(event: up, pid: pid)
        return .ok()
    }

    /// Move the pointer to `point` in `pid`'s window without clicking, as
    /// a short approach so hover tracking sees motion into the target.
    func move(pid: pid_t, to point: CGPoint, windowId: CGWindowID? = nil) -> InputResult {
        let window = windowId ?? transports.windowAt(pid, point)
        for at in [CGPoint(x: point.x - 6, y: point.y - 6), point] {
            guard
                let moved = CGEvent(
                    mouseEventSource: source,
                    mouseType: .mouseMoved,
                    mouseCursorPosition: at,
                    mouseButton: .left
                )
            else {
                return .fail("Failed to create mouse move event")
            }
            WindowBinding.bind(moved, to: window)
            _ = route(event: moved, pid: pid)
            transports.pause(0.02)
        }
        return .ok()
    }

    // MARK: - Public API: keyboard

    /// Make `pid` ready to receive synthesized keystrokes without raising it.
    ///
    /// Posting a key event to a pid isn't enough on its own: a Cocoa app has to
    /// be AppKit-active for the keystroke to reach its key window / menu
    /// shortcuts, and a Chromium renderer drops keys that didn't follow a
    /// trusted user gesture. So we route input focus to the target (no raise,
    /// same as `click`) and, for Electron/Chromium, tick the user-activation
    /// gate with the same off-screen decoy click `click` uses. Without this,
    /// app shortcuts like Cmd+K posted to Slack "succeed" but never land.
    private func prepareForKeyboard(pid: pid_t) {
        transports.focusWithoutRaise(pid, nil)
        if transports.isChromium(pid) {
            _ = postClickPair(pid: pid, point: CGPoint(x: -1, y: -1), button: .left, clickCount: 1, windowId: nil)
            transports.pause(0.01)
        }
    }

    /// Type a string of text. Per-pid routing means the user can keep typing
    /// in their own focused app while we type into `pid`.
    func type(pid: pid_t, text: String) -> InputResult {
        prepareForKeyboard(pid: pid)
        for char in text {
            if let result = typeCharacter(pid: pid, char: char), !result.success {
                return result
            }
            transports.pause(0.005)
        }
        return .ok()
    }

    private func typeCharacter(pid: pid_t, char: Character) -> InputResult? {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            return .fail("Failed to create keyboard event")
        }
        // Attach the character to the keyDown ONLY. Real keystrokes never carry
        // text on release, Cocoa ignores any keyUp string, and Chromium/Electron
        // inserts a SECOND copy of the character when the keyUp also carries a
        // Unicode string — that double-insert is what produced "hheelllloo" in
        // Slack. Leave keyUp as a bare key release.
        var utf16 = Array(String(char).utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)

        _ = route(event: down, pid: pid)
        _ = route(event: up, pid: pid)
        return nil
    }

    /// Press a single key with optional modifiers, routed to `pid`.
    func pressKey(pid: pid_t, keyCode: CGKeyCode, modifiers: CGEventFlags = []) -> InputResult {
        prepareForKeyboard(pid: pid)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return .fail("Failed to create keyboard event")
        }
        down.flags = modifiers
        up.flags = modifiers

        _ = route(event: down, pid: pid)
        _ = route(event: up, pid: pid)
        return .ok()
    }

    // MARK: - Public API: scroll

    /// Scroll `pid`. With a `point` the wheel event is placed there, so the
    /// app (which receives it per-process) hit-tests that scroll area rather
    /// than the spot under the user's cursor. Wheel events do not carry the
    /// window-under-pointer fields, so they are placed, not window-bound.
    func scroll(
        pid: pid_t,
        direction: ScrollDirection,
        amount: Int32 = 3,
        at point: CGPoint? = nil
    ) -> InputResult {
        let deltaX: Int32
        let deltaY: Int32
        switch direction {
        case .up: (deltaX, deltaY) = (0, amount)
        case .down: (deltaX, deltaY) = (0, -amount)
        case .left: (deltaX, deltaY) = (amount, 0)
        case .right: (deltaX, deltaY) = (-amount, 0)
        }
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltaY,
                wheel2: deltaX,
                wheel3: 0
            )
        else {
            return .fail("Failed to create scroll event")
        }
        if let point { event.location = point }
        _ = route(event: event, pid: pid)
        return .ok()
    }

    // MARK: - Public API: drag

    /// Intermediate `dragged` events between `start` and `end`. Apps that
    /// track a drag (sliders, list reordering, selection) follow a path of
    /// moves; a single jump from down to up reads as a click.
    static func dragPath(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = min(30, max(4, Int(distance / 20)))
        return (1 ... steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }

    /// Drag from `start` to `end`, addressed to `pid` and bound to its window
    /// under `start`, along an interpolated path. Every event takes the same
    /// per-app route as a click (per-pid for Cocoa, SkyLight for Chromium),
    /// so the user's cursor stays put. Apps that track drags by the global
    /// cursor won't follow; the verify step reports that, and the pid-less
    /// `MouseController.drag` remains the explicit cursor-moving fallback.
    func drag(
        pid: pid_t,
        from start: CGPoint,
        to end: CGPoint,
        button: MouseButton = .left,
        windowId: CGWindowID? = nil
    ) -> InputResult {
        let downType: CGEventType
        let dragType: CGEventType
        let upType: CGEventType
        let mouseButton: CGMouseButton

        switch button {
        case .left:
            downType = .leftMouseDown
            dragType = .leftMouseDragged
            upType = .leftMouseUp
            mouseButton = .left
        case .right:
            downType = .rightMouseDown
            dragType = .rightMouseDragged
            upType = .rightMouseUp
            mouseButton = .right
        case .center:
            downType = .otherMouseDown
            dragType = .otherMouseDragged
            upType = .otherMouseUp
            mouseButton = .center
        }

        let window = windowId ?? transports.windowAt(pid, start)
        transports.focusWithoutRaise(pid, window)

        guard
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: downType,
                mouseCursorPosition: start,
                mouseButton: mouseButton
            )
        else {
            return .fail("Failed to create mouse down event")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        WindowBinding.bind(down, to: window)
        _ = route(event: down, pid: pid)

        // CRITICAL: always release the button. If the up event is never
        // posted, the target believes the button is still held.
        var releaseFired = false
        defer {
            if !releaseFired,
                let release = CGEvent(
                    mouseEventSource: source,
                    mouseType: upType,
                    mouseCursorPosition: end,
                    mouseButton: mouseButton
                )
            {
                WindowBinding.bind(release, to: window)
                _ = route(event: release, pid: pid)
            }
        }

        transports.pause(0.05)
        var previous = start
        for point in Self.dragPath(from: start, to: end) {
            guard
                let moved = CGEvent(
                    mouseEventSource: source,
                    mouseType: dragType,
                    mouseCursorPosition: point,
                    mouseButton: mouseButton
                )
            else {
                return .fail("Failed to create mouse drag event")
            }
            moved.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previous.x).rounded()))
            moved.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - previous.y).rounded()))
            WindowBinding.bind(moved, to: window)
            _ = route(event: moved, pid: pid)
            previous = point
            transports.pause(0.008)
        }

        guard
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: upType,
                mouseCursorPosition: end,
                mouseButton: mouseButton
            )
        else {
            return .fail("Failed to create mouse up event")
        }
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        WindowBinding.bind(up, to: window)
        _ = route(event: up, pid: pid)
        releaseFired = true

        return .ok()
    }
}

// MARK: - Window binding

/// Ties synthesized pointer events to one WindowServer window.
enum WindowBinding {
    static func bind(_ event: CGEvent, to windowId: CGWindowID?) {
        guard let windowId else { return }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowId))
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: Int64(windowId)
        )
    }

    /// Frontmost on-screen normal window of `pid` whose bounds contain `point`
    /// (global top-left coordinates).
    static func window(ownedBy pid: pid_t, containing point: CGPoint) -> CGWindowID? {
        let info =
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]]) ?? []
        for entry in info {
            guard (entry[kCGWindowOwnerPID] as? Int32) == pid,
                (entry[kCGWindowLayer] as? Int ?? 0) == 0,
                let boundsDict = entry[kCGWindowBounds] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.contains(point),
                let number = entry[kCGWindowNumber] as? Int
            else { continue }
            return CGWindowID(number)
        }
        return nil
    }
}

