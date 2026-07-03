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
    /// keystroke/click, set the system volume/clipboard) → `.edit`; everything
    /// else (pure `get` / `return` / `count` reads, local `set <var> to …`
    /// assignments) → `.read`.
    ///
    /// `do shell script` is classified by the SHELL command it runs rather than
    /// by the AppleScript verb, and only ever ESCALATES the verb classification
    /// (never lowers it): a destructive / writing command (rm, kill, sudo, `>`,
    /// `defaults write`, …) is `.consequential`, while a pure read (pmset -g
    /// batt, system_profiler, sw_vers, …) stays a `.read` so `mac_query` can run
    /// benign shell reads instead of blocking them.
    public static func classify(_ script: String) -> EffectClass {
        let text = script.lowercased()
        let tokens = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        var effect: EffectClass = .read
        if containsAny(text, tokens, consequentialSignals) {
            effect = .consequential
        } else if mutatesState(text, tokens) {
            effect = .edit
        }

        if text.contains("do shell script") {
            effect = EffectClass.max(effect, shellEffect(text, tokens))
        }
        return effect
    }

    /// Language-aware classification. AppleScript classifies normally. A JXA
    /// (JavaScript) script floors at `.edit`: the verb vocabulary above is
    /// AppleScript English, and JavaScript mutations (`note.body = …`,
    /// `.push(…)`, method calls) are statically opaque to it — so per the
    /// escalate bias a JXA script is NEVER rated a silent-auto-run `.read`.
    /// The token scan still runs so destructive names (`delete`, `send`, …)
    /// escalate JXA to `.consequential`.
    public static func classify(_ script: String, language: AppleScriptLanguage) -> EffectClass {
        switch language {
        case .appleScript:
            return classify(script)
        case .javascript:
            return EffectClass.max(.edit, classify(script))
        }
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
    /// system commands that are hard to undo. `run shortcut` is here because a
    /// user-authored Shortcut can do ANYTHING the user built it to do (send,
    /// delete, post, purchase) — its effect is opaque to this classifier, so
    /// invoking one is a trust-boundary commit, never a read.
    static let consequentialSignals: Set<String> =
        EffectClassifier.consequentialSignals.union([
            "quit", "reopen", "relaunch", "restart", "eject", "unmount",
            "move to trash", "empty the trash", "empty trash",
            "shut down", "log out", "sleep",
            "run shortcut", "run the shortcut",
        ])

    /// Non-destructive mutating verbs / writes that still change state the user
    /// may want to review before it runs. `do shell script` is intentionally
    /// NOT here — it is classified by its shell command in `shellEffect`.
    static let editSignals: Set<String> = [
        "make", "duplicate", "create", "add", "insert", "paste",
        "keystroke", "click", "activate", "launch", "mount",
        "set volume", "set the volume", "set the clipboard", "set clipboard",
        "key code", "open location", "perform action",
        "open for access",
    ]

    /// Shell tokens / phrases that DESTROY or WRITE system / file state. Any of
    /// these inside a `do shell script` → `.consequential`, so a destructive
    /// command never auto-runs under auto-run-with-warning and is always blocked
    /// in read-only `mac_query` mode. Tools whose read/write split is
    /// argument-dependent (`defaults`, `pmset`, `networksetup`, `scutil`) are
    /// matched by their WRITE sub-form only, so their read form (`defaults
    /// read`, `pmset -g batt`) still classifies as a read.
    static let mutatingShellSignals: Set<String> = [
        // Destructive.
        "rm", "rmdir", "unlink", "kill", "killall", "pkill", "shutdown",
        "reboot", "halt", "dd", "mkfs", "sudo", "srm", "shred", "diskutil",
        "fdisk", "purge", "trash",
        // File / state writes.
        "mv", "cp", "mkdir", "touch", "chmod", "chown", "chgrp", "ln", "tee",
        "install", "installer", "launchctl", "crontab", "nvram", "systemsetup",
        "spctl", "csrutil", "kextload", "kextunload", "mount", "umount",
        "softwareupdate", "pkgutil", "git", "brew", "npm", "pip", "gem",
        "curl", "wget", "osascript", "pbcopy", "renice", "caffeinate", "say",
        // Argument-dependent tools: match the WRITE sub-form as a phrase.
        "defaults write", "defaults delete", "defaults rename",
        "networksetup -set", "scutil --set",
        "pmset -a", "pmset -c", "pmset -b", "pmset schedule", "pmset repeat",
        // Running a user Shortcut from the shell — same opaque-effect commit
        // as the AppleScript `run shortcut` form. (`shortcuts list` stays a read.)
        "shortcuts run",
    ]

    /// Shell metacharacters that redirect output (a write) or substitute a
    /// command whose effect can't be seen. Any → `.consequential`. Pipes (`|`)
    /// and simple chaining are intentionally omitted: they're common in reads
    /// (`system_profiler … | grep …`) and each piped command is still screened
    /// against `mutatingShellSignals`.
    static let writingShellMetacharacters: [String] = [">", "`", "$("]

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

    /// The effect of a `do shell script` from the shell command it runs.
    /// Escalate-biased: a destructive / writing command (or an output
    /// redirection / command substitution) is `.consequential`; anything else
    /// is a `.read` (a benign system read like `pmset -g batt` /
    /// `system_profiler`). There is deliberately no shell `.edit` tier — a shell
    /// command either writes (treat as consequential and always confirm/block)
    /// or it reads.
    static func shellEffect(_ text: String, _ tokens: Set<String>) -> EffectClass {
        if containsAny(text, tokens, mutatingShellSignals) { return .consequential }
        if writingShellMetacharacters.contains(where: { text.contains($0) }) {
            return .consequential
        }
        return .read
    }
}
