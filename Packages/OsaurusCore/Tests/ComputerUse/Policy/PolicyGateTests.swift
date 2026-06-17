//
//  PolicyGateTests.swift
//  OsaurusCoreTests — Computer Use
//
//  PR2 coverage for the configurable-autonomy layer: the context-sensitive
//  `EffectClassifier`, the strictest-wins `AutonomyPolicy` merge (global +
//  per-app + per-agent ceiling), the app allowlist, and the policy-driven
//  `ComputerUseGate` decisions. All pure over their inputs — no driver, no
//  permissions, no UI.
//

import Foundation
import XCTest

@testable import OsaurusCore

// MARK: - Effect classifier

final class EffectClassifierTests: XCTestCase {
    private func click(describe: String? = nil, note: String? = nil) -> AgentAction {
        AgentAction(verb: .click, target: AgentTarget(mark: 1, describe: describe), note: note)
    }

    func testBaselinePreservedWithoutSignals() {
        XCTAssertEqual(EffectClassifier.classify(action: AgentAction(verb: .observe)), .read)
        XCTAssertEqual(
            EffectClassifier.classify(action: click(), resolvedRole: "AXButton", resolvedLabel: "Files"),
            .navigate
        )
        XCTAssertEqual(
            EffectClassifier.classify(
                action: AgentAction(verb: .type, text: "hello"),
                resolvedRole: "AXTextField",
                resolvedLabel: "Search"
            ),
            .edit
        )
    }

    func testCommitButtonsEscalateToConsequential() {
        for label in ["Send", "Delete", "Purchase", "Publish", "Move to Trash", "Reply All"] {
            let effect = EffectClassifier.classify(
                action: click(),
                resolvedRole: "AXButton",
                resolvedLabel: label
            )
            XCTAssertEqual(effect, .consequential, "\(label) should be consequential")
        }
    }

    func testTokenMatchAvoidsSubstringFalsePositive() {
        // "display" contains "pay" but must NOT escalate (token, not substring).
        let effect = EffectClassifier.classify(
            action: click(),
            resolvedRole: "AXButton",
            resolvedLabel: "Display Settings"
        )
        XCTAssertEqual(effect, .navigate)
    }

    func testTypedTextDoesNotEscalate() {
        // Typing the word "delete" into a field is an edit, not consequential —
        // the classifier scans the target, not the payload.
        let effect = EffectClassifier.classify(
            action: AgentAction(verb: .type, text: "please delete everything"),
            resolvedRole: "AXTextField",
            resolvedLabel: "Message"
        )
        XCTAssertEqual(effect, .edit)
    }

    func testCommitWithRecipientsIsConsequential() {
        // The "calendar-save-with-invitees" case: a generic Save/Done commit
        // becomes consequential when recipients are in play.
        let effect = EffectClassifier.classify(
            action: click(note: "Save the event with the invitees"),
            resolvedRole: "AXButton",
            resolvedLabel: "Save"
        )
        XCTAssertEqual(effect, .consequential)
    }

    func testCommandReturnIsSubmit() {
        let cmdReturn = AgentAction(verb: .pressKey, key: "return", modifiers: ["cmd"])
        XCTAssertEqual(EffectClassifier.classify(action: cmdReturn), .consequential)

        let bareReturn = AgentAction(verb: .pressKey, key: "return")
        XCTAssertEqual(EffectClassifier.classify(action: bareReturn), .edit)
    }

    func testAmbiguousClickIsStricter() {
        // No mark resolution, no role, no describe → escalate navigate → edit.
        let blind = AgentAction(verb: .click, target: AgentTarget(describe: ""))
        XCTAssertEqual(EffectClassifier.classify(action: blind), .edit)
    }

    func testNeverLowersBelowBaseline() {
        // An edit verb with a totally benign target stays at least edit.
        let effect = EffectClassifier.classify(
            action: AgentAction(verb: .setValue, target: AgentTarget(mark: 2), text: "x"),
            resolvedRole: "AXTextField",
            resolvedLabel: "Name"
        )
        XCTAssertGreaterThanOrEqual(effect, .edit)
    }
}

