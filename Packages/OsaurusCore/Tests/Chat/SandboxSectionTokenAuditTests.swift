//
//  SandboxSectionTokenAuditTests.swift
//
//  Item 7 of the sandbox tightening spec, decided after measurement:
//  the canonical sandbox section sits at ~458 tokens once items 1–6
//  land plus the SOUL.md advert (~50 tokens, added in the SOUL.md PR3).
//  The compact pair only saved ~150 tokens vs that baseline while
//  doubling the maintenance surface (same lockstep hazard
//  `composeChatContext` and `composePreviewContext` had before parity
//  tests landed). The compact variants were dropped —
//  `SystemPromptTemplates.sandbox` now takes only `secretNames`. This
//  test pins the canonical cost so it can't drift back into "expensive
//  enough that someone re-introduces a compact pair" territory.
//
//  Numbers from the in-tree run on 2026-05-06:
//    canonical: 458 tokens (no secrets configured)
//      (was 408 tokens before SOUL.md advert landed)
//
//  The 550-token ceiling leaves headroom for trivial wording changes
//  without breaking the test. The failure message includes the live
//  number so reviewers can re-anchor this comment when it shifts.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Sandbox section token cost audit")
struct SandboxSectionTokenAuditTests {

    @Test("sandbox section stays under 550 tokens")
    func sandboxSectionFitsBudget() {
        let section = SystemPromptTemplates.sandbox()
        let cost = TokenEstimator.estimate(section)
        #expect(
            cost < 550,
            "Sandbox section grew to \(cost) tokens (>550). Trim it back; if the growth is genuinely needed, revisit whether the small-context budget allocation still makes sense."
        )
    }

    /// PR3 of the SOUL.md spec adds a one-line advert to
    /// `sandboxRuntimeHints`. The advert is the only signal the agent
    /// has that `~/SOUL.md` is meaningful — the bootstrap seed exists
    /// but a model with no advert has no reason to read or write it.
    /// Pin both the file path and the verb so a future trim cannot
    /// silently drop the affordance while the seed file still ships.
    @Test("sandbox section advertises ~/SOUL.md as agent-editable")
    func sandboxSectionAdvertisesSoul() {
        let section = SystemPromptTemplates.sandbox()
        #expect(
            section.contains("~/SOUL.md"),
            "Sandbox section dropped the `~/SOUL.md` mention. Without it the agent has no signal that the bootstrap seed is meaningful or that editing is sanctioned. Section:\n\(section)"
        )
        #expect(
            section.contains("stable preferences across sessions"),
            "Sandbox section dropped the SOUL framing — the agent needs to know edits persist beyond the current session."
        )
        #expect(
            section.contains("edits apply on the next session"),
            "Sandbox section dropped the cadence note — the agent needs to know SOUL edits are not visible mid-session."
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
