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
//  - The seed write now lives inside the batched per-agent bootstrap
//    (`SandboxManager.agentBootstrapScript`) and is idempotent: an
//    `[ ! -f .../SOUL.md ]` guard wraps the heredoc so a soul the agent
//    has accumulated edits to is never overwritten on re-provisions.
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

    // MARK: - Batched bootstrap script shape

    private func makeScript(
        token: String? = "tok-123",
        soulSeedBody: String? = SandboxAgentProvisioner.soulSeedBody
    ) -> String {
        SandboxManager.agentBootstrapScript(
            agentName: "abc",
            homeDir: "/home/agents/abc",
            bridgeTokenDir: "/run/osaurus",
            token: token,
            soulSeedBody: soulSeedBody
        )
    }

    /// The `[ ! -f .../SOUL.md ]` guard is the idempotency contract.
    /// Without it, every provision would overwrite an accumulated soul
    /// — the spec calls this out explicitly: "never overwrite an
    /// agent's accumulated SOUL".
    @Test("bootstrap script guards the seed write on file absence")
    func bootstrapScript_isIdempotentGuarded() {
        let script = makeScript()
        #expect(script.contains("[ ! -f '/home/agents/abc/SOUL.md' ]"))
        #expect(script.contains("cat > '/home/agents/abc/SOUL.md'"))
        // Ownership must land with the agent, not root — the script
        // runs as root, unlike the old per-user seed exec.
        #expect(script.contains("chown agent-abc:agent-abc '/home/agents/abc/SOUL.md'"))
    }

    /// Single-quoted heredoc terminator disables `$` / backtick / `\`
    /// expansion so the seed body's contents land byte-exact regardless
    /// of the shell environment.
    @Test("bootstrap script uses a single-quoted heredoc terminator")
    func bootstrapScript_usesSingleQuotedHeredoc() {
        let script = makeScript()
        #expect(script.contains("<<'SOUL_EOF'"))
        #expect(
            !script.contains("<<SOUL_EOF"),
            "Heredoc terminator must stay quoted; an unquoted terminator would expand `$` references inside the body and corrupt the seed."
        )
    }

    /// The heredoc terminator must appear on its own line with no
    /// leading whitespace, otherwise the shell treats it as part of the
    /// body and the heredoc never closes.
    @Test("bootstrap script's SOUL_EOF terminator is on its own line, flush left")
    func bootstrapScript_terminatorIsFlushLeft() {
        let script = makeScript()
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
    @Test("bootstrap script embeds the full soulSeedBody verbatim")
    func bootstrapScript_embedsSeedBody() {
        let script = makeScript()
        #expect(script.contains(SandboxAgentProvisioner.soulSeedBody))
    }

    // MARK: - Bootstrap user/token shape

    /// The user-creation half of the bootstrap must guard on `id` (the
    /// old `ensureAgentUser` semantics) and fail loudly via `set -e`
    /// rather than silently continuing after a failed adduser.
    @Test("bootstrap script creates the user idempotently under set -e")
    func bootstrapScript_createsUserIdempotently() {
        let script = makeScript()
        #expect(script.hasPrefix("set -e"))
        #expect(script.contains("if ! id agent-abc >/dev/null 2>&1; then"))
        #expect(script.contains("adduser -D -h '/home/agents/abc' agent-abc"))
        #expect(script.contains("chmod 700 '/home/agents/abc'"))
    }

    /// Token file must be created under `umask 0077` (mode 0600 with no
    /// transient world-readable window) and `printf %s` (byte-exact, no
    /// trailing newline) — same contract `provisionBridgeToken` had.
    @Test("bootstrap script writes the token under umask 0077 with printf %s")
    func bootstrapScript_writesTokenSafely() {
        let script = makeScript(token: "tok-123")
        #expect(script.contains("( umask 0077 && printf %s 'tok-123' > /run/osaurus/agent-abc.token )"))
        #expect(script.contains("chown agent-abc:agent-abc /run/osaurus/agent-abc.token"))
        #expect(script.contains("chmod 0711 /run/osaurus"))
    }

    /// Diagnostics-style callers pass no token / no seed; the script
    /// must degrade to plain user + dirs without leftover fragments.
    @Test("bootstrap script omits token and seed sections when nil")
    func bootstrapScript_omitsOptionalSections() {
        let script = makeScript(token: nil, soulSeedBody: nil)
        #expect(!script.contains(".token"))
        #expect(!script.contains("SOUL"))
        #expect(script.contains("adduser"))
    }
}
