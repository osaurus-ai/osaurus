//
//  TerminalLineTracker.swift
//  osaurus
//
//  Tier-1 TUI renderer for streaming command output. State machine that
//  turns a byte stream — including `\r` carriage-return redraws — into:
//    1. a sequence of "committed" lines (terminated by `\n`, immutable)
//    2. a single mutable "live" line (everything after the last `\n` or
//       `\r` in the stream so far)
//
//  Used by `TerminalStreamRenderer`'s flush path (incremental) AND by
//  the static `render(_:)` helper (one-shot, for completed snapshots).
//
//  Only handles `\r` and `\n`. Cursor up/down, alternate-screen toggles,
//  and SGR colours are `ANSIStripper`'s job. That's enough for the
//  dominant single-line progress bar cases (pip / curl / wget / apt /
//  ffmpeg with `-progress pipe:1`) without pulling in a vt100 emulator.
//
//  Cross-chunk contract:
//    - `\r` in chunk N + characters in chunk N+1 still replaces the
//      same live line — no boundary special-casing needed.
//    - `\n` as the last byte commits the line; `liveLine` is empty
//      until the next chunk arrives.
//

import Foundation

struct TerminalLineTracker {

    /// Trailing un-committed line. Replaced wholesale on every `\r`,
    /// appended to on every other character.
    private(set) var liveLine: String = ""

    /// Newly committed lines not yet drained by the consumer. Trailing
    /// `\n` is stripped — the consumer joins with `\n` when writing.
    private var pendingCommits: [String] = []

    init() {}

    /// Feed a chunk of (already ANSI-stripped) text. Mutates internal
    /// state; doesn't allocate per-byte.
    mutating func feed(_ text: String) {
        guard !text.isEmpty else { return }
        // Walk by Unicode scalar so multi-byte UTF-8 doesn't split
        // mid-codepoint.
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n":
                pendingCommits.append(liveLine)
                liveLine = ""
            case "\r":
                liveLine = ""
            default:
                liveLine.unicodeScalars.append(scalar)
            }
        }
    }

    /// Convenience: feed UTF-8 bytes. Invalid bytes are dropped.
    mutating func feed(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        feed(text)
    }

    /// Pop every line committed since the last drain (without trailing
    /// newlines). Empty array when nothing committed.
    mutating func drainNewlyCommittedLines() -> [String] {
        defer { pendingCommits.removeAll(keepingCapacity: true) }
        return pendingCommits
    }

    mutating func reset() {
        pendingCommits.removeAll(keepingCapacity: false)
        liveLine = ""
    }

    // MARK: - Pure-function helpers

    /// One-shot render for completed snapshots: apply the tracker to
    /// the whole buffer and return the rendered text. Trailing newline
    /// is preserved only when the input ends in `\n` AND `liveLine` is
    /// empty.
    static func render(_ text: String) -> String {
        var tracker = TerminalLineTracker()
        tracker.feed(text)
        let committed = tracker.drainNewlyCommittedLines()
        if tracker.liveLine.isEmpty {
            return committed.isEmpty ? "" : committed.joined(separator: "\n") + "\n"
        }
        if committed.isEmpty {
            return tracker.liveLine
        }
        return committed.joined(separator: "\n") + "\n" + tracker.liveLine
    }

    static func render(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        return render(text)
    }
}