// MARK: - Presets + policy merge

final class AutonomyPolicyTests: XCTestCase {
    func testPresetDispositions() {
        XCTAssertEqual(AutonomyPreset.balanced.disposition(for: .read), .allow)
        XCTAssertEqual(AutonomyPreset.balanced.disposition(for: .navigate), .allow)
        XCTAssertEqual(AutonomyPreset.balanced.disposition(for: .edit), .confirm)
        XCTAssertEqual(AutonomyPreset.balanced.disposition(for: .consequential), .confirm)

        XCTAssertEqual(AutonomyPreset.readOnly.disposition(for: .navigate), .allow)
        XCTAssertEqual(AutonomyPreset.readOnly.disposition(for: .edit), .deny)
        XCTAssertEqual(AutonomyPreset.readOnly.disposition(for: .consequential), .deny)

        XCTAssertEqual(AutonomyPreset.cautious.disposition(for: .navigate), .confirm)

        XCTAssertEqual(AutonomyPreset.trusted.disposition(for: .edit), .allow)
        XCTAssertEqual(AutonomyPreset.trusted.disposition(for: .consequential), .confirm)

        for effect in EffectClass.allCases {
            XCTAssertEqual(AutonomyPreset.autonomous.disposition(for: effect), .allow)
        }
    }

    func testPerAppOverrideOnlyTightens() {
        // Global trusted (edits auto), but Mail is held to cautious.
        var policy = AutonomyPolicy(globalPreset: .trusted)
        policy.perApp["mail"] = .cautious
        XCTAssertEqual(policy.disposition(for: .edit, app: "Mail", ceiling: nil), .confirm)
        // An app with no override follows the global preset.
        XCTAssertEqual(policy.disposition(for: .edit, app: "Notes", ceiling: nil), .allow)
    }

    func testPerAppCannotLoosen() {
        // Global cautious; per-app "autonomous" must NOT weaken it (strictest wins).
        var policy = AutonomyPolicy(globalPreset: .cautious)
        policy.perApp["safari"] = .autonomous
        XCTAssertEqual(policy.disposition(for: .navigate, app: "Safari", ceiling: nil), .confirm)
    }

    func testCeilingTightensAcrossPolicy() {
        let policy = AutonomyPolicy(globalPreset: .autonomous)
        let ceiling = AutonomyCeiling.cappedAt(.balanced)
        XCTAssertEqual(policy.disposition(for: .consequential, app: "Notes", ceiling: ceiling), .confirm)
        XCTAssertEqual(policy.disposition(for: .edit, app: "Notes", ceiling: ceiling), .confirm)
        // Read is never capped.
        XCTAssertEqual(policy.disposition(for: .read, app: "Notes", ceiling: ceiling), .allow)
    }

    func testAllowlistGating() {
        XCTAssertTrue(AutonomyPolicy().isAppAllowed("anything"))
        XCTAssertTrue(AutonomyPolicy(allowlist: []).isAppAllowed("anything"))

        let restricted = AutonomyPolicy(allowlist: ["safari", "notes"])
        XCTAssertTrue(restricted.isAppAllowed("Safari"))  // case-insensitive
        XCTAssertTrue(restricted.isAppAllowed("NOTES"))
        XCTAssertFalse(restricted.isAppAllowed("Mail"))
        XCTAssertFalse(restricted.isAppAllowed(nil))
    }

    func testCeilingPresetRoundTrips() {
        for preset in AutonomyPreset.allCases {
            XCTAssertEqual(AutonomyCeiling.cappedAt(preset).matchingPreset, preset)
        }
    }

