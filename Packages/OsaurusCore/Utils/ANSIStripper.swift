//
//  ANSIStripper.swift
//  osaurus
//
//  Drop ANSI escape sequences (SGR colors, cursor moves, alternate-
//  screen toggles) from terminal output before rendering it in the
//  chat UI. Best-effort — not a vt100 emulator. Used by
//  `TerminalDisplayView` so a `claude` REPL or coloured `cargo build`
//  reads as plain text in
//  the chat instead of being littered with `\u{1B}[...m` markers.
//
//  Coverage:
//    - CSI sequences:  ESC `[` <params> <intermediate>* <final ASCII byte>
//      (covers SGR `m`, cursor moves `H A B C D J K f`, etc.).
//    - Single-char escapes: ESC <byte in 0x40..0x5F>
//      (covers `ESC c` reset, `ESC 7` save cursor, etc.).
//    - OSC sequences: ESC `]` ... BEL or ESC `\`.
//      (terminal title sets, hyperlinks).
//    - Lone bell / shift-out / shift-in: dropped silently.
//
//  Anything that isn't an escape sequence flows through untouched.
//

import Foundation

public enum ANSIStripper {

    /// Strip ANSI escape sequences from `input`, returning the visible
    /// text. Does NOT trim whitespace or rewrite line endings.
    public static func strip(_ input: String) -> String {
        // Fast-path: no `ESC` byte means there's nothing to strip.
        guard input.contains("\u{1B}") || input.contains("\u{07}") else { return input }

        var out = String()
        out.reserveCapacity(input.count)

        var iter = input.unicodeScalars.makeIterator()
        while let scalar = iter.next() {
            switch scalar {
            case "\u{1B}":
                consumeEscape(&iter)
            case "\u{07}", "\u{0E}", "\u{0F}":
                // BEL / SO / SI — drop quietly.
                continue
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Strip ANSI from a `Data` chunk (UTF-8 in, UTF-8 out). Falls
    /// back to passing the bytes through unchanged when the chunk
    /// isn't valid UTF-8 (avoids destroying e.g. a raw binary log
    /// segment we happen to receive mid-stream).
    public static func strip(_ data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8) else { return data }
        return Data(strip(s).utf8)
    }

    /// Consume one escape sequence following an `ESC` byte we just
    /// removed. Branches on the next scalar.
    private static func consumeEscape(_ iter: inout String.UnicodeScalarView.Iterator) {
        guard let next = iter.next() else { return }
        switch next {
        case "[":
            consumeCSI(&iter)
        case "]":
            consumeOSC(&iter)
        case "(", ")", "*", "+":
            // Character-set selection: ESC ( <single byte>.
            _ = iter.next()
        default:
            // Single-char escape (ESC c, ESC 7, ESC =, ...). Already
            // consumed by `iter.next()` above. Nothing else to do.
            break
        }
    }

    /// Consume a CSI sequence: parameter bytes (0x30..0x3F) +
    /// intermediate bytes (0x20..0x2F) + a single final byte
    /// (0x40..0x7E) that terminates it.
    private static func consumeCSI(_ iter: inout String.UnicodeScalarView.Iterator) {
        while let scalar = iter.next() {
            let v = scalar.value
            if v >= 0x40 && v <= 0x7E {
                return  // final byte consumed; sequence over.
            }
            // Anything else is param / intermediate — keep consuming.
        }
    }

    /// Consume an OSC sequence: terminated by BEL (0x07) OR by
    /// ESC `\` (the "string terminator").
    private static func consumeOSC(_ iter: inout String.UnicodeScalarView.Iterator) {
        while let scalar = iter.next() {
            if scalar == "\u{07}" { return }
            if scalar == "\u{1B}" {
                // Consume the trailing `\` (or whatever follows the ESC).
                _ = iter.next()
                return
            }
        }
    }
}
