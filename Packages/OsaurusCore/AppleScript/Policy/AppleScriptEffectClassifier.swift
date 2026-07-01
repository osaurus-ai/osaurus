//
//  AppleScriptEffectClassifier.swift
//  OsaurusCore — AppleScript Computer Use
//
//  A stateless, deterministic read/edit/consequential classifier for a
//  generated AppleScript, mirroring the Computer Use `EffectClassifier` posture:
//  it is ESCALATE-BIASED (when uncertain it rates a script HIGHER, never lower),
//  so a misfire can only make the gate STRICTER (an extra confirm, or a blocked
//  write in read-only `mac_query` mode) — never silently run a mutation as if it
//  were a harmless read.
//
//  This is a real safety/UX refinement, not a fake guard or an allowlist: the
//  classification is surfaced to the user (the effect badge on the confirm card
//  and feed) and is used only to gate, never to coerce a script into "looking
//  safe". The loop still runs the REAL script and reports the REAL outcome.
//
//  Reuses `EffectClass` (read < navigate < edit < consequential); AppleScript
//  has no distinct "navigate" surface, so it maps to `.read` / `.edit` /
//  `.consequential`.
//

import Foundation

/// Classifies a generated AppleScript by its effect on the system, from the
/// source text alone (no execution). Pure over its input → trivially testable.
public enum AppleScriptEffectClassifier {

    /// Classify `script`. Destructive / trust-boundary commits → `.consequential`;
    /// any other state mutation (set a property, make/duplicate/move an element,
    /// keystroke/click, run a shell command, set the system volume/clipboard) →
    /// `.edit`; everything else (pure `get` / `return` / `count` reads, local
    /// `set <var> to …` assignments) → `.read`.
    public static func classify(_ script: String) -> EffectClass {
        let text = script.lowercased()
        let tokens = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        if containsAny(text, tokens, consequentialSignals) { return .consequential }
        if mutatesState(text, tokens) { return .edit }
        return .read
    }

    // MARK: - Vocabularies

    /// Whole-word (token) or phrase (substring) match — same scheme as
    /// `EffectClassifier.containsAny` so "send" won't fire inside "sender".
    static func containsAny(_ text: String, _ tokens: Set<String>, _ needles: Set<String>) -> Bool {
        for needle in needles {
            if needle.contains(" ") {
                if text.contains(needle) { return true }
            } else if tokens.contains(needle) {
                return true
            }
        }
        return false
    }

    /// Destructive or trust-boundary commits. Reuses the Computer Use
    /// vocabulary (delete/send/purchase/…) and adds the AppleScript-specific
    /// system commands that are hard to undo.
    static let consequentialSignals: Set<String> =
        EffectClassifier.consequentialSignals.union([
            "quit", "reopen", "relaunch", "restart", "eject", "unmount",
            "move to trash", "empty the trash", "empty trash",
            "shut down", "log out", "sleep",
        ])

    /// Non-destructive mutating verbs / writes that still change state the user
    /// may want to review before it runs.
    static let editSignals: Set<String> = [
        "make", "duplicate", "create", "add", "insert", "paste",
        "keystroke", "click", "activate", "launch", "mount",
        "set volume", "set the volume", "set the clipboard", "set clipboard",
        "do shell script", "key code", "open location", "perform action",
        "open for access",
    ]

    /// Whether the script mutates state: an explicit mutating verb, OR an
    /// app-state property write of the form `set <thing> of <thing> to …`. A
    /// bare `set <var> to <expr>` is a LOCAL assignment (read-only data
    /// gathering) and is intentionally NOT treated as a mutation.
    private static func mutatesState(_ text: String, _ tokens: Set<String>) -> Bool {
        if containsAny(text, tokens, editSignals) { return true }
        // `set … of … to` on a single line = writing an app/element property.
        // ICU `.` excludes newlines, so this stays line-scoped (no cross-line
        // false positives) and won't match `set t to name of current track`
        // (there the `of` comes AFTER the `to`).
        if text.range(of: #"\bset\b[^\n]*\bof\b[^\n]*\bto\b"#, options: [.regularExpression]) != nil {
            return true
        }
        return false
    }
}
