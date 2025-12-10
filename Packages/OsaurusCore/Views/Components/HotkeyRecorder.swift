//
//  HotkeyRecorder.swift
//  osaurus
//
//  A small SwiftUI control to record a global hotkey (key + modifiers).
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var value: Hotkey?
    @State private var isRecording: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if isRecording {
                Text("Recording… Press new shortcut")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                Button("Cancel") { isRecording = false }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .buttonStyle(.plain)
            } else {
                Text(display(for: value))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                Button("Change…") { isRecording = true }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .buttonStyle(.plain)
                if value != nil {
                    Button("Clear") { value = nil }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .buttonStyle(.plain)
                }
            }
        }
        .background(
            RecordingCatcher(
                isRecording: $isRecording,
                onCapture: { event in
                    guard isRecording else { return }
                    if event.keyCode == kVK_Escape {
                        isRecording = false
                        return
                    }
                    // Ignore modifier-only presses
                    let isModifierOnly =
                        event.keyCode == kVK_Shift || event.keyCode == kVK_Command
                        || event.keyCode == kVK_Option
                        || event.keyCode == kVK_Control
                    if isModifierOnly { return }
                    let mods = carbonModifiers(from: event.modifierFlags)
                    let display = displayString(keyCode: event.keyCode, modifiers: mods)
                    value = Hotkey(
                        keyCode: UInt32(event.keyCode),
                        carbonModifiers: mods,
                        displayString: display
                    )
                    isRecording = false
                }
            )
        )
    }

    private func display(for hotkey: Hotkey?) -> String {
        guard let hotkey else { return "Not set" }
        return hotkey.displayString
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    private func displayString(keyCode: UInt16, modifiers: UInt32) -> String {
        var parts: [String] = []
        if (modifiers & UInt32(cmdKey)) != 0 { parts.append("⌘") }
        if (modifiers & UInt32(shiftKey)) != 0 { parts.append("⇧") }
        if (modifiers & UInt32(optionKey)) != 0 { parts.append("⌥") }
        if (modifiers & UInt32(controlKey)) != 0 { parts.append("⌃") }
        let localized = localizedKeyString(for: keyCode)
        let label = normalizedDisplay(from: localized) ?? keyGlyph(for: keyCode) ?? "?"
        parts.append(label)
        return parts.joined()
    }

    // Produce a display-friendly label from a raw localized string
    private func normalizedDisplay(from raw: String?) -> String? {
        guard let s = raw, !s.isEmpty else { return nil }
        switch s {
        case " ": return "Space"
        case "\t": return "⇥"
        case "\r", "\n": return "⏎"
        default:
            break
        }
        // Prefer uppercase single-letter for readability
        if s.count == 1 { return s.uppercased() }
        return s
    }

    // Resolve the character produced by a virtual key code in the current keyboard layout
    private func localizedKeyString(for keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let prop = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = unsafeBitCast(prop, to: CFData.self)
        guard let ptr = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(ptr))
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength: Int = 0
        let keyboardType = UInt32(LMGetKbdType())
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &actualLength,
            &chars
        )
        if status == noErr && actualLength > 0 {
            return String(utf16CodeUnits: chars, count: actualLength)
        }
        return nil
    }

    private func keyGlyph(for keyCode: UInt16) -> String? {
        let code = Int(keyCode)
        switch code {
        // Letters (ANSI - explicit mapping; key codes are non-contiguous)
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"

        // Number row
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"

        // Punctuation
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"

        // Navigation / control
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Escape: return "⎋"
        case kVK_Return: return "⏎"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Space: return "Space"

        // Function keys (explicit common ones)
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return nil
        }
    }
}

// Invisible event catcher while recording
private struct RecordingCatcher: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (NSEvent) -> Void

    func makeNSView(context: Context) -> EventCatcherView {
        let view = EventCatcherView()
        view.onCapture = onCapture
        view.isRecording = isRecording
        view.updateMonitor()
        return view
    }

    func updateNSView(_ nsView: EventCatcherView, context: Context) {
        nsView.onCapture = onCapture
        if nsView.isRecording != isRecording {
            nsView.isRecording = isRecording
            nsView.updateMonitor()
        }
    }

    final class EventCatcherView: NSView {
        var onCapture: ((NSEvent) -> Void)?
        var isRecording: Bool = false
        private var localToken: Any?
        private var globalToken: Any?

        override var acceptsFirstResponder: Bool { true }

        func updateMonitor() {
            if isRecording {
                if window != nil { window?.makeFirstResponder(self) }
                if localToken == nil {
                    localToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                        guard let self else { return event }
                        self.onCapture?(event)
                        return nil
                    }
                }
                if globalToken == nil {
                    globalToken = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                        self?.onCapture?(event)
                    }
                }
            } else {
                if let t = localToken {
                    NSEvent.removeMonitor(t)
                    localToken = nil
                }
                if let t = globalToken {
                    NSEvent.removeMonitor(t)
                    globalToken = nil
                }
            }
        }

    }
}
