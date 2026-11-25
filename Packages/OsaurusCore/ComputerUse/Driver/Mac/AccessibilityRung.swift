//
//  AccessibilityRung.swift
//  OsaurusCore — Computer Use
//
//  Accessibility actions tried before any synthesized event: inserting text
//  at the caret, picking popup and menu options, and stepping sliders. Each either completes through AX (no
//  event posted, nothing for the user's input to collide with) or reports
//  false so the caller falls back to per-pid events.
//
//  Key equivalents are not pressed as menu items: a background app's menu
//  keeps its last validation (Undo reads disabled after an edit) and AXPress
//  returns success on a disabled item while doing nothing, so neither the
//  enabled flag nor the press result proves anything there.
//

import ApplicationServices
import Foundation

// MARK: - Text insertion

enum AXTextInsertion {
    /// Text the AX path can insert faithfully. Newlines and tabs are left to
    /// key events because they act as keys (submit, next field) in most
    /// fields; Chromium web content is left to key events because setting AX
    /// text there does not reliably fire the page's input handlers.
    static func isEligible(text: String, isChromium: Bool) -> Bool {
        guard !isChromium, !text.isEmpty else { return false }
        return !text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" })
    }

    /// Whether a read-back proves the insertion landed.
    static func landed(before: String?, after: String?, text: String) -> Bool {
        guard let after, after != before else { return false }
        return after.contains(text)
    }

    /// Replace the selection (or insert at the caret) of `element` with
    /// `text` through `AXSelectedText`, then read the value back.
    static func insert(_ text: String, into element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { return false }
        let before = stringValue(of: element)
        guard
            AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
                == .success
        else { return false }
        return landed(before: before, after: stringValue(of: element), text: text)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}

// MARK: - Adjustable controls

enum AXAdjustment {
    static let increment = "AXIncrement"
    static let decrement = "AXDecrement"
    static let maxSteps = 20

    /// The AX action a scroll direction maps to on a slider or stepper.
    static func action(for direction: CUScrollDirection) -> String {
        switch direction {
        case .up, .right: return increment
        case .down, .left: return decrement
        }
    }

    static func supports(_ actions: [String]) -> Bool {
        actions.contains(increment) && actions.contains(decrement)
    }
}

// MARK: - Popup and menu options

enum AXOptionPicker {
    /// How long to wait for an opened popup's menu to appear.
    static let menuWaitSeconds: TimeInterval = 1.0

    /// The index of the title `option` names: an exact (case-insensitive)
    /// match, else the only title starting with it, else the only title
    /// containing it. Ambiguity is nil, never a guess.
    static func match(_ option: String, in titles: [String]) -> Int? {
        let want = normalized(option)
        guard !want.isEmpty else { return nil }
        let have = titles.map(normalized)
        if let exact = have.firstIndex(of: want) { return exact }
        let prefixed = have.indices.filter { have[$0].hasPrefix(want) }
        if prefixed.count == 1 { return prefixed[0] }
        let containing = have.indices.filter { have[$0].contains(want) }
        return containing.count == 1 ? containing[0] : nil
    }

    static func isComboBox(role: String) -> Bool {
        role.lowercased().contains("combobox")
    }

    /// How long to wait for a popup to show the picked option.
    static let readBackSeconds: TimeInterval = 0.6

    /// Enabled menu items under `element` (an opened popup or menu button),
    /// up to a few levels down, with their titles. Disabled items (section
    /// headers like "Recently Used") accept AXPress and do nothing.
    static func menuItems(under element: AXUIElement) -> [(item: AXUIElement, title: String)] {
        var found: [(AXUIElement, String)] = []
        func walk(_ node: AXUIElement, depth: Int) {
            guard depth < 4 else { return }
            for child in children(of: node) {
                let role = string(child, kAXRoleAttribute) ?? ""
                if role == (kAXMenuItemRole as String) {
                    let title = string(child, kAXTitleAttribute) ?? ""
                    if !title.isEmpty, bool(child, kAXEnabledAttribute) != false { found.append((child, title)) }
                } else {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(element, depth: 0)
        return found
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
            let list = value as? [AXUIElement]
        else { return [] }
        return list
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Whether `shown` (a popup's value after the press) is `title`.
    static func shows(_ shown: String?, title: String) -> Bool {
        guard let shown else { return false }
        return normalized(shown) == normalized(title)
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
