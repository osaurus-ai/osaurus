//
//  ElementCache.swift
//  OsaurusCore — Computer Use
//
//  Native macOS driver, brought in-core from osaurus-ai/osaurus-macos-use.
//  High-level element interaction (click / set value / type / clear) over the
//  snapshot-scoped element cache, with AX-action-first, input-fallback routing.
//

import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Element Action Result

/// Result of an action on a cached element. Carries enough info for the agent
/// to decide whether to re-observe or give up.
struct ElementActionResult: Codable {
    let success: Bool
    let error: String?
    /// True when the failure is because the id refers to a snapshot we no longer
    /// remember. Caller should re-observe and retry with the fresh id, not
    /// abandon the goal.
    let stale: Bool?
    /// True when the id was well-formed but the element no longer exists (UI
    /// changed). Caller should re-observe and find a new element.
    let removed: Bool?
    /// Retained for response-shape stability; never set on the input path.
    let cancelled: Bool?
    /// A small "what changed" record for successful actions on a known pid.
    let delta: FocusDelta?

    static func ok(delta: FocusDelta? = nil) -> ElementActionResult {
        return ElementActionResult(
            success: true,
            error: nil,
            stale: nil,
            removed: nil,
            cancelled: nil,
            delta: delta
        )
    }

    static func fail(_ message: String) -> ElementActionResult {
        return ElementActionResult(
            success: false,
            error: message,
            stale: nil,
            removed: nil,
            cancelled: nil,
            delta: nil
        )
    }

    static func stale(requested: Int, current: Int) -> ElementActionResult {
        let msg =
            "Element id is from snapshot s\(requested) but the current snapshot is s\(current). "
            + "Call get_ui_elements (or find_elements) again, then retry with the fresh id."
        return ElementActionResult(
            success: false,
            error: msg,
            stale: true,
            removed: nil,
            cancelled: nil,
            delta: nil
        )
    }

    static func removed(_ id: String) -> ElementActionResult {
        let msg =
            "Element \(id) no longer exists in the UI (it may have been removed, or the view changed). "
            + "Re-observe to find the current element."
        return ElementActionResult(
            success: false,
            error: msg,
            stale: nil,
            removed: true,
            cancelled: nil,
            delta: nil
        )
    }

    static func malformed(_ id: String) -> ElementActionResult {
        return .fail(
            "Element id '\(id)' is not a valid snapshot id. Expected format 's<snapshot>-<n>' "
                + "as returned by get_ui_elements or find_elements."
        )
    }
}

// MARK: - Lookup Helper

/// Either a usable element or a pre-built failure result for the agent.
private enum ResolveOutcome {
    case ok(CachedElement)
    case failure(ElementActionResult)
}

private func resolve(id: String) -> ResolveOutcome {
    switch AccessibilityManager.shared.lookup(id: id) {
    case .found(let element):
        return .ok(element)
    case .stale(let requested, let current):
        return .failure(.stale(requested: requested, current: current))
    case .removed(let id):
        return .failure(.removed(id))
    case .malformed(let id):
        return .failure(.malformed(id))
    }
}

// MARK: - Element Interaction

/// High-level API for interacting with cached elements.
/// Uses AX actions when available, falls back to coordinate input.
final class ElementInteraction: @unchecked Sendable {
    static let shared = ElementInteraction()

    private let driver = BackgroundDriver.shared

    private init() {}

    /// Click an element by id. Tries AXPress first (fully backgrounded),
    /// then a per-pid SkyLight click at the element's center, and finally
    /// the HID-tap path that warps the cursor (only happens when both
    /// SkyLight and `CGEvent.postToPid` are unavailable).
    func clickElement(id: String) -> ElementActionResult {
        switch resolve(id: id) {
        case .failure(let err): return err
        case .ok(let element):
            if element.supportsAction("AXPress") && element.performAction("AXPress") {
                return .ok(delta: computeFocusDelta(pid: element.pid))
            }
            guard let frame = element.getCurrentFrame() else {
                return .removed(id)
            }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let result = driver.click(pid: element.pid, point: center)
            if result.success {
                return .ok(delta: computeFocusDelta(pid: element.pid))
            }
            return .fail(result.error ?? "Click failed")
        }
    }

