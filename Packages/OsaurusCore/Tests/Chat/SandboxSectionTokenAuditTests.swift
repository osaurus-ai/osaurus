//
//  SandboxSectionTokenAuditTests.swift
//
//  Item 7 of the sandbox tightening spec, decided after measurement:
//  the canonical sandbox section sits at ~408 tokens once items 1–6 land.
//  The compact pair only saved ~150 tokens vs that baseline while doubling
//  the maintenance surface (same lockstep hazard `composeChatContext` and
//  `composePreviewContext` had before parity tests landed). The compact
//  variants were dropped — `SystemPromptTemplates.sandbox` now takes only
//  `secretNames`. This test pins the canonical cost so it can't drift back
//  into "expensive enough that someone re-introduces a compact pair"
//  territory.
//
//  Numbers from the in-tree run on 2026-05-05:
//    canonical: 408 tokens (no secrets configured)
//
//  The 500-token ceiling leaves headroom for trivial wording changes
//  without breaking the test. The failure message includes the live
//  number so reviewers can re-anchor this comment when it shifts.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Sandbox section token cost audit")
struct SandboxSectionTokenAuditTests {

    @Test("sandbox section stays under 500 tokens")
    func sandboxSectionFitsBudget() {
        let section = SystemPromptTemplates.sandbox()
        let cost = TokenEstimator.estimate(section)
        #expect(
            cost < 500,
            "Sandbox section grew to \(cost) tokens (>500). Trim it back; if the growth is genuinely needed, revisit whether the small-context budget allocation still makes sense."
        )
    }

    /// Adding secrets MUST scale roughly linearly — a fixed overhead for
    /// the header + access instructions, plus one short bullet per secret.
    /// Pin both: a generous fixed ceiling and a per-secret ceiling, so a
    /// future over-formatted secrets block surfaces as a test failure
    /// rather than a silent prompt regression.
    ///
    /// Live numbers (2026-05-05): zero secrets → no block; two secrets
    /// adds ~44 tokens (~32 fixed header/access + ~6 per bullet).
    @Test("secrets block scales near-linearly with secret count")
    func secretsScaleLinearly() {
        let baseline = TokenEstimator.estimate(SystemPromptTemplates.sandbox(secretNames: []))
        let twoSecrets = TokenEstimator.estimate(
            SystemPromptTemplates.sandbox(secretNames: ["FOO_TOKEN", "BAR_API_KEY"])
        )
        let fourSecrets = TokenEstimator.estimate(
            SystemPromptTemplates.sandbox(secretNames: ["A", "B", "C", "D"])
        )
        let twoDelta = twoSecrets - baseline
        let fourDelta = fourSecrets - baseline
        let perSecret = (fourDelta - twoDelta) / 2

        #expect(
            twoDelta <= 60,
            "Fixed secrets-block overhead grew to \(twoDelta) tokens for 2 secrets (>60). Header / access-instruction wording may have ballooned."
        )
        #expect(
            perSecret <= 10,
            "Per-secret cost is now \(perSecret) tokens (>10). Bullet formatting may have regressed."
        )
    }

    /// Pin the blank-line separator between Runtime hints and Configured
    /// secrets. Without it the secrets block reads as a sixth runtime-hint
    /// bullet because both render as bulleted text — visually orphaned.
    @Test("secrets block is separated from runtime hints by a blank line")
    func secretsBlockHasBlankLineSeparator() {
        let section = SystemPromptTemplates.sandbox(secretNames: ["FOO_TOKEN"])
        // Find the runtime-hints terminator and the secrets header. They
        // must be separated by `\n\n` (blank line), not a single `\n`.
        guard let hintsEnd = section.range(of: "experiment freely."),
            let secretsStart = section.range(of: "Configured secrets")
        else {
            Issue.record("Section is missing one of the pinned anchors:\n\(section)")
            return
        }
        let between = section[hintsEnd.upperBound ..< secretsStart.lowerBound]
        #expect(
            between.contains("\n\n"),
            "Runtime hints and Configured secrets are not separated by a blank line — secrets reads as a continuation of the hints list. Between: \(String(reflecting: String(between)))"
        )
    }
}