    func testPolicyCodableRoundTrip() throws {
        var policy = AutonomyPolicy(globalPreset: .trusted, allowlist: ["safari"])
        policy.perApp["mail"] = .cautious
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(AutonomyPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
    }
}

// MARK: - Gate

final class ComputerUseGateTests: XCTestCase {
    private let clickSend = AgentAction(
        verb: .click,
        target: AgentTarget(describe: "the Send button")
    )

    func testRejectsNonAllowlistedApp() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(allowlist: ["notes"]))
        let decision = await gate.evaluate(
            action: clickSend,
            effect: .navigate,
            appName: "Mail",
            targetLabel: "Send"
        )
        guard case .reject = decision else {
            return XCTFail("expected reject for non-allowlisted app")
        }
    }

    func testAllowRunsConfirmConfirmsDenyRejects() async {
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .balanced))

        let read = await gate.evaluate(
            action: AgentAction(verb: .observe),
            effect: .read,
            appName: "Notes",
            targetLabel: nil
        )
        XCTAssertEqual(read, .run)

        let edit = await gate.evaluate(
            action: AgentAction(verb: .type, text: "x"),
            effect: .edit,
            appName: "Notes",
            targetLabel: "Body"
        )
        guard case .confirm(let preview) = edit else { return XCTFail("expected confirm") }
        XCTAssertEqual(preview.effect, .edit)
        XCTAssertEqual(preview.appName, "Notes")
        XCTAssertEqual(preview.targetLabel, "Body")

        let readOnlyGate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .readOnly))
        let blocked = await readOnlyGate.evaluate(
            action: clickSend,
            effect: .consequential,
            appName: "Notes",
            targetLabel: "Send"
        )
        guard case .reject = blocked else { return XCTFail("expected reject under read-only") }
    }

    func testCeilingAppliesInGate() async {
        let gate = ComputerUseGate(
            policy: AutonomyPolicy(globalPreset: .autonomous),
            ceiling: AutonomyCeiling.cappedAt(.balanced)
        )
        let decision = await gate.evaluate(
            action: clickSend,
            effect: .consequential,
            appName: "Notes",
            targetLabel: "Send"
        )
        guard case .confirm = decision else {
            return XCTFail("ceiling should force a confirm even under autonomous policy")
        }
    }

    /// The `open` verb is navigate-class and must clear the allowlist + the
    /// navigate disposition exactly like the loop now gates it (classify the app
    /// being opened, then evaluate). This guards the closed allowlist-bypass.
    func testOpenIsGatedByAllowlistAndPreset() async {
        let openMail = AgentAction(verb: .open, app: "Mail")
        let effect = EffectClassifier.classify(
            action: openMail,
            appName: "Mail",
            recipeSignals: AppRecipes.signals(for: "Mail")
        )
        XCTAssertEqual(effect, .navigate)

        // Allowlist excludes Mail → reject, even though navigate would otherwise run.
        let restricted = ComputerUseGate(policy: AutonomyPolicy(allowlist: ["notes"]))
        guard
            case .reject = await restricted.evaluate(
                action: openMail,
                effect: effect,
                appName: "Mail",
                targetLabel: "Mail"
            )
        else { return XCTFail("expected reject when opening a non-allowlisted app") }

        // Cautious preset → navigate confirms, so `open` pauses for approval.
        let cautious = ComputerUseGate(policy: AutonomyPolicy(globalPreset: .cautious))
        guard
            case .confirm = await cautious.evaluate(
                action: openMail,
                effect: effect,
                appName: "Mail",
                targetLabel: "Mail"
            )
        else { return XCTFail("expected confirm under cautious") }

        // Allowed + balanced → runs immediately.
        let allowed = ComputerUseGate(
            policy: AutonomyPolicy(globalPreset: .balanced, allowlist: ["mail"])
        )
        let allowedDecision = await allowed.evaluate(
            action: openMail,
            effect: effect,
            appName: "Mail",
            targetLabel: "Mail"
        )
        XCTAssertEqual(allowedDecision, .run)
    }
}
