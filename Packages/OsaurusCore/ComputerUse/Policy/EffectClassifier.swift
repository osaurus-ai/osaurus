//
//  EffectClassifier.swift
//  OsaurusCore — Computer Use
//
//  Refines a verb's baseline `EffectClass` upward using the resolved
//  element + app context. It can only ever ESCALATE (never lower), so the
//  verb baseline in `AgentAction.baselineEffect` stays the floor and a
//  misfire here can only make the gate stricter, never weaker.
//
//  What it catches beyond the verb floor:
//    • Irreversible / cross-boundary commits — a `click` on a button labeled
//      "Send", "Delete", "Purchase", "Publish" jumps navigate → consequential.
//    • Recipients on a commit — a "Save" / "Done" / "Add" press while the
//      surrounding text mentions invitees / recipients / attendees becomes
//      consequential (the spec's "calendar-save-with-invitees" case).
//    • Keyboard submit — ⌘Return / ⌘Enter, the conventional send/submit chord.
//    • Ambiguity — a click with no identifiable target is treated as at least
//      an edit so it confirms rather than silently auto-running.
//

import Foundation

/// Stateless, deterministic effect classifier. Pure over its inputs so it's
/// trivially unit-testable with the mock driver.
public enum EffectClassifier {

    /// Classify a proposed action. `resolvedRole` / `resolvedLabel` come from
    /// the `TargetResolver` (the live element the mark/describe matched);
    /// `appName` is the focused app. `recipeSignals` are per-app refinements
    /// (see `AppRecipes`) that add app-specific consequential/commit words.
    /// Returns a class `>= action.baselineEffect`.
    public static func classify(
        action: AgentAction,
        resolvedRole: String? = nil,
        resolvedLabel: String? = nil,
        appName: String? = nil,
        recipeSignals: RecipeSignals = .empty
    ) -> EffectClass {
        let baseline = action.baselineEffect
        var effect = baseline

        let consequential = Self.consequentialSignals.union(recipeSignals.consequential)
        let commit = Self.commitSignals.union(recipeSignals.commit)

        // Intent signals come from the TARGET (what the control is), not the
        // typed payload — typing the word "delete" into a search box must not
        // escalate. We scan the resolved label, the model's natural-language
        // target, and its stated rationale.
        let signal =
            [resolvedLabel, action.target?.describe, action.note]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let role = (resolvedRole ?? "").lowercased()

        // 1) Irreversible / cross-boundary commit verbs.
        if baseline >= .navigate, containsAny(signal, consequential) {
            effect = EffectClass.max(effect, .consequential)
        }

        // 2) Commit + recipients ⇒ consequential (calendar-save-with-invitees,
        //    "Send invites", an email "Send" reached via a generic "Done", etc.).
        if baseline >= .navigate,
            containsAny(signal, commit),
            containsAny(signal, Self.recipientSignals)
        {
            effect = EffectClass.max(effect, .consequential)
        }

        // 3) ⌘Return / ⌘Enter — the conventional submit/send chord.
        if action.verb == .pressKey {
            let key = (action.key ?? "").lowercased()
            let mods = Set(action.modifiers.map { $0.lowercased() })
            let isReturn = key == "return" || key == "enter" || key == "\r"
            let hasCommand = mods.contains("cmd") || mods.contains("command")
            if isReturn, hasCommand {
                effect = EffectClass.max(effect, .consequential)
            }
        }

        // 4) Default-stricter on ambiguity: an unidentifiable click target could
        //    do anything, so confirm it rather than auto-run.
        if action.verb == .click,
            (resolvedLabel?.trimmingCharacters(in: .whitespaces).isEmpty ?? true),
            role.isEmpty,
            (action.target?.describe?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        {
            effect = EffectClass.max(effect, .edit)
        }

        return effect
    }

    // MARK: - Signal vocabularies

    /// Whole-word / phrase match. Single words match against tokens (so "pay"
    /// won't fire on "display"); entries containing a space match as a
    /// substring phrase.
    static func containsAny(_ text: String, _ needles: Set<String>) -> Bool {
        guard !text.isEmpty else { return false }
        let tokens = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        for needle in needles {
            if needle.contains(" ") {
                if text.contains(needle) { return true }
            } else if tokens.contains(needle) {
                return true
            }
        }
        return false
    }

    /// Commits that are hard to undo or cross a trust boundary. Tokens are
    /// chosen to avoid common false positives (e.g. no bare "order" — it would
    /// fire on "sort order").
    static let consequentialSignals: Set<String> = [
        "send", "submit", "post", "publish", "share", "shared",
        "delete", "remove", "discard", "trash", "erase", "destroy",
        "purchase", "buy", "pay", "checkout", "transfer", "withdraw",
        "unsubscribe", "uninstall", "deactivate", "logout", "forward", "overwrite",
        "permanently", "wire",
        "log out", "sign out", "reply all", "move to trash", "empty trash",
        "delete account", "place order", "confirm purchase", "send invites",
    ]

    /// Commit-style controls — only escalate when paired with a recipient
    /// signal (rule 2).
    static let commitSignals: Set<String> = [
        "save", "done", "apply", "ok", "add", "create", "confirm", "update",
        "schedule", "invite", "save changes",
    ]

    /// Recipients / cross-boundary audience signals.
    static let recipientSignals: Set<String> = [
        "recipient", "recipients", "invitee", "invitees", "attendee", "attendees",
        "guests", "cc", "bcc", "everyone",
    ]
}
