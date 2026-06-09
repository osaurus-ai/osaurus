//
//  SandboxSectionTokenAuditTests.swift
//
//  Item 7 of the sandbox tightening spec, refreshed during the prompt-bloat
//  follow-up: the canonical sandbox section should sit around 400 tokens.
//  The full operational details now live in the sandbox tool descriptions
//  (pulled in through lazy schemas) and SOUL guidance lives in the
//  Self-improvement section, so this top-level section only carries mode
//  framing and dispatch hints.
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

    /// `~/SOUL.md` guidance has a single owner: the always-present
    /// `## Self-improvement` section (which co-fires on every sandbox turn).
    /// To keep the surfaces from drifting back into duplication, the static
    /// sandbox framing must NOT re-advertise SOUL, and Self-improvement must
    /// carry the path, the edit verb, and the next-session cadence.
    @Test("SOUL.md guidance lives in Self-improvement, not the sandbox framing")
    func soulGuidanceOwnedBySelfImprovement() {
        let framing = SystemPromptTemplates.sandbox()
        #expect(
            !framing.contains("SOUL.md"),
            "Sandbox framing should no longer carry SOUL guidance — it moved to the Self-improvement section. Framing:\n\(framing)"
        )

        let selfImprovement = SystemPromptTemplates.selfImprovementGuidance(canCreatePlugins: false)
        #expect(
            selfImprovement.contains("~/SOUL.md"),
            "Self-improvement dropped the `~/SOUL.md` mention — the agent needs a signal that the bootstrap seed is meaningful and editing is sanctioned."
        )
        #expect(
            selfImprovement.contains("sandbox_write_file"),
            "Self-improvement dropped the SOUL edit verb."
        )
        #expect(
            selfImprovement.contains("next session"),
            "Self-improvement dropped the cadence note — the agent needs to know SOUL edits are not visible mid-session."
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
    /// Adding secrets MUST scale roughly linearly. Secrets now live in the
    /// dynamic `sandboxState` section (relocated out of the static framing
    /// for KV-cache stability), so the audit measures that section.
    @Test("secrets block scales near-linearly with secret count")
    func secretsScaleLinearly() {
        let baseline = TokenEstimator.estimate(SystemPromptTemplates.sandboxState(secretNames: []))
        let twoSecrets = TokenEstimator.estimate(
            SystemPromptTemplates.sandboxState(secretNames: ["FOO_TOKEN", "BAR_API_KEY"])
        )
        let fourSecrets = TokenEstimator.estimate(
            SystemPromptTemplates.sandboxState(secretNames: ["A", "B", "C", "D"])
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

    /// The static `sandbox` framing must NOT carry the mutable secret /
    /// package state — that lives in the dynamic `sandboxState` section so
    /// adding a secret or installing a package mid-session doesn't rewrite
    /// the cached prefix. Pin the split so a future refactor can't silently
    /// fold the mutable bits back into the framing.
    @Test("static sandbox framing carries no mutable state")
    func sandboxFramingExcludesMutableState() {
        let framing = SystemPromptTemplates.sandbox()
        #expect(!framing.contains("Configured secrets"))
        #expect(!framing.contains("Already installed"))

        let state = SystemPromptTemplates.sandboxState(
            secretNames: ["FOO_TOKEN"],
            installedPackages: .init(pip: ["flask"])
        )
        #expect(state.contains("Configured secrets"))
        #expect(state.contains("Already installed"))
    }
}
