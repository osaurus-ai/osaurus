//
//  KeyboardSimulationService.swift
//  osaurus
//
//  Service for simulating keyboard input using CGEventPost.
//  Requires accessibility permission (AXIsProcessTrusted).
//  Used by Transcription Mode to type text into focused text fields.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Service for simulating keyboard input into the currently focused text field
@MainActor
public final class KeyboardSimulationService: ObservableObject {
    public static let shared = KeyboardSimulationService()

    /// Whether accessibility permission is granted
    @Published public private(set) var hasAccessibilityPermission: Bool = false

    private init() {
        checkAccessibilityPermission()
    }

    // MARK: - Permission Checking

    /// Check if accessibility permission is granted
    public func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    /// Request accessibility permission (shows system prompt if not granted)
    public func requestAccessibilityPermission() {
        // Use the string value directly to avoid concurrency issues with the global constant
        // kAXTrustedCheckOptionPrompt's value is "AXTrustedCheckOptionPrompt"
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)

        // Re-check after a delay (user may grant permission)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            checkAccessibilityPermission()
        }
    }

    /// Open System Preferences to the Accessibility pane
    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Text Typing

    /// Type the given text into the currently focused text field
    /// - Parameter text: The text to type
    /// - Returns: True if typing was successful
    @discardableResult
    public func typeText(_ text: String) -> Bool {
        guard hasAccessibilityPermission else {
            print("[KeyboardSimulationService] Cannot type: accessibility permission not granted")
            return false
        }

        guard !text.isEmpty else {
            return true
        }

        // Type each character
        for char in text {
            typeCharacter(char)
            // Small delay between characters for reliability
            usleep(1000)  // 1ms
        }

        return true
    }

    /// Type backspace characters to delete text
    /// - Parameter count: Number of characters to delete
    @discardableResult
    public func typeBackspace(count: Int) -> Bool {
        guard hasAccessibilityPermission else {
            print("[KeyboardSimulationService] Cannot type backspace: accessibility permission not granted")
            return false
        }

        for _ in 0 ..< count {
            typeKeyCode(UInt16(kVK_Delete))
            usleep(1000)  // 1ms
        }

        return true
    }

    // MARK: - Private Helpers

    /// Type a single character using CGEventPost
    private func typeCharacter(_ char: Character) {
        let str = String(char)

        // Use Unicode input method for reliability
        // This handles special characters, accents, emoji, etc.
        for scalar in str.unicodeScalars {
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)

            guard let keyDown = keyDown, let keyUp = keyUp else {
                continue
            }

            // Set the Unicode character
            var unicodeChar = UniChar(scalar.value)
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicodeChar)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicodeChar)

            // Post the events
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// Type a specific key code (for special keys like backspace)
    private func typeKeyCode(_ keyCode: UInt16, modifiers: CGEventFlags = []) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            return
        }

        keyDown.flags = modifiers
        keyUp.flags = modifiers

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
