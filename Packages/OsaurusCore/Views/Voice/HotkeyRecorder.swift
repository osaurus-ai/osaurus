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
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(9, enabled: baseComponentEnabled) }

    var body: some View {
        HStack(spacing: theme.space.s8) {
            if isRecording {
                Text("Recording… Press new shortcut", bundle: .module)
                    .assignedTypography("component.library.9.caption", fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .padding(.horizontal, theme.space.s0).padding(.vertical, theme.space.s0)
                    .frame(minHeight: theme.catalogMetric("height", fallback: 0))
                    .assignedBaseChrome(9, fallback: nil, selected: true)
                    .assignedBaseFocusRing(9, visible: baseComponentEnabled, radius: theme.catalogMetric("radius", fallback: 8), keyboardOnly: false)
                SettingsButton(.secondary, "Cancel", size: .compact) {
                    isRecording = false
                }
            } else {
                Text(display(for: value))
                    .lineLimit(1)
                    .assignedTypography("component.library.9.label", fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                    .padding(.vertical, theme.space.s4)
                    .padding(.horizontal, theme.space.s8)
                    .frame(minHeight: theme.controlSize.compactHeight)
                    .settingsChrome(.inset)
                SettingsButton(.secondary, "Change…", size: .compact) {
                    isRecording = true
                }
                if value != nil {
                    SettingsButton(.tertiary, "Clear", size: .compact) {
                        value = nil
                    }
                }
            }
        }
        .fixedSize()
        .background(
            RecordingCatcher(
                isRecording: $isRecording,
                onCapture: { event in
                    guard isRecording && baseComponentEnabled else { return }
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
        .onChange(of: baseComponentEnabled) { _, enabled in
            if !enabled { isRecording = false }
        }
        .onDisappear { isRecording = false }
    }

    private func display(for hotkey: Hotkey?) -> String {
        guard let hotkey else { return L("Not set") }
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
        HotkeyText.label(forKeyCode: Int(keyCode))
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

    static func dismantleNSView(_ nsView: EventCatcherView, coordinator: ()) {
        nsView.isRecording = false
        nsView.updateMonitor()
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
