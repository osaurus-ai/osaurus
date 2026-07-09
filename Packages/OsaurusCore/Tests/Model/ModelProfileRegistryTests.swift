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
        // a different family-specific option surface. Locking the dispatch
        // order here prevents that drift without injecting hidden defaults.
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

    @Test("Gemma 4 exposes chat Thinking toggle without synthesizing hidden defaults")
    func gemma4_exposesChatThinkingToggle() {
        for id in [
            "gemma-4-26b-a4b-it-jang_4m-crack",
            "dealign.ai/Gemma-4-26B-A4B-it-JANG_4M-CRACK",
            "OsaurusAI/gemma4-it-26b-a4b",
            "gemma-4-12b-it-jang_4m",
            "gemma-4-12b-it-mxfp4",
            "gemma-4-12b-it-mxfp8",
            "dealign.ai/Gemma-4-12B-it-MXFP8-CRACK",
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(profile?.displayName == Gemma4RuntimeProfile.displayName)
            #expect(profile?.thinkingOption?.id == "disableThinking")
            #expect(profile?.thinkingOption?.inverted == true)
            let normalized = ModelProfileRegistry.normalizedOptions(for: id, persisted: nil)
            #expect(normalized["disableThinking"] == nil)

            let explicitOff = ModelProfileRegistry.normalizedOptions(
                for: id,
                persisted: ["disableThinking": .bool(true)]
            )
            #expect(explicitOff["disableThinking"]?.boolValue == true)
            #expect(ModelProfileRegistry.thinkingEnabled(for: id, values: explicitOff) == false)

            let explicitOn = ModelProfileRegistry.normalizedOptions(
                for: id,
                persisted: ["disableThinking": .bool(false)]
            )
            #expect(explicitOn["disableThinking"]?.boolValue == false)
            #expect(ModelProfileRegistry.thinkingEnabled(for: id, values: explicitOn) == true)
        }
    }

    /// Nemotron-3 Reasoning bundles (model_type=nemotron_h, hybrid Mamba+Attn+MoE)
    /// must match `NemotronThinkingProfile`, NOT the generic
    /// `AutoThinkingProfile`. The profile only exposes the family-specific
    /// control surface; absent user/API options must not inject a hidden
    /// `disableThinking` value or any parser-side behavior fix.
    @Test("Nemotron-3 reasoning bundles match NemotronThinkingProfile")
    func nemotron3_matchesNemotronProfile() {
        for id in [
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ",
            "dealign.ai/Nemotron-Omni-Nano-JANGTQ-CRACK",
            "nemotron-omni-nano-jangtq-crack",
            "nemotron-3-nano-omni-30b-a3b-mxfp4",  // case-folded picker form
            "jangq-ai/NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            "NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            "nemotron-3-ultra-550b-a55b-jangtq-1l",
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(
                profile?.displayName == NemotronThinkingProfile.displayName,
                "expected NemotronThinkingProfile for \(id), got \(profile?.displayName ?? "nil")"
            )
            let normalized = ModelProfileRegistry.normalizedOptions(for: id, persisted: nil)
            #expect(normalized["disableThinking"] == nil)
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
                !isNemotron3,
                "matcher must be specific to nemotron-3, not generic nemotron"
            )
        }
    }

    /// Laguna bundles (`model_type=laguna`) must match
    /// `LagunaThinkingProfile` so the chat-input area's reasoning toggle
    /// drives the `enable_thinking` Jinja kwarg honoured by the shipped
    /// `laguna_glm_thinking_v5/chat_template.jinja`. Osaurus exposes the
    /// control but leaves absent values absent so the shipped template/runtime
    /// defaults remain authoritative.
    @Test("Laguna bundles match LagunaThinkingProfile (all quant tiers)")
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
            let normalized = ModelProfileRegistry.normalizedOptions(for: id, persisted: nil)
            #expect(normalized["disableThinking"] == nil)
        }
    }

    /// Ling-2.6 Flash / Bailing uses `enable_thinking` to select the upstream
    /// `detailed thinking on/off` directive. Osaurus exposes the option without
    /// injecting a hidden default; explicit user/API choices still pass through.
    @Test("Ling bundles expose thinking toggle")
    func ling_matchesRuntimeProfileWithThinkingToggle() {
        for id in [
            "OsaurusAI/Ling-2.6-flash-MXFP4",
            "OsaurusAI/Ling-2.6-flash-JANGTQ",
            "ling-2.6-flash-jangtq",  // case-folded picker form
            "JANGQ-AI/Ling-2.6-flash-JANGTQ",  // forward-compat source org
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(
                profile?.displayName == LingRuntimeProfile.displayName,
                "expected LingRuntimeProfile for \(id), got \(profile?.displayName ?? "nil")"
            )
            #expect(profile?.thinkingOption?.id == "disableThinking")
            let normalized = ModelProfileRegistry.normalizedOptions(for: id, persisted: nil)
            #expect(normalized["disableThinking"] == nil)
        }

        for id in ["linguistics-model-7b", "darling-llm"] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(
                profile?.displayName != LingRuntimeProfile.displayName,
                "must not classify \(id) as Ling"
            )
        }
    }

    @Test("Profile option normalization preserves explicit Ling thinking preference")
    func normalizedOptions_preservesExplicitLingThinkingPreference() {
        let staleLing = ModelProfileRegistry.normalizedOptions(
            for: "OsaurusAI/Ling-2.6-flash-JANGTQ",
            persisted: ["disableThinking": .bool(false)]
        )
        #expect(staleLing["disableThinking"]?.boolValue == false)

        let lingUnspecified = ModelProfileRegistry.normalizedOptions(
            for: "OsaurusAI/Ling-2.6-flash-JANGTQ",
            persisted: nil
        )
        #expect(lingUnspecified["disableThinking"] == nil)

        let qwen = ModelProfileRegistry.normalizedOptions(
            for: "OsaurusAI/Qwen3.5-30B-A3B-JANGTQ",
            persisted: [
                "disableThinking": .bool(false),
                "unrelated": .bool(true),
            ]
        )
        #expect(qwen["disableThinking"]?.boolValue == false)
        #expect(qwen["unrelated"] == nil)

        let qwenUnspecified = ModelProfileRegistry.normalizedOptions(
            for: "OsaurusAI/Qwen3.5-30B-A3B-JANGTQ",
            persisted: nil
        )
        #expect(qwenUnspecified["disableThinking"] == nil)
    }

    /// ZAYA1 (Zyphra; `model_type=zaya`) is served as reasoning-capable. The
    /// runtime profile must reserve every canonical bundle name ahead of
    /// `AutoThinkingProfile` so its default stays OFF while still exposing
    /// a real opt-in Thinking toggle. Negative cases lock the matcher
    /// boundary so adjacent names like `zayasaurus-7b` or
    /// `dataset/zayasaurus` do NOT shortcut into the ZAYA profile.
    @Test("Zaya bundles match reasoning runtime profile, boundary-safe")
    func zaya_matchesThinkingProfileWithDefaultOffToggle() {
        for id in [
            "Zyphra/Zaya1-8B-JANGTQ4",
            "Zyphra/Zaya1-8B-MXFP4",
            "OsaurusAI/Zaya1-8B-JANGTQ2",
            "Zaya1-8B-JANGTQ4",  // bare picker form
            "zaya1-8b-mxfp4",  // case-folded
            "Zyphra/Zaya-S-7B-Future",  // dash-boundary, forward-compat
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(
                profile?.displayName == ZayaThinkingProfile.displayName,
                "expected ZayaThinkingProfile for \(id), got \(profile?.displayName ?? "nil")"
            )
            #expect(profile?.thinkingOption?.id == "disableThinking")
            #expect(profile?.thinkingOption?.inverted == true)
            let normalized = ModelProfileRegistry.normalizedOptions(for: id, persisted: nil)
            #expect(normalized["disableThinking"] == nil)
        }

        // Non-text ZAYA and boundary-regression negatives: must NOT classify
        // as text ZAYA thinking profile.
        for id in [
            "Zyphra/Zaya1-VL-8B-JANGTQ4",
            "zaya1-vl-8b-jangtk",
            "dataset/zayasaurus",
            "zayasaurus-7b",
            "lazyaardvark",
            "dazaya-llm",
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(
                profile?.displayName != ZayaThinkingProfile.displayName,
                "must not classify \(id) as Zaya"
            )
        }
    }

    @Test("Profile option normalization preserves explicit Zaya thinking preference")
    func normalizedOptions_preservesExplicitZayaThinkingPreference() {
        let explicitEnabled = ModelProfileRegistry.normalizedOptions(
            for: "Zyphra/Zaya1-8B-JANGTQ4",
            persisted: ["disableThinking": .bool(false)]
        )
        #expect(explicitEnabled["disableThinking"]?.boolValue == false)

        let unspecified = ModelProfileRegistry.normalizedOptions(
            for: "Zyphra/Zaya1-8B-JANGTQ4",
            persisted: nil
        )
        #expect(unspecified["disableThinking"] == nil)
    }

    @Test("Thinking helpers require explicit Zaya values and honor inverted toggle semantics")
    func thinkingHelpers_requireExplicitZayaValuesAndHonorInversion() {
        let model = "Zyphra/Zaya1-8B-JANGTQ4"

        #expect(
            ModelProfileRegistry.boolOptionValue(
                for: model,
                optionId: "disableThinking",
                values: [:]
            ) == nil
        )
        #expect(ModelProfileRegistry.thinkingEnabled(for: model, values: [:]) == nil)
        #expect(
            ModelProfileRegistry.thinkingEnabled(
                for: model,
                values: ["disableThinking": .bool(false)]
            ) == true
        )
        #expect(
            ModelProfileRegistry.thinkingEnabled(
                for: model,
                values: ["disableThinking": .bool(true)]
            ) == false
        )
    }

    @Test("ModelOptionsStore migrates legacy injected defaults without deleting new explicit choices")
    @MainActor
    func modelOptionsStore_migratesLegacyDefaultsButPreservesNewExplicitChoices() throws {
        let qwen = "qwen3.6-\(UUID().uuidString)"
        let dsv4 = "deepseek-v4-flash-\(UUID().uuidString)"
        let qwenKey = "model_options_\(qwen)"
        let dsv4Key = "model_options_\(dsv4)"
        defer {
            UserDefaults.standard.removeObject(forKey: qwenKey)
            UserDefaults.standard.removeObject(forKey: dsv4Key)
        }

        let encoder = JSONEncoder()
        UserDefaults.standard.set(
            try encoder.encode(["reasoningEffort": ModelOptionValue.string("instruct")]),
            forKey: dsv4Key
        )
        #expect(ModelOptionsStore.shared.loadOptions(for: dsv4) == nil)

        ModelOptionsStore.shared.saveOptions(["disableThinking": .bool(true)], for: qwen)
        let explicitQwen = ModelOptionsStore.shared.loadOptions(for: qwen)
        #expect(explicitQwen?["disableThinking"]?.boolValue == true)
    }

    @Test("Hy3 bundles expose native reasoning_effort values")
    func hy3_matchesReasoningEffortProfile() {
        for id in [
            "JANGQ-AI/Hy3-preview-JANGTQ",
            "Tencent/Hy3-preview",
            "hy_v3-preview",
            "hunyuan-v3-jangtq2",
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(profile?.displayName == Hy3ReasoningProfile.displayName)
            let normalized = ModelProfileRegistry.normalizedOptions(for: id, persisted: nil)
            #expect(normalized["reasoningEffort"] == nil)
            #expect(profile?.thinkingOption?.id == nil)
        }

        let explicit = ModelProfileRegistry.normalizedOptions(
            for: "JANGQ-AI/Hy3-preview-JANGTQ",
            persisted: ["reasoningEffort": .string("high")]
        )
        #expect(explicit["reasoningEffort"]?.stringValue == "high")
    }

    @Test("Mistral models expose only none/high reasoning effort and drop stale values")
    func mistral_matchesReasoningEffortProfile() {
        for id in [
            "mistral-medium-3.5",
            "mistral-small-latest",
            "mistralai/mistral-medium-3.5",
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(profile?.displayName == MistralReasoningProfile.displayName)

            guard case .segmented(let segments)? = ModelProfileRegistry.options(for: id).first?.kind
            else {
                Issue.record("expected segmented reasoningEffort option for \(id)")
                continue
            }
            #expect(segments.map(\.id) == ["none", "high"])

            // Values narrowed out of the option set (low/medium) must not reach
            // the wire — Mistral rejects them with HTTP 400.
            for stale in ["low", "medium"] {
                let normalized = ModelProfileRegistry.normalizedOptions(
                    for: id,
                    persisted: ["reasoningEffort": .string(stale)]
                )
                #expect(normalized["reasoningEffort"] == nil)
            }

            let explicit = ModelProfileRegistry.normalizedOptions(
                for: id,
                persisted: ["reasoningEffort": .string("high")]
            )
            #expect(explicit["reasoningEffort"]?.stringValue == "high")
        }
    }

    @Test("DSV4 bundles expose instruct, reasoning, and max modes")
    func dsv4_matchesReasoningModeProfile() {
        for id in [
            "JANGQ-AI/DeepSeek-V4-Flash-JANGTQ-K",
            "DeepSeek-V4-Flash-JANGTQ-K",
            "deepseekv4-flash-jangtq",
            "dsv4-flash-jangtq-k",
        ] {
            let profile = ModelProfileRegistry.profile(for: id)
            #expect(profile?.displayName == DSV4ReasoningProfile.displayName)
            let normalized = ModelProfileRegistry.normalizedOptions(for: id, persisted: nil)
            #expect(normalized["reasoningEffort"] == nil)
            #expect(profile?.thinkingOption?.id == nil)

            let definitions = ModelProfileRegistry.options(for: id)
            guard case .segmented(let segments)? = definitions.first?.kind else {
                Issue.record("DSV4 should expose segmented reasoning modes")
                continue
            }
            #expect(segments.map(\.id) == ["instruct", "high", "max"])
        }

        for id in [
            "deepseek-v3-jangtq",
            "deepseek-r1",
            "notdeepseekv4",
        ] {
            #expect(
                ModelProfileRegistry.profile(for: id)?.displayName != DSV4ReasoningProfile.displayName,
                "DSV4 matcher must not catch unrelated DeepSeek names: \(id)"
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
