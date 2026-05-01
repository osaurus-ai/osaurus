import Foundation
import Testing

@testable import OsaurusCore

/// Guards the profile-matching behavior behind osaurus's "reasoning
/// toggle" and "model options" UI. Each of these tests pins a concrete
/// rule the registry promises so we don't silently regress:
///
/// - `QwenThinkingProfile` should match every modern Qwen3.x family
///   (including 3.5, 3.6) because they share the `enable_thinking`
///   chat-template kwarg. Regressing this removes the toggle from
///   the UI and leaves users with no way to control reasoning.
///
/// - `AutoThinkingProfile` is the catch-all for local reasoning models
///   detected via their chat template. Since `QwenThinkingProfile`
///   registers first, Auto must *not* shadow it for Qwen models.
///
/// - Non-reasoning models must not match any thinking profile.
@Suite("ModelProfileRegistry — reasoning toggle dispatch")
struct ModelProfileRegistryTests {

    @Test("Qwen 3.5 matches QwenThinkingProfile and exposes disableThinking toggle")
    func qwen3_5() {
        let profile = ModelProfileRegistry.profile(for: "qwen3.5-35b-a3b-4bit")
        // Bind the boolean to a local `let` before `#expect` sees it.
        // Direct `#expect(profile != nil)` makes the macro reflect on the
        // operand type for diagnostic capture — and the operand here is
        // `(any ModelProfile.Type)?`, an *optional protocol existential
        // metatype*. Reflecting that through Swift Testing's `Expression.
        // captureValue` walks the existential's witness-table set and
        // segfaults on the GitHub Actions `Apple Virtual Machine 1`
        // macOS 15.7.4 ARM64e runner (worked locally on dev Macs).
        // Reproducer:
        // https://github.com/osaurus-ai/osaurus/actions/runs/24576426664/job/71862829833
        // Binding to `Bool` first makes the macro reflect on `Bool`, which
        // is safe.
        let hasProfile = profile != nil
        #expect(hasProfile, "QwenThinkingProfile should match `qwen3.5-*` ids")
        #expect(profile?.displayName == QwenThinkingProfile.displayName)
        #expect(profile?.thinkingOption?.id == "disableThinking")
        #expect(profile?.thinkingOption?.inverted == true)
    }

    @Test("Qwen 3.6 (MXFP4) matches the same QwenThinkingProfile")
    func qwen3_6_mxfp4() {
        // Substring match `qwen3` in `"qwen3.6-35b-a3b-mxfp4"` should carry
        // over from Qwen 3.5 without a new profile needed — the template
        // still exposes the same `enable_thinking` kwarg.
        let profile = ModelProfileRegistry.profile(for: "qwen3.6-35b-a3b-mxfp4")
        #expect(profile?.displayName == QwenThinkingProfile.displayName)
        #expect(profile?.thinkingOption?.id == "disableThinking")
    }

    @Test("Qwen 3.6 JANGTQ routes to QwenThinkingProfile, not AutoThinkingProfile")
    func qwen3_6_jangtq_notAutoProfile() {
        // JANGTQ is routed at weight-load time by vmlx (via weight_format:
        // "mxtq" in jang_config.json) — osaurus-side the *profile* is still
        // the generic Qwen thinking toggle. If Auto shadowed it we'd get
        // different default thinking-state behavior (Auto defaults ON, Qwen
        // defaults OFF). Locking the dispatch order here prevents that drift.
        let profile = ModelProfileRegistry.profile(for: "qwen3.6-35b-a3b-jangtq2")
        #expect(profile?.displayName == QwenThinkingProfile.displayName)
    }

    @Test("Qwen 3 Coder variants do NOT get a thinking toggle")
    func qwen3_coder_excluded() {
        // Qwen3-Coder is non-thinking only; registering the toggle
        // would show users a control that silently does nothing.
        let profile = ModelProfileRegistry.profile(for: "qwen3-coder-plus")
        // See `qwen3_5()` for why the boolean is bound to a local first
        // instead of being inlined into `#expect(...)`.
        let hasNoThinkingToggle = profile == nil || profile?.thinkingOption == nil
        #expect(hasNoThinkingToggle, "Qwen3-Coder is non-thinking; toggle would silently no-op")
    }

    @Test("Foundation (Apple built-in) does not match any thinking profile")
    func foundation_noProfile() {
        let profile = ModelProfileRegistry.profile(for: "foundation")
        // See `qwen3_5()` for why the boolean is bound to a local first
        // instead of being inlined into `#expect(...)`.
        let hasNoProfile = profile == nil
        #expect(hasNoProfile, "`foundation` is Apple's built-in model and has no MLX/HF profile")
    }

    @Test("Non-reasoning Gemma variants do not get a thinking toggle")
    func gemma_noThinkingToggle() {
        let profile = ModelProfileRegistry.profile(for: "gemma-2-non-reasoning-\(UUID().uuidString)")
        // Use a guaranteed-missing suffix so this stays independent of the
        // developer's locally installed model directory.
        #expect(profile?.thinkingOption == nil)
    }