    func doubleClickElement(id: String) -> ElementActionResult {
        switch resolve(id: id) {
        case .failure(let err): return err
        case .ok(let element):
            guard let frame = element.getCurrentFrame() else { return .removed(id) }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let result = driver.doubleClick(pid: element.pid, point: center)
            if result.success {
                return .ok(delta: computeFocusDelta(pid: element.pid))
            }
            return .fail(result.error ?? "Double click failed")
        }
    }

    /// Focus an element by ID (for text fields).
    func focusElement(id: String) -> ElementActionResult {
        switch resolve(id: id) {
        case .failure(let err): return err
        case .ok(let element):
            let result = AXUIElementSetAttributeValue(
                element.axElement,
                kAXFocusedAttribute as CFString,
                true as CFTypeRef
            )
            if result == .success { return .ok() }
            return clickElement(id: id)
        }
    }

    func rightClickElement(id: String) -> ElementActionResult {
        switch resolve(id: id) {
        case .failure(let err): return err
        case .ok(let element):
            if element.supportsAction("AXShowMenu") && element.performAction("AXShowMenu") {
                return .ok(delta: computeFocusDelta(pid: element.pid))
            }
            guard let frame = element.getCurrentFrame() else { return .removed(id) }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let result = driver.click(pid: element.pid, point: center, button: .right)
            if result.success {
                // Heads-up: Chromium coerces synthetic right-clicks on web content
                // to left-clicks at the renderer-IPC boundary. AXShowMenu above is
                // the only reliable right-click path for those targets.
                return .ok(delta: computeFocusDelta(pid: element.pid))
            }
            return .fail(result.error ?? "Right click failed")
        }
    }

    /// Get the current text value of an element (raw, without affecting cache).
    func getElementValue(id: String) -> String? {
        guard case .found(let element) = AccessibilityManager.shared.lookup(id: id) else {
            return nil
        }
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element.axElement,
            kAXValueAttribute as CFString,
            &valueRef
        )
        if result == .success, let value = valueRef as? String { return value }
        return nil
    }

    /// Set the text value of an element. Preferred for forms.
    func setElementValue(id: String, value: String) -> ElementActionResult {
        switch resolve(id: id) {
        case .failure(let err): return err
        case .ok(let element):
            let result = AXUIElementSetAttributeValue(
                element.axElement,
                kAXValueAttribute as CFString,
                value as CFTypeRef
            )
            if result == .success {
                return .ok(delta: computeFocusDelta(pid: element.pid))
            }
            return .fail(
                "Failed to set element value. Element may not be editable. "
                    + "Try type_text with the element id (which focuses first) as a fallback."
            )
        }
    }

    /// Clear an element's value.
    /// Tries set_value("") first; falls back to focus + Cmd+A + delete.
    func clearElement(id: String) -> ElementActionResult {
        switch resolve(id: id) {
        case .failure(let err): return err
        case .ok(let element):
            let result = AXUIElementSetAttributeValue(
                element.axElement,
                kAXValueAttribute as CFString,
                "" as CFTypeRef
            )
            if result == .success {
                return .ok(delta: computeFocusDelta(pid: element.pid))
            }
            // Fallback: focus, select all, delete — routed per-pid so other
            // apps don't see the Cmd+A.
            let focusResult = focusElement(id: id)
            if !focusResult.success { return focusResult }
            if let aCode = keyCode(for: "a") {
                _ = driver.pressKey(pid: element.pid, keyCode: aCode, modifiers: .maskCommand)
            }
            guard let delCode = keyCode(for: "delete") else {
                return .fail("Failed to clear field: no delete key code available")
            }
            let del = driver.pressKey(pid: element.pid, keyCode: delCode, modifiers: [])
            if del.success {
                return .ok(delta: computeFocusDelta(pid: element.pid))
            }
            return .fail(del.error ?? "Failed to clear field")
        }
    }
}
