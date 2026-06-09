//
//  SandboxAgentProvisionerSoulSeedTests.swift
//
//  Pin the contract of the SOUL.md bootstrap seed:
//
//  - The seed body still spells out the file's purpose, sanctions edits,
//    and states the cadence on which edits apply. The detailed
//    what-goes / what-does-not-go boundary now lives once in the
//    always-present `## Self-improvement` prompt section (which co-fires
//    on every sandbox turn), so the one-time seed stays identity-only
//    rather than duplicating it.
//  - The seed script is idempotent: a `test -f "$HOME/SOUL.md" ||`
//    guard wraps the heredoc so a soul the agent has accumulated edits
//    to is never overwritten on subsequent provisions.
//  - The heredoc terminator is single-quoted (`<<'SOUL_EOF'`) so `$` /
//    backtick / `\` inside the body never expand, and the seed lands
//    byte-exact regardless of the agent user's shell environment.
//
//  Behaviour (write happens on first provision, file survives second
//  provision after the agent has edited it) is covered end-to-end by
//  `SandboxIntegrationTests.soulSeed_appearsOnFirstProvisionAndIsPreserved`,
//  which is gated on `OSAURUS_RUN_SANDBOX_INTEGRATION_TESTS=1` because
//  it boots a real Apple Containerization VM.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("SOUL.md bootstrap seed shape")
struct SandboxAgentProvisionerSoulSeedTests {

    // MARK: - Seed body contract

    @Test("seed body declares it is the agent's space + persists across sessions")
    func seedBody_declaresPurpose() {
        let body = SandboxAgentProvisioner.soulSeedBody
        #expect(body.contains("# SOUL"))
        #expect(body.contains("persists across sessions"))
    }

    /// The whole point of the seed is to teach the agent that EDITS
    /// are sanctioned — without that signal the agent has no reason to
    /// touch the file. Pin the tool names so a future "trim everything"
    /// refactor cannot silently strip the editing affordance.
    @Test("seed body sanctions edits via sandbox_write_file")
    func seedBody_sanctionsEdits() {
        let body = SandboxAgentProvisioner.soulSeedBody
        #expect(body.contains("sandbox_write_file"))
        // `sandbox_edit_file` was folded into `sandbox_write_file`.
        #expect(!body.contains("sandbox_edit_file"))
    }

    /// The seed stays identity-only: the detailed what-goes / what-does-not-go
    /// boundary moved to the always-present `## Self-improvement` prompt
    /// section, so the one-time seed must NOT re-list it. Pinning the
    /// absence keeps the two surfaces from drifting back into duplication.
    @Test("seed body stays identity-only and delegates the boundary to the prompt")
    func seedBody_staysIdentityOnly() {
        let body = SandboxAgentProvisioner.soulSeedBody
        #expect(!body.contains("What goes here"))
        #expect(!body.contains("What does NOT go here"))
        // The Self-improvement section is the single owner of the boundary.
        let selfImprovement = SystemPromptTemplates.selfImprovementGuidance(canCreatePlugins: false)
        #expect(selfImprovement.contains("SOUL.md"))
    }

    @Test("seed body explains the next-session cadence")
    func seedBody_explainsCadence() {
        let body = SandboxAgentProvisioner.soulSeedBody
        #expect(body.contains("next session"))
    }

    // MARK: - Seed script shape

    /// `test -f "$HOME/SOUL.md" || cat > ...` is the idempotency guard.
    /// Without it, every provision would overwrite an accumulated soul
    /// — the spec calls this out explicitly: "never overwrite an
    /// agent's accumulated SOUL".
    @Test("seed script is guarded by test -f against $HOME/SOUL.md")
    func seedScript_isIdempotentGuarded() {
        let script = SandboxAgentProvisioner.soulSeedScript()
        #expect(script.contains(#"test -f "$HOME/SOUL.md""#))
        #expect(script.contains("||"))
        #expect(script.contains(#"cat > "$HOME/SOUL.md""#))
    }

    /// Single-quoted heredoc terminator disables `$` / backtick / `\`
    /// expansion so the seed body's contents land byte-exact regardless
    /// of the agent user's shell environment.
    @Test("seed script uses a single-quoted heredoc terminator")
    func seedScript_usesSingleQuotedHeredoc() {
        let script = SandboxAgentProvisioner.soulSeedScript()
        #expect(script.contains("<<'SOUL_EOF'"))
        #expect(
            !script.contains("<<SOUL_EOF"),
            "Heredoc terminator must stay quoted; an unquoted terminator would expand `$` references inside the body and corrupt the seed."
        )
    }

    /// The heredoc terminator must appear on its own line with no
    /// leading whitespace, otherwise bash treats it as part of the
    /// body and the heredoc never closes.
    @Test("seed script's SOUL_EOF terminator is on its own line, flush left")
    func seedScript_terminatorIsFlushLeft() {
        let script = SandboxAgentProvisioner.soulSeedScript()
        let lines = script.components(separatedBy: "\n")
        guard let terminator = lines.first(where: { $0.contains("SOUL_EOF") && !$0.contains("'") })
        else {
            Issue.record("Expected a closing SOUL_EOF line; got:\n\(script)")
            return
        }
        #expect(
            terminator == "SOUL_EOF",
            "Heredoc terminator must be flush-left with no leading whitespace; got \(String(reflecting: terminator))."
        )
    }

    /// Sanity: the script embeds the canonical seed body verbatim
    /// (after Swift's `"""` indent strip). Catches accidental drift
    /// between the constant and the script wrapper.
    @Test("seed script embeds the full soulSeedBody verbatim")
    func seedScript_embedsSeedBody() {
        let script = SandboxAgentProvisioner.soulSeedScript()
        #expect(script.contains(SandboxAgentProvisioner.soulSeedBody))
    }
}
