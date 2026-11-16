//
//  HotkeyText.swift
//  osaurus
//
//  Text form of the global hotkey (`cmd+shift+o`), used by the declarative
//  `app.hotkey` key. The key table also supplies `HotkeyRecorder`'s fallback
//  labels, so a typed hotkey and a recorded one display the same way.
//

import Carbon.HIToolbox
import Foundation

public enum HotkeyText {
    struct Key: Sendable {
        /// Accepted spellings; the first is the one exports write.
        let names: [String]
        let code: Int
        let label: String
    }

    static let keys: [Key] = {
        var keys: [Key] = []
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
            ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
        ]
        keys += letters.map { Key(names: [$0.0], code: $0.1, label: $0.0.uppercased()) }
        let digits: [Int] = [
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]
        keys += digits.enumerated().map { Key(names: ["\($0.offset)"], code: $0.element, label: "\($0.offset)") }
        keys += [
            Key(names: ["`", "grave", "backtick"], code: kVK_ANSI_Grave, label: "`"),
            Key(names: ["-", "minus"], code: kVK_ANSI_Minus, label: "-"),
            Key(names: ["=", "equal", "equals"], code: kVK_ANSI_Equal, label: "="),
            Key(names: ["[", "leftbracket"], code: kVK_ANSI_LeftBracket, label: "["),
            Key(names: ["]", "rightbracket"], code: kVK_ANSI_RightBracket, label: "]"),
            Key(names: ["\\", "backslash"], code: kVK_ANSI_Backslash, label: "\\"),
            Key(names: [";", "semicolon"], code: kVK_ANSI_Semicolon, label: ";"),
            Key(names: ["'", "quote"], code: kVK_ANSI_Quote, label: "'"),
            Key(names: [",", "comma"], code: kVK_ANSI_Comma, label: ","),
            Key(names: [".", "period"], code: kVK_ANSI_Period, label: "."),
            Key(names: ["/", "slash"], code: kVK_ANSI_Slash, label: "/"),
            Key(names: ["space"], code: kVK_Space, label: "Space"),
            Key(names: ["return", "enter"], code: kVK_Return, label: "⏎"),
            Key(names: ["tab"], code: kVK_Tab, label: "⇥"),
            Key(names: ["delete", "backspace"], code: kVK_Delete, label: "⌫"),
            Key(names: ["up"], code: kVK_UpArrow, label: "↑"),
            Key(names: ["down"], code: kVK_DownArrow, label: "↓"),
            Key(names: ["left"], code: kVK_LeftArrow, label: "←"),
            Key(names: ["right"], code: kVK_RightArrow, label: "→"),
        ]
        let functionKeys: [Int] = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ]
        keys += functionKeys.enumerated().map {
            Key(names: ["f\($0.offset + 1)"], code: $0.element, label: "F\($0.offset + 1)")
        }
        return keys
    }()

    private struct Modifier {
        let names: [String]
        let glyph: Character
        let mask: UInt32
    }

    /// Display order, matching `HotkeyRecorder`: ⌘ ⇧ ⌥ ⌃.
    private static let modifiers: [Modifier] = [
        Modifier(names: ["cmd", "command"], glyph: "⌘", mask: UInt32(cmdKey)),
        Modifier(names: ["shift"], glyph: "⇧", mask: UInt32(shiftKey)),
        Modifier(names: ["option", "opt", "alt"], glyph: "⌥", mask: UInt32(optionKey)),
        Modifier(names: ["ctrl", "control"], glyph: "⌃", mask: UInt32(controlKey)),
    ]

    static func label(forKeyCode code: Int) -> String? {
        keys.first { $0.code == code }?.label
    }

    /// Parses `cmd+shift+o`, `option+space`, or the glyph form `⌘⇧O`.
    /// Returns the hotkey or a message naming what is wrong.
    public static func parse(_ raw: String) -> Result<Hotkey, ParseError> {
        var rest = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        var mask: UInt32 = 0
        while let first = rest.first, let modifier = modifiers.first(where: { $0.glyph == first }) {
            mask |= modifier.mask
            rest = rest.dropFirst()
        }
        var parts = rest.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.popLast(), !keyName.isEmpty else {
            return .failure(ParseError("`\(raw)` has no key. Write it like cmd+shift+o."))
        }
        for part in parts {
            guard let modifier = modifiers.first(where: { $0.names.contains(part) }) else {
                return .failure(
                    ParseError("`\(part)` is not a modifier. Use cmd, shift, option, or ctrl."))
            }
            mask |= modifier.mask
        }
        guard let key = keys.first(where: { $0.names.contains(keyName) }) else {
            return .failure(
                ParseError(
                    "`\(keyName)` is not a supported key. Use a letter, digit, punctuation, "
                        + "space, return, tab, delete, an arrow, or f1…f12."))
        }
        let typingModifiers = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        guard mask & typingModifiers != 0 else {
            return .failure(
                ParseError("`\(raw)` needs cmd, option, or ctrl, or it would capture normal typing."))
        }
        let glyphs = modifiers.filter { mask & $0.mask != 0 }.map { String($0.glyph) }.joined()
        return .success(
            Hotkey(keyCode: UInt32(key.code), carbonModifiers: mask, displayString: glyphs + key.label))
    }

    /// `cmd+shift+o` form for export. A key outside the table (recorded on
    /// another keyboard layout) falls back to its display string.
    public static func text(for hotkey: Hotkey) -> String {
        guard let key = keys.first(where: { $0.code == Int(hotkey.keyCode) }) else {
            return hotkey.displayString
        }
        let names = modifiers.filter { hotkey.carbonModifiers & $0.mask != 0 }.map { $0.names[0] }
        return (names + [key.names[0]]).joined(separator: "+")
    }

    public struct ParseError: Error, Equatable, Sendable {
        public let message: String
        init(_ message: String) { self.message = message }
    }
}
