//
//  BrowserGatingTests.swift
//  OsaurusCore — Native Browser Use
//
//  Pins the browser action → EffectClass mapping (`BrowserEffectClassifier`)
//  and the pure `BrowserGate` decisions on top of the shared `AutonomyPolicy`
//  + per-agent ceiling. These are the deterministic halves of the plan's
//  "reads/navigation auto, typing edit, submit/auth/reset consequential"
//  contract — the same gate ladder Computer Use uses.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Effect classification

@Suite struct BrowserEffectClassifierTests {

    @Test func perceptionAndInspectionAreReads() {
        for action in [
            "snapshot", "wait_for", "console_messages", "network_requests", "get_cookies",
            "screenshot", "dialog_status", "read_page",
        ] {
            #expect(
                BrowserEffectClassifier.classify(action: action, target: nil, submit: false)
                    == .read)
        }
    }

    @Test func ordinaryMovementIsNavigate() {
        for action in ["navigate", "back", "scroll", "hover"] {
            #expect(
                BrowserEffectClassifier.classify(action: action, target: nil, submit: false)
                    == .navigate)
        }
    }

    @Test func typingAndStateMutationAreEdits() {
        for action in ["type", "select", "set_cookie", "handle_dialog"] {
            #expect(
                BrowserEffectClassifier.classify(action: action, target: nil, submit: false)
                    == .edit)
        }
    }

    @Test func explicitSubmitEscalatesToConsequential() {
        // type(submit: true) and Enter fold the caller's submit intent in.
        #expect(
            BrowserEffectClassifier.classify(action: "type", target: nil, submit: true)
                == .consequential)
        #expect(
            BrowserEffectClassifier.classify(action: "press_key", target: "Enter", submit: true)
                == .consequential)
        // A plain key press is only navigation.
        #expect(
            BrowserEffectClassifier.classify(action: "press_key", target: "Tab", submit: false)
                == .navigate)
    }

    @Test func clickEscalatesOnConsequentialTargets() {
        #expect(
            BrowserEffectClassifier.classify(action: "click", target: "Read more", submit: false)
                == .navigate)
        for label in ["Submit", "Place order", "Delete account", "Sign in", "Buy now", "Checkout"] {
            #expect(
                BrowserEffectClassifier.classify(action: "click", target: label, submit: false)
                    == .consequential,
                "click on '\(label)' must be consequential")
        }
    }

    @Test func authSessionAndScriptActionsAreAlwaysConsequential() {
        // read_cookie_values: raw session tokens flowing into the transcript
        // are an exfiltration channel, so it always needs a user confirm.
        for action in [
            "clear_cookies", "reset_session", "open_login", "execute_script",
            "read_cookie_values",
        ] {
            #expect(
                BrowserEffectClassifier.classify(action: action, target: nil, submit: false)
                    == .consequential)
        }
    }

    @Test func unknownActionsDefaultToEdit() {
        // Conservative fallback: a verb the classifier doesn't know must at
        // least require the edit disposition, never run as a free read.
        #expect(
            BrowserEffectClassifier.classify(action: "future_verb", target: nil, submit: false)
                == .edit)
    }

    @Test func targetDetectionIsCaseInsensitiveAndSubstring() {
        #expect(BrowserEffectClassifier.targetLooksConsequential("SUBMIT ORDER"))
        #expect(BrowserEffectClassifier.targetLooksConsequential("Confirm & pay"))
        #expect(!BrowserEffectClassifier.targetLooksConsequential(nil))
        #expect(!BrowserEffectClassifier.targetLooksConsequential(""))
        #expect(!BrowserEffectClassifier.targetLooksConsequential("View details"))
    }
}

// MARK: - Gate decisions

@Suite struct BrowserGateTests {

    private func decide(
        _ gate: BrowserGate, effect: EffectClass, host: String? = "example.com"
    ) -> GateDecision {
        gate.evaluate(
            effect: effect, actionLabel: "Test", host: host, targetLabel: nil, typedText: nil)
    }

    @Test func balancedDefaultAllowsReadsAndNavigationConfirmsTheRest() {
        let gate = BrowserGate(policy: .defaultPolicy)
        #expect(decide(gate, effect: .read).isRun)
        #expect(decide(gate, effect: .navigate).isRun)
        #expect(decide(gate, effect: .edit).isConfirm)
        #expect(decide(gate, effect: .consequential).isConfirm)
    }

    @Test func readOnlyDeniesEditsOutright() {
        let gate = BrowserGate(policy: AutonomyPolicy(globalPreset: .readOnly))
        #expect(decide(gate, effect: .navigate).isRun)
        if case .reject(let reason) = decide(gate, effect: .edit) {
            #expect(reason.contains("autonomy policy"))
        } else {
            Issue.record("readOnly must reject edits")
        }
    }

    @Test func autonomousStillHonorsTheAgentCeiling() {
        // Strictest-wins: a per-agent ceiling caps even the loosest global
        // preset, so an agent can never be MORE autonomous than its ceiling.
        let gate = BrowserGate(
            policy: AutonomyPolicy(globalPreset: .autonomous),
            ceiling: .cappedAt(.balanced)
        )
        #expect(decide(gate, effect: .navigate).isRun)
        #expect(decide(gate, effect: .edit).isConfirm)
        #expect(decide(gate, effect: .consequential).isConfirm)
    }

    @Test func perAppOverridesAndAllowlistDoNotApplyToHosts() {
        // The macOS app allowlist names desktop apps, not web hosts — a
        // restrictive allowlist must not block browser actions, and a per-app
        // rule keyed on a host name must not tighten them (BrowserGate passes
        // `app: nil` into the disposition merge on purpose).
        let gate = BrowserGate(
            policy: AutonomyPolicy(
                globalPreset: .balanced,
                perApp: ["example.com": .readOnly],
                allowlist: ["Safari"]
            )
        )
        #expect(decide(gate, effect: .navigate, host: "example.com").isRun)
        #expect(decide(gate, effect: .edit, host: "example.com").isConfirm)
    }

    @Test func confirmPreviewCarriesHostAndEffect() {
        let gate = BrowserGate(policy: .defaultPolicy)
        let decision = gate.evaluate(
            effect: .consequential,
            actionLabel: "Click",
            host: "shop.example.com",
            targetLabel: "Place order",
            typedText: nil
        )
        guard case .confirm(let preview) = decision else {
            Issue.record("expected a confirm decision")
            return
        }
        #expect(preview.appName == "shop.example.com")
        #expect(preview.targetLabel == "Place order")
        #expect(preview.effect == .consequential)
    }
}

// MARK: - GateDecision test sugar

extension GateDecision {
    fileprivate var isRun: Bool {
        if case .run = self { return true }
        return false
    }
    fileprivate var isConfirm: Bool {
        if case .confirm = self { return true }
        return false
    }
}
