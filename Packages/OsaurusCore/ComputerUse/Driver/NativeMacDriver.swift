//
//  NativeMacDriver.swift
//  OsaurusCore — Computer Use
//
//  The in-process `MacDriver` conformer. Lifts the orchestration the driver's
//  former `Plugin.swift` tool handlers did into typed calls on the ported
//  `Driver/Mac/*` classes, returning the harness's `CU…` contract types. No
//  JSON marshalling, no PluginManager / ExternalPlugin.
//
//  AX reads and input synthesis run on a dedicated serial background queue
//  (`AccessibilityManager.runOffMain`) so slow cross-process AX IPC and the
//  per-character input sleeps never block the UI thread. Only `narrate` stays
//  on the main actor (it mutates `AutomationSession` UI state); screenshots use
//  async ScreenCaptureKit.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct NativeMacDriver: MacDriver {
    public init() {}

    // MARK: Availability

    public func availability() async -> MacDriverAvailability {
        await AccessibilityManager.runOffMain {
            MacDriverAvailability(
                accessibility: AXIsProcessTrusted(),
                screenRecording: CGPreflightScreenCaptureAccess(),
                skyLight: SkyLightBridge.isAvailable
            )
        }
    }

    // MARK: Perceive (read-only)

    public func listApps() async -> [CUAppListing] {
        await AccessibilityManager.runOffMain {
            listRunningApps().apps.map {
                CUAppListing(
                    pid: $0.pid,
                    bundleId: $0.bundleId,
                    name: $0.name,
                    active: $0.active,
                    hidden: $0.hidden
                )
            }
        }
    }

    public func listWindows(pid: Int32) async -> [CUWindowInfo] {
        await AccessibilityManager.runOffMain {
            listWindowsForPid(pid).windows.map {
                CUWindowInfo(
                    windowId: $0.windowId,
                    title: $0.title,
                    focused: $0.focused,
                    minimized: $0.minimized,
                    x: $0.x,
                    y: $0.y,
                    w: $0.w,
                    h: $0.h
                )
            }
        }
    }

    public func activeWindow() async -> CUActiveWindow? {
        await AccessibilityManager.runOffMain {
            guard let info = getActiveWindow() else { return nil }
            return CUActiveWindow(
                pid: info.pid,
                app: info.app,
                title: info.title,
                x: info.x,
                y: info.y,
                w: info.w,
                h: info.h
            )
        }
    }

    public func focusedContent(pid: Int32) async -> CUFocusedContent? {
        await AccessibilityManager.runOffMain {
            guard let info = computeFocusedContent(pid: pid) else { return nil }
            return CUFocusedContent(
                role: info.role,
                label: info.label,
                placeholder: info.placeholder,
                value: info.value,
                selectedText: info.selectedText,
                viewport: info.viewport
            )
        }
    }

    // MARK: Open

    public func open(
        identifier: String,
        background: Bool
    ) async -> Result<CUAppInfo, MacDriverError> {
        let opened = await openAppOnMain(identifier, background)
        switch opened {
        case .failure(let error):
            return .failure(.appNotFound(error.message))
        case .success(let info):
            return .success(CUAppInfo(pid: info.pid, bundleId: info.bundleId, name: info.name))
        }
    }

    @MainActor
    private func openAppOnMain(
        _ identifier: String,
        _ background: Bool
    ) async -> Result<MacAppInfo, MacAppError> {
        await openApplication(identifier: identifier, background: background)
    }

    // MARK: Capture / find

    public func capture(
        pid: Int32,
        tier: CaptureTier,
        windowId: Int?,
        maxElements: Int?,
        focusedWindowOnly: Bool,
        interactiveOnly: Bool
    ) async -> CUSnapshot {
        switch tier {
        case .ax:
            // Electron/Chromium build their AX tree asynchronously after
            // `AXManualAccessibility` flips, so wait for it before this one-shot
            // traverse (Cocoa apps + already-built trees return immediately).
            // Without this the first read of Slack/Chrome/VS Code is empty.
            await AccessibilityManager.shared.prepareAndAwaitTree(pid: pid)
            let snapshot = await AccessibilityManager.runOffMain { () -> TraversalResult in
                var filter = ElementFilter(pid: pid)
                if let maxElements { filter.maxElements = maxElements }
                if focusedWindowOnly { filter.focusedWindowOnly = true }
                filter.interactiveOnly = interactiveOnly
                return AccessibilityManager.shared.traverse(filter: filter)
            }
            return mapSnapshot(snapshot, tier: .ax, image: nil)
        case .som, .vision:
            let mode: CaptureMode = (tier == .som) ? .som : .vision
            let som = await buildCapture(
                pid: pid,
                mode: mode,
                windowId: windowId,
                maxElements: maxElements,
                focusedWindowOnly: focusedWindowOnly
            )
            return mapSnapshot(som.snapshot, tier: tier, image: som.image.map(mapImage))
        }
    }

    public func find(
        pid: Int32,
        text: String?,
        roles: [String]?,
        windowId: Int?,
        enabledOnly: Bool,
        limit: Int
    ) async -> CUSnapshot {
        await AccessibilityManager.runOffMain {
            var filter = ElementFilter(pid: pid)
            filter.roles = roles
            filter.maxDepth = 25
            filter.maxElements = limit
            filter.interactiveOnly = true
            let search = SearchOptions(
                text: text,
                enabledOnly: enabledOnly,
                windowId: windowId,
                limit: limit
            )
            let snapshot = AccessibilityManager.shared.traverse(filter: filter, search: search)
            return mapSnapshot(snapshot, tier: .ax, image: nil)
        }
    }

    // MARK: Act — element-addressed

    public func perform(_ action: CUElementAction) async -> CUActionResult {
        await AccessibilityManager.runOffMain {
            switch action {
            case let .click(id, button, doubleClick):
                let r: ElementActionResult
                if button == .right {
                    r = ElementInteraction.shared.rightClickElement(id: id)
                } else if doubleClick {
                    r = ElementInteraction.shared.doubleClickElement(id: id)
                } else {
                    r = ElementInteraction.shared.clickElement(id: id)
                }
                return mapActionResult(r)

            case let .setValue(id, value):
                return mapActionResult(ElementInteraction.shared.setElementValue(id: id, value: value))

            case let .clearField(id):
                return mapActionResult(ElementInteraction.shared.clearElement(id: id))

            case let .typeText(id, pid, text, replace):
                // Resolve target pid: explicit > derived from element id > most recent.
                let resolvedPid: Int32? =
                    pid
                    ?? id.flatMap { AccessibilityManager.shared.pid(for: $0) }
                    ?? AccessibilityManager.shared.mostRecentPid()

                if let elementId = id {
                    let focusResult = ElementInteraction.shared.focusElement(id: elementId)
                    if !focusResult.success { return mapActionResult(focusResult) }
                    if replace {
                        // Best-effort clear; some fields aren't AX-clearable, in which
                        // case typing simply appends.
                        _ = ElementInteraction.shared.clearElement(id: elementId)
                    }
                }

                let result: InputResult
                if let pid = resolvedPid {
                    result = BackgroundDriver.shared.type(pid: pid, text: text)
                } else {
                    result = KeyboardController.shared.type(text: text)
                }
                if result.success {
                    let delta = resolvedPid.flatMap { computeFocusDelta(pid: $0) }
                    return CUActionResult.ok(
                        delta: delta.map(mapDelta),
                        routeUsed: inputRoute(pidAddressed: resolvedPid != nil)
                    )
                }
                return .failure(result.error ?? "Type failed")

            case let .pressKey(pid, key, modifiers):
                let flags = parseModifierFlags(modifiers)
                let resolvedPid = pid ?? AccessibilityManager.shared.mostRecentPid()
                let result: InputResult
                if let pid = resolvedPid, let code = keyCode(for: key) {
                    result = BackgroundDriver.shared.pressKey(pid: pid, keyCode: code, modifiers: flags)
                } else {
                    result = KeyboardController.shared.pressKey(keyName: key, modifiers: flags)
                }
                if result.success {
                    let delta = resolvedPid.flatMap { computeFocusDelta(pid: $0) }
                    return CUActionResult.ok(
                        delta: delta.map(mapDelta),
                        routeUsed: inputRoute(pidAddressed: resolvedPid != nil)
                    )
                }
                return .failure(result.error ?? "Press key failed")
            }
        }
    }

    // MARK: Act — coordinate-addressed

    public func coordinate(_ action: CUCoordinateAction) async -> CUActionResult {
        await AccessibilityManager.runOffMain {
            switch action {
            case let .click(x, y, button, doubleClick, pid):
                let point = CGPoint(x: x, y: y)
                let mb = mapButton(button)
                let result: InputResult
                if let pid {
                    result =
                        doubleClick
                        ? BackgroundDriver.shared.doubleClick(pid: pid, point: point, button: mb)
                        : BackgroundDriver.shared.click(pid: pid, point: point, button: mb)
                } else {
                    result =
                        doubleClick
                        ? MouseController.shared.doubleClick(at: point, button: mb)
                        : MouseController.shared.click(at: point, button: mb)
                }
                return mapInputResult(result, routeUsed: inputRoute(pidAddressed: pid != nil))

            case let .scroll(direction, amount, x, y, pid):
                let dir = mapScroll(direction)
                if let pid {
                    return mapInputResult(
                        BackgroundDriver.shared.scroll(pid: pid, direction: dir, amount: amount),
                        routeUsed: inputRoute(pidAddressed: true)
                    )
                }
                if let x, let y { _ = MouseController.shared.moveTo(CGPoint(x: x, y: y)) }
                return mapInputResult(
                    MouseController.shared.scroll(direction: dir, amount: amount),
                    routeUsed: inputRoute(pidAddressed: false)
                )

            case let .drag(startX, startY, endX, endY, pid):
                let start = CGPoint(x: startX, y: startY)
                let end = CGPoint(x: endX, y: endY)
                if let pid {
                    return mapInputResult(
                        BackgroundDriver.shared.drag(pid: pid, from: start, to: end),
                        routeUsed: inputRoute(pidAddressed: true)
                    )
                }
                return mapInputResult(
                    MouseController.shared.drag(from: start, to: end),
                    routeUsed: inputRoute(pidAddressed: false)
                )
            }
        }
    }

    // MARK: Screenshot

    public func screenshot(pid: Int32?, windowId: Int?, annotate: Bool) async -> CUImage? {
        var opts = ScreenshotOptions()
        opts.pid = pid
        if let windowId { opts.windowId = CGWindowID(windowId) }
        opts.annotate = annotate
        guard let captured = await ScreenshotController.shared.capture(options: opts) else {
            return nil
        }
        return mapImage(captured)
    }

    // MARK: Narrate

    public func narrate(_ note: String, step: Int?, total: Int?) async {
        await MainActor.run {
            if AutomationSession.shared.isActive() {
                AutomationSession.shared.updateSession(narration: note, stepIndex: step, totalSteps: total)
            } else {
                AutomationSession.shared.startSession(
                    title: note,
                    totalSteps: total,
                    narration: note
                )
            }
        }
    }
}

