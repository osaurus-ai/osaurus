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
        resolvedValue: String? = nil,
        resolvedRoleDescription: String? = nil,
        appName: String? = nil,
        recipeSignals: RecipeSignals = .empty
    ) -> EffectClass {
        let baseline = action.baselineEffect
        var effect = baseline

        let consequential = Self.consequentialSignals.union(recipeSignals.consequential)
        let commit = Self.commitSignals.union(recipeSignals.commit)

        let role = (resolvedRole ?? "").lowercased()
        let isTextInput = Self.textInputRoles.contains(role)
        // An element's `value` is intent-bearing for controls (a button whose
        // label lives in `AXValue`, a checkbox/segment state) but is USER
        // CONTENT for text inputs — folding a field's contents into the signal
        // would re-escalate "type the word delete into a search box", which must
        // stay an edit. So `value` joins the signal only for non-text-input roles.
        let valueSignal = isTextInput ? nil : resolvedValue

        // Target text = what the control IS (label + roleDescription + value +
        // the model's `describe`), excluding the free-text rationale (`note`) so
        // an icon-only control with a descriptive note isn't treated as labeled.
        let targetText =
            [resolvedLabel, resolvedRoleDescription, valueSignal, action.target?.describe]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        // The vocabulary scan also folds in the rationale (`note`), which often
        // names the real intent ("send the email", "save with the invitees").
        let signal =
            [targetText, action.note]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

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

        // 3) A bare commit control (Save / OK / Done / Apply / Create / …) with no
        //    recipient still commits SOMETHING the user may want to review, so
        //    raise it to at least `edit`. It then confirms under cautious/balanced
        //    (the default) but still auto-runs under trusted/autonomous — closing
        //    the gap where a solo "Save"/"OK" silently auto-ran as `navigate`.
        if baseline >= .navigate, containsAny(signal, commit) {
            effect = EffectClass.max(effect, .edit)
        }

        // 4) ⌘Return / ⌘Enter — the conventional submit/send chord.
        if action.verb == .pressKey {
            let key = (action.key ?? "").lowercased()
            let mods = Set(action.modifiers.map { $0.lowercased() })
            let isReturn = key == "return" || key == "enter" || key == "\r"
            let hasCommand = mods.contains("cmd") || mods.contains("command")
            if isReturn, hasCommand {
                effect = EffectClass.max(effect, .consequential)
            }
        }

        // 5) Default-stricter on ambiguity / icon-only controls: a click whose
        //    target exposes no readable text — an unidentifiable hit (empty role)
        //    OR an icon-only button (a known control role with no label/value/
        //    description) — could do anything, so confirm it rather than auto-run.
        if action.verb == .click || action.verb == .doubleClick || action.verb == .rightClick {
            let isControl = role.isEmpty || Self.actionableControlRoles.contains(role)
            if targetText.isEmpty, isControl {
                effect = EffectClass.max(effect, .edit)
            }
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

    /// Roles that act on click (so an UNLABELED one is an icon-only button worth
    /// confirming). Includes both raw AX (`AXButton`) and friendly (`button`)
    /// forms since `CUElement.role` carries either depending on the driver.
    static let actionableControlRoles: Set<String> = [
        "button", "axbutton",
        "menubutton", "axmenubutton",
        "popupbutton", "axpopupbutton",
        "togglebutton", "axtogglebutton",
    ]

    /// Text-input roles whose `value` is user content, not control intent — see
    /// `valueSignal`. Raw AX + friendly forms.
    static let textInputRoles: Set<String> = [
        "textfield", "axtextfield",
        "textarea", "axtextarea",
        "textview", "axtextview",
        "searchfield", "axsearchfield",
        "securefield", "securetextfield", "axsecuretextfield",
        "combobox", "axcombobox",
    ]
}
