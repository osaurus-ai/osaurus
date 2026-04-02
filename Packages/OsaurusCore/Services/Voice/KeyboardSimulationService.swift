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
        // run check in background to avoid blocking main thread
        Task.detached(priority: .utility) {
            let granted = AXIsProcessTrusted()
            await MainActor.run {
                if self.hasAccessibilityPermission != granted {
                    self.hasAccessibilityPermission = granted
                }
            }
        }
    }

    /// Request accessibility permission (shows system prompt if not granted)
    public func requestAccessibilityPermission() {
        // use the string value directly to avoid concurrency issues with the global constant
        // kAXTrustedCheckOptionPrompt's value is "AXTrustedCheckOptionPrompt"
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)

        // re-check after a delay (user may grant permission)
        Task {
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
        let currentlyTrusted = AXIsProcessTrusted()
        if currentlyTrusted != hasAccessibilityPermission {
            hasAccessibilityPermission = currentlyTrusted
        }

        guard currentlyTrusted else {
            print("[KeyboardSimulationService] Cannot type: accessibility permission not granted")
            return false
        }

        guard !text.isEmpty else {
            return true
        }

        // use a Task to allow non-blocking sleep. Since we are @MainActor,
        // this stays on the main thread but yields during sleep.
        Task {
            for char in text {
                Self.typeCharacter(char)
                try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
            }
        }

        return true
    }

    /// Type backspace characters to delete text
    /// - Parameter count: Number of characters to delete
    @discardableResult
    public func typeBackspace(count: Int) -> Bool {
        let currentlyTrusted = AXIsProcessTrusted()
        if currentlyTrusted != hasAccessibilityPermission {
            hasAccessibilityPermission = currentlyTrusted
        }

        guard currentlyTrusted else {
            print("[KeyboardSimulationService] Cannot type backspace: accessibility permission not granted")
            return false
        }

        Task {
            for _ in 0 ..< count {
                Self.typeKeyCode(UInt16(kVK_Delete))
                try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
            }
        }

        return true
    }

    // MARK: - Clipboard Copy

    /// Simulate Cmd+C to copy the current selection in the active application
    /// - Returns: True if the command was posted
    @discardableResult
    public func copySelection() -> Bool {
        guard hasAccessibilityPermission else {
            print("[KeyboardSimulationService] Cannot copy: accessibility permission not granted")
            checkAccessibilityPermission()
            return false
        }

        print("[KeyboardSimulationService] Posting Cmd+C event...")
        Self.typeKeyCode(UInt16(kVK_ANSI_C), modifiers: .maskCommand)
        return true
    }

    // MARK: - Clipboard Paste

    /// Paste the given text into the currently focused text field via clipboard
    @discardableResult
    public func pasteText(_ text: String, restoreClipboard: Bool = true) -> Bool {
        // use cached permission to avoid blocking main thread
        guard hasAccessibilityPermission else {
            print(
                "[KeyboardSimulationService] Cannot paste: accessibility permission not granted (using cached status)"
            )
            // trigger a refresh for the next time
            checkAccessibilityPermission()
            return false
        }

        guard !text.isEmpty else {
            return true
        }

        // entire clipboard operation moved to background to prevent main-thread hangs
        Task.detached(priority: .userInitiated) {
            let pb = NSPasteboard.general

            var backup: [[String: Data]] = []
            if restoreClipboard {
                for item in pb.pasteboardItems ?? [] {
                    var itemData: [String: Data] = [:]
                    for type in item.types {
                        if let data = item.data(forType: type) {
                            itemData[type.rawValue] = data
                        }
                    }
                    backup.append(itemData)
                }
            }

            // clear and Set
            pb.clearContents()
            pb.setString(text, forType: .string)

            // trigger Cmd+V
            // 50ms buffer for OS to register clipboard
            try? await Task.sleep(nanoseconds: 50_000_000)
            Self.typeKeyCode(UInt16(kVK_ANSI_V), modifiers: .maskCommand)

            if restoreClipboard && !backup.isEmpty {
                // longer delay to ensure target app pasted
                try? await Task.sleep(nanoseconds: 400_000_000)
                pb.clearContents()
                for itemData in backup {
                    let newItem = NSPasteboardItem()
                    for (type, data) in itemData {
                        newItem.setData(data, forType: NSPasteboard.PasteboardType(type))
                    }
                    pb.writeObjects([newItem])
                }
            }
        }

        return true
    }

    // MARK: - Private Helpers

    /// Type a single character using CGEventPost
    nonisolated private static func typeCharacter(_ char: Character) {
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
    nonisolated private static func typeKeyCode(_ keyCode: UInt16, modifiers: CGEventFlags = []) {
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