// MARK: - Mapping helpers (driver → contract)

private func mapSnapshot(
    _ t: TraversalResult,
    tier: CaptureTier,
    image: CUImage?
) -> CUSnapshot {
    CUSnapshot(
        snapshotId: t.snapshotId,
        pid: t.pid,
        app: t.app,
        focusedWindow: t.focusedWindow,
        tier: tier,
        truncated: t.truncated,
        windows: t.windows.map {
            CUWindowSummary(id: $0.id, title: $0.title, focused: $0.focused, x: $0.x, y: $0.y, w: $0.w, h: $0.h)
        },
        elements: t.elements.map {
            CUElement(
                id: $0.id,
                role: $0.role,
                roleDescription: $0.roleDescription,
                label: $0.label,
                value: $0.value,
                selectedText: $0.selectedText,
                placeholder: $0.placeholder,
                path: $0.path,
                windowId: $0.windowId,
                focused: $0.focused,
                enabled: $0.enabled,
                x: $0.x,
                y: $0.y,
                w: $0.w,
                h: $0.h,
                actions: $0.actions
            )
        },
        image: image
    )
}

private func mapImage(_ c: CapturedImage) -> CUImage {
    CUImage(base64: c.base64, mimeType: c.mimeType, width: c.width, height: c.height)
}