    /// Nemotron-3 Reasoning bundles (model_type=nemotron_h, hybrid Mamba+Attn+MoE)
    /// must match `NemotronThinkingProfile`, NOT the generic
    /// `AutoThinkingProfile`. The two have different `disableThinking`
    /// defaults — Nemotron defaults to thinking-OFF (defensive, mirroring
    /// `QwenThinkingProfile`) because the SKU's training extends `<think>`
    /// blocks through arbitrary self-verification on validation prompts
    /// (the trapped-thinking pattern documented in
    /// `jang/research/NEMOTRON-OMNI-RUNTIME-2026-04-28.md` §9). Auto would
    /// default ON and surface the loop as visible UX regression.
    @Test("Nemotron-3 reasoning bundles match NemotronThinkingProfile (default OFF)")
    func nemotron3_matchesNemotronProfile() {
        for id in [
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ",
            "nemotron-3-nano-omni-30b-a3b-mxfp4",  // case-folded picker form
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(
                profile?.displayName == NemotronThinkingProfile.displayName,
                "expected NemotronThinkingProfile for \(id), got \(profile?.displayName ?? "nil")"
            )
            // Default-OFF guards against the trapped-thinking pattern.
            let defaultDisable = profile?.defaults["disableThinking"]?.boolValue ?? false
            #expect(
                defaultDisable == true,
                "Nemotron must default disableThinking=true to avoid trapped-thinking loops"
            )
        }
    }

    /// Older "Nemotron-Cascade-2" / "Nemotron-Hyper" bundles use a different
    /// model-type lineage (deprecated NeMo style) and shouldn't accidentally
    /// pick up the new profile. Locks the matcher specificity to `nemotron-3`.
    @Test("Older Nemotron lineages do NOT match NemotronThinkingProfile")
    func olderNemotron_doesNotMatch() {
        for id in [
            "JANGQ-AI/Nemotron-Cascade-2-30B-A3B-JANG_4M",
            "dealignai/Nemotron-3-Super-120B-A12B-JANG_2L-CRACK",
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            // Cascade-2 / Super may still match `AutoThinkingProfile` if their
            // chat template reads `enable_thinking` — the assertion is just
            // that they don't shortcut into the new Nemotron-3-specific
            // profile.
            let isNemotron3 = profile?.displayName == NemotronThinkingProfile.displayName
            #expect(
                !isNemotron3 || id.lowercased().contains("nemotron-3"),
                "matcher must be specific to nemotron-3, not generic nemotron"
            )
        }
    }

    /// Laguna bundles (`model_type=laguna`) must match
    /// `LagunaThinkingProfile` so the chat-input area's reasoning toggle
    /// drives the `enable_thinking` Jinja kwarg honoured by the shipped
    /// `laguna_glm_thinking_v5/chat_template.jinja`. Default-OFF mirrors
    /// the chat template's own default — agentic-coding flows want
    /// straight-to-answer; the toggle lets the user opt into CoT.
    @Test("Laguna bundles match LagunaThinkingProfile (default OFF, all quant tiers)")
    func laguna_matchesLagunaProfile() {
        for id in [
            "OsaurusAI/Laguna-XS.2-mxfp4",
            "OsaurusAI/Laguna-XS.2-JANGTQ2",
            "JANGQ-AI/Laguna-XS.2-JANGTQ2",
            "laguna-xs.2-mxfp4",  // case-folded picker form
            "OsaurusAI/Laguna-S.3-JANGTQ4",  // forward-compat (future variant)
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(
                profile?.displayName == LagunaThinkingProfile.displayName,
                "expected LagunaThinkingProfile for \(id), got \(profile?.displayName ?? "nil")"
            )
            let defaultDisable = profile?.defaults["disableThinking"]?.boolValue ?? false
            #expect(
                defaultDisable == true,
                "Laguna must default disableThinking=true to mirror the chat-template default"
            )
        }
    }

    /// Mistral Medium 3.5 has no thinking toggle today (no `<think>` block
    /// in its chat template). Match must NOT shortcut into a thinking
    /// profile; if it falls through to `AutoThinkingProfile` that's fine
    /// (only activates if the local-reasoning capability detector says
    /// thinking is toggleable). The assertion is the negative one: it
    /// must NOT pick up Nemotron's or Laguna's profile.
    @Test("Mistral Medium 3.5 does NOT match Nemotron or Laguna thinking profiles")
    func mistralMedium35_doesNotMatchThinkingFamilies() {
        for id in [
            "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4",
            "OsaurusAI/Mistral-Medium-3.5-128B-JANGTQ2",
            "mistral-medium-3.5-128b-mxfp4",
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(
                profile?.displayName != NemotronThinkingProfile.displayName,
                "Mistral 3.5 must NOT shortcut into NemotronThinkingProfile: \(id)"
            )
            #expect(
                profile?.displayName != LagunaThinkingProfile.displayName,
                "Mistral 3.5 must NOT shortcut into LagunaThinkingProfile: \(id)"
            )
        }
    }
}
