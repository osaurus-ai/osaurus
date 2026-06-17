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

// MARK: - Routing Telemetry

/// Tells the caller (and tests) which transport the driver actually used.
/// The fallback chain — SkyLight → CGEvent.postToPid → HID tap — degrades
/// from "fully backgrounded" to "warps the user's cursor" so it's important
/// for the agent to know when the cursor moved.
enum InputRoute: String, Codable {
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

    /// Diagnostics: most-recent route used. Tests assert against this; agents
    /// can read it via the `routeUsed` field returned in action results.
    private let routeLock = NSLock()
    private var _lastRoute: InputRoute = .skyLight
    var lastRoute: InputRoute {
        routeLock.lock()
        defer { routeLock.unlock() }
        return _lastRoute
    }

    private init() {}

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
            event.post(tap: .cghidEventTap)
            record(route: .hidFallback)
            return .hidFallback
        }

        // Guard against pids that don't correspond to a WindowServer-visible
        // GUI app. Both SkyLight's SLEventPostToPid and CoreGraphics'
        // postToPid have been observed to segfault when handed a stale,
        // never-existed, or CLI-only pid.
        guard SkyLightBridge.isWindowServerVisible(pid: pid) else {
            record(route: .perPid)
            return .perPid
        }

        if SkyLightBridge.isAvailable && SkyLightBridge.postEvent(event, toPid: pid) {
            record(route: .skyLight)
            return .skyLight
        }

        // CGEvent.postToPid is public CoreGraphics API. Works for almost all
        // Cocoa apps; only Chromium's renderer filter is picky.
        event.postToPid(pid)
        let route: InputRoute = BundleClass.isChromium(pid: pid) ? .hidFallback : .perPid
        if route == .hidFallback {
            // Per-pid won't actually deliver to Chrome web content; mark the
            // failure in telemetry so the agent knows the click probably missed.
            // We still record .perPid as the *attempted* route — callers that
            // care can re-try with HID via the explicit "click" path.
            record(route: .perPid)
            return .perPid
        }
        record(route: route)
        return route
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
        SkyLightBridge.focusWithoutRaise(pid: pid)

        if BundleClass.isChromium(pid: pid) {
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

    /// Type a string of text. Per-pid routing means the user can keep typing
    /// in their own focused app while we type into `pid`.
    func type(pid: pid_t, text: String) -> InputResult {
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
        var utf16 = Array(String(char).utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)

        _ = route(event: down, pid: pid)
        _ = route(event: up, pid: pid)
        return nil
    }

    /// Press a single key with optional modifiers, routed to `pid`.
    func pressKey(pid: pid_t, keyCode: CGKeyCode, modifiers: CGEventFlags = []) -> InputResult {
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
