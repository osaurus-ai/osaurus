//
//  BackgroundDriver.swift
//  OsaurusCore — Computer Use
//
//  Native macOS driver, brought in-core from osaurus-ai/osaurus-macos-use.
//  Per-pid input layer that defaults to backgrounded routing (no cursor warp)
//  and walks the SkyLight → CGEvent.postToPid → HID-tap fallback chain.
//

import AppKit
import CoreGraphics
import Darwin
import Foundation
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
        FileHandle.standardError.write(Data("[cu-input] \(text)\n".utf8))
    }
}

// MARK: - Routing Telemetry

/// Tells the caller (and tests) which transport the driver actually used.
/// The fallback chain — SkyLight → CGEvent.postToPid → HID tap — degrades
/// from "fully backgrounded" to "warps the user's cursor" so it's important
/// for the agent to know when the cursor moved.
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
private enum AppClass {
    case chromium
    case cocoa
    case unknown
}

private enum BundleClass {

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

    static func classify(pid: pid_t) -> AppClass {
        lock.lock()
        if let cached = cache[pid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = computeClass(for: pid)

        lock.lock()
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
/// Routing chain for every action:
///   1. `SLEventPostToPid` (SkyLight private framework). Cursor never moves;
///      Chromium renderers accept it.
///   2. `CGEvent.postToPid` (CoreGraphics public API). Cursor never moves
///      but Chromium web content silently drops the event.
///   3. `CGEvent.post(tap: .cghidEventTap)` (HID stream). Warps the cursor;
///      visible to the user; only used for canvas/games.
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
        var focusWithoutRaise: @Sendable (pid_t) -> Void

        static let live = Transports(
            isWindowServerVisible: { SkyLightBridge.isWindowServerVisible(pid: $0) },
            skyLightAvailable: { SkyLightBridge.isAvailable },
            skyLightPost: { SkyLightBridge.postEvent($0, toPid: $1) },
            postToPid: { $0.postToPid($1) },
            hidPost: { $0.post(tap: .cghidEventTap) },
            isChromium: { BundleClass.isChromium(pid: $0) },
            focusWithoutRaise: { _ = SkyLightBridge.focusWithoutRaise(pid: $0) }
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

    /// Post a fully-built `CGEvent` to `pid`, walking the fallback chain.
    ///
    /// `forceHID` is the single escape hatch for callers who *must* hit the
    /// HID tap (e.g. drag, where each step must continue from the previous
    /// mouseDown that we already posted via HID).
    @discardableResult
    private func route(event: CGEvent, pid: pid_t, forceHID: Bool = false) -> InputRoute {
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

        // SkyLight is the primary transport for every window-server-visible GUI
        // app: it delivers without warping the cursor and Chromium renderers
        // accept it. It is also TERMINAL — once SkyLight has the event we must
        // NOT also postToPid, or the event lands twice. (postEvent now reports
        // success on a completed call; it used to mis-detect SkyLight's
        // non-zero success code as failure, which is what produced the
        // double-delivery doubling.)
        if transports.skyLightAvailable() && transports.skyLightPost(event, pid) {
            record(route: .skyLight)
            return .skyLight
        }

        // Reached only when the SkyLight symbol is unavailable (older/newer
        // macOS, sandboxed host).
        //
        // For Chromium/Electron web content, per-pid delivery is BOTH
        // unconfirmable (postToPid is fire-and-forget) AND silently dropped by
        // the renderer's trusted-gesture filter — the signature Slack/Electron
        // miss. So rather than post a per-pid event that never lands and only
        // logging telemetry, escalate straight to the HID tap. The cursor warp
        // is the lesser evil vs. a keystroke/click that silently misses, and
        // using a SINGLE transport (HID, not postToPid+HID) avoids the
        // double-delivery class of bug.
        if transports.isChromium(pid) {
            transports.hidPost(event)
            InputDebug.log("route pid=\(pid) -> hidFallback (Chromium; per-pid not deliverable)")
            record(route: .hidFallback)
            return .hidFallback
        }

        // CGEvent.postToPid is public CoreGraphics API and works for almost all
        // Cocoa apps; the cursor never moves.
        transports.postToPid(event, pid)
        InputDebug.log("route pid=\(pid) -> perPid (SkyLight unavailable)")
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
    /// Optional `windowId` is forwarded to `focusWithoutRaise` so we can
    /// flip AppKit-active routing for that specific window without raising.
    func click(
        pid: pid_t,
        point: CGPoint,
        button: MouseButton = .left,
        clickCount: Int = 1,
        windowId: CGWindowID? = nil
    ) -> InputResult {
        transports.focusWithoutRaise(pid)

        if transports.isChromium(pid) {
            // (-1, -1) decoy click ticks Chromium's user-activation gate so the
            // real click that follows is treated as a trusted user gesture.
            // The renderer drops the decoy because no window claims that pixel.
            _ = postClickPair(pid: pid, point: CGPoint(x: -1, y: -1), button: .left, clickCount: 1)
            // Small gap so the renderer has a chance to update its activation
            // state before the real click arrives.
            Thread.sleep(forTimeInterval: 0.01)
        }

        return postClickPair(pid: pid, point: point, button: button, clickCount: clickCount)
    }

    func doubleClick(pid: pid_t, point: CGPoint, button: MouseButton = .left) -> InputResult {
        let r1 = click(pid: pid, point: point, button: button, clickCount: 1)
        if !r1.success { return r1 }
        Thread.sleep(forTimeInterval: 0.05)
        return click(pid: pid, point: point, button: button, clickCount: 2)
    }

    /// Build the down/up event pair and route both to `pid`.
    private func postClickPair(
        pid: pid_t,
        point: CGPoint,
        button: MouseButton,
        clickCount: Int
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

        _ = route(event: down, pid: pid)
        _ = route(event: up, pid: pid)
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
        transports.focusWithoutRaise(pid)
        if transports.isChromium(pid) {
            _ = postClickPair(pid: pid, point: CGPoint(x: -1, y: -1), button: .left, clickCount: 1)
            Thread.sleep(forTimeInterval: 0.01)
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
            Thread.sleep(forTimeInterval: 0.005)
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

    func scroll(pid: pid_t, direction: ScrollDirection, amount: Int32 = 3) -> InputResult {
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
        _ = route(event: event, pid: pid)
        return .ok()
    }

    // MARK: - Public API: drag
    //
    // Drag is the one operation that can NOT be cleanly backgrounded for
    // arbitrary apps: many apps key drag tracking on the global cursor
    // location, so the cursor genuinely needs to move during the drag.
    // We post via SkyLight when possible (which avoids the warp inside other
    // apps) but force HID tap for the down/drag/up sequence so the system
    // sees a coherent gesture. Tests should treat drag as cursor-warping.

    func drag(pid: pid_t, from start: CGPoint, to end: CGPoint, button: MouseButton = .left)
        -> InputResult
    {
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
        _ = route(event: down, pid: pid, forceHID: true)

        // CRITICAL: always release the button. Same invariant as the
        // MouseController.drag — if we somehow fail to post the up event, the
        // OS believes the user is still holding the mouse button down.
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
                _ = route(event: release, pid: pid, forceHID: true)
            }
        }

        Thread.sleep(forTimeInterval: 0.05)

        guard
            let dragEvent = CGEvent(
                mouseEventSource: source,
                mouseType: dragType,
                mouseCursorPosition: end,
                mouseButton: mouseButton
            )
        else {
            return .fail("Failed to create mouse drag event")
        }
        _ = route(event: dragEvent, pid: pid, forceHID: true)

        Thread.sleep(forTimeInterval: 0.05)

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
        _ = route(event: up, pid: pid, forceHID: true)
        releaseFired = true

        return .ok()
    }
}