private func mapDelta(_ d: FocusDelta) -> CUFocusDelta {
    CUFocusDelta(
        focusedWindow: d.focusedWindow,
        focusedElement: d.focusedElement.map {
            CUFocusedElement(role: $0.role, label: $0.label, value: $0.value)
        }
    )
}

private func mapActionResult(_ r: ElementActionResult) -> CUActionResult {
    CUActionResult(
        success: r.success,
        error: r.error,
        stale: r.stale ?? false,
        removed: r.removed ?? false,
        delta: r.delta.map(mapDelta)
    )
}

private func mapInputResult(_ r: InputResult, routeUsed: InputRoute? = nil) -> CUActionResult {
    CUActionResult(success: r.success, error: r.error, routeUsed: routeUsed)
}

/// The transport an input action used: `BackgroundDriver`'s last route when the
/// action was pid-addressed (backgrounded), else `.hidFallback` because the
/// no-pid `MouseController`/`KeyboardController` paths post via the HID tap and
/// warp the cursor.
private func inputRoute(pidAddressed: Bool) -> InputRoute {
    pidAddressed ? BackgroundDriver.shared.lastRoute : .hidFallback
}

private func mapButton(_ b: CUMouseButton) -> MouseButton {
    switch b {
    case .left: return .left
    case .right: return .right
    case .center: return .center
    }
}

private func mapScroll(_ d: CUScrollDirection) -> ScrollDirection {
    switch d {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    }
}
