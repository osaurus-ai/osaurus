//
//  SandboxSectionTokenAuditTests.swift
//
//  Item 7 of the sandbox tightening spec, refreshed during the prompt-bloat
//  follow-up: the canonical sandbox section should sit around 400 tokens
//  even with the SOUL.md advert. The full operational details now live in
//  the sandbox tool descriptions and can be pulled in through lazy schemas,
//  so this top-level section only carries mode framing and dispatch hints.
//
//  Numbers from the in-tree run on 2026-05-06:
//    canonical before T-O: 458 tokens (no secrets configured)
//
//  Re-anchored 2026-05-30 after the file/write tool consolidation: the
//  dispatch guide now explains `sandbox_write_file`'s dual whole-file /
//  in-place-edit behavior (the merged-away `sandbox_edit_file`), nudging
//  the canonical section to 420 tokens. The 440-token ceiling leaves
//  headroom for trivial wording changes; the failure message includes the
//  live number so reviewers can re-anchor this comment when it shifts.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Sandbox section token cost audit")
struct SandboxSectionTokenAuditTests {

    @Test("sandbox section stays under 440 tokens")
    func sandboxSectionFitsBudget() {
        let section = SystemPromptTemplates.sandbox()
        let cost = TokenEstimator.estimate(section)
        #expect(
            cost < 440,
            "Sandbox section grew to \(cost) tokens (>440). Trim it back; if the growth is genuinely needed, revisit whether the small-context budget allocation still makes sense."
        )
    }

    /// Combined mode (`.sandbox(hostRead:)`) renders the combined tool
    /// guide plus the `## Files` path-routing block. Pin its total budget
    /// and the two contracts that keep it correct: the guide must not steer
    /// the model toward the hidden sandbox read tools, and the `## Files`
    /// block must spell out the `/workspace/...` routing.
    @Test("combined-mode sandbox section + Files block stays within budget")
    func combinedModeSectionFitsBudget() {
        let section = SystemPromptTemplates.sandbox(hostReadCombined: true)
        let files = SystemPromptTemplates.unifiedFilesBlock(allowSecretReads: false)
        // Live number (2026-05-30): combined guide + `## Files` block ≈ 647
        // tokens. The 720 ceiling leaves headroom for trivial wording
        // changes; the failure message carries the live number so a
        // reviewer can re-anchor this comment when it shifts.
        let cost = TokenEstimator.estimate(section + "\n\n" + files)
        #expect(
            cost < 720,
            "Combined-mode sandbox section + Files block grew to \(cost) tokens (>720). Trim the guide / Files block."
        )
        // The combined guide must not point at tools hidden in this mode.
        #expect(!section.contains("sandbox_read_file"))
        #expect(!section.contains("sandbox_search_files"))
        // The Files block must explain the path routing.
        #expect(files.contains("## Files"))
        #expect(files.contains("/workspace"))
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
