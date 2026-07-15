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

    // MARK: - Dynamic (catalog-driven) reasoning capabilities

    /// Provider-published capabilities must outrank the static
    /// `OpenAIReasoningProfile` for the same id: without the dynamic
    /// catalog, valid `xhigh`/`max`/`ultra` selections would be dropped by
    /// the static four-tier profile when `ChatEngine` re-normalizes request
    /// options.
    @Test func dynamicCatalog_overridesStaticProfileAndValidatesPersistence() async {
        await RemoteProviderTestLock.shared.run {
            let terraId = "openai-chatgpt/gpt-5.6-terra-\(UUID().uuidString)"
            let previous = RemoteReasoningCapabilityCatalog.snapshot()
            defer { RemoteReasoningCapabilityCatalog.replaceAll(previous) }

            RemoteReasoningCapabilityCatalog.replaceAll([
                terraId: ModelReasoningCapabilities(
                    levels: ["low", "medium", "high", "xhigh", "max", "ultra"].map {
                        .init(id: $0)
                    },
                    defaultLevelId: "medium"
                )
            ])

            // The dynamic option surface replaces the static profile's.
            let definitions = ModelProfileRegistry.options(for: terraId)
            guard case .segmented(let segments)? = definitions.first?.kind else {
                Issue.record("expected a segmented dynamic reasoningEffort option")
                return
            }
            #expect(definitions.count == 1)
            #expect(definitions.first?.id == "reasoningEffort")
            #expect(segments.map(\.id) == ["low", "medium", "high", "xhigh", "max", "ultra"])

            // Wire ids map to ChatGPT-style presentation labels only; the
            // segment id (what reaches the wire) stays the original value.
            #expect(ModelReasoningCapabilities.displayLabel(forEffort: "low") == "Light")
            #expect(ModelReasoningCapabilities.displayLabel(forEffort: "xhigh") == "Extra High")
            #expect(ModelReasoningCapabilities.displayLabel(forEffort: "ultra") == "Ultra")

            // Catalog-advertised values survive normalization…
            for effort in ["xhigh", "max", "ultra"] {
                let normalized = ModelProfileRegistry.normalizedOptions(
                    for: terraId,
                    persisted: ["reasoningEffort": .string(effort)]
                )
                #expect(normalized["reasoningEffort"]?.stringValue == effort)
            }
            // …while unknown/stale ones are dropped rather than sent.
            let stale = ModelProfileRegistry.normalizedOptions(
                for: terraId,
                persisted: ["reasoningEffort": .string("hyperdrive")]
            )
            #expect(stale["reasoningEffort"] == nil)

            // The catalog default is display-only: it surfaces through the
            // effective-effort helper but is never synthesized into options.
            #expect(
                ModelProfileRegistry.effectiveReasoningEffort(for: terraId, values: [:]) == "medium"
            )
            #expect(
                ModelProfileRegistry.effectiveReasoningEffort(
                    for: terraId,
                    values: ["reasoningEffort": .string("ultra")]
                ) == "ultra"
            )
            #expect(ModelProfileRegistry.normalizedOptions(for: terraId, persisted: nil).isEmpty)
        }
    }

    /// The official API-key GPT-5.6 profile is the documented `none`…`max`
    /// contract with a Medium default — and must never leak Codex-only
    /// `ultra`, even when a Codex entry for the same slug coexists in the
    /// catalog under its own provider prefix.
    @Test func publicGPT56Profile_offersNoneThroughMaxAndIsolatesFromCodex() async {
        await RemoteProviderTestLock.shared.run {
            let suffix = UUID().uuidString
            let apiKeyId = "openai/gpt-5.6-sol-\(suffix)"
            let codexId = "openai-chatgpt/gpt-5.6-sol-\(suffix)"
            let previous = RemoteReasoningCapabilityCatalog.snapshot()
            defer { RemoteReasoningCapabilityCatalog.replaceAll(previous) }

            RemoteReasoningCapabilityCatalog.replaceAll([
                apiKeyId: .officialOpenAIGPT56,
                codexId: ModelReasoningCapabilities(
                    levels: ["low", "medium", "high", "xhigh", "max", "ultra"].map {
                        .init(id: $0)
                    },
                    defaultLevelId: "low"
                ),
            ])

            #expect(
                ModelReasoningCapabilities.officialOpenAIGPT56.levels.map(\.id)
                    == ["none", "low", "medium", "high", "xhigh", "max"]
            )
            #expect(ModelReasoningCapabilities.officialOpenAIGPT56.defaultLevelId == "medium")

            // `none` and `max` persist for the API-key route; `ultra` is
            // rejected there while the Codex route (same slug, different
            // provider prefix) keeps it.
            for effort in ["none", "max"] {
                let normalized = ModelProfileRegistry.normalizedOptions(
                    for: apiKeyId,
                    persisted: ["reasoningEffort": .string(effort)]
                )
                #expect(normalized["reasoningEffort"]?.stringValue == effort)
            }
            let ultraOnAPIKey = ModelProfileRegistry.normalizedOptions(
                for: apiKeyId,
                persisted: ["reasoningEffort": .string("ultra")]
            )
            #expect(ultraOnAPIKey["reasoningEffort"] == nil)

            let ultraOnCodex = ModelProfileRegistry.normalizedOptions(
                for: codexId,
                persisted: ["reasoningEffort": .string("ultra")]
            )
            #expect(ultraOnCodex["reasoningEffort"]?.stringValue == "ultra")

            // Per-route defaults stay independent too.
            #expect(
                ModelProfileRegistry.effectiveReasoningEffort(for: apiKeyId, values: [:]) == "medium"
            )
            #expect(
                ModelProfileRegistry.effectiveReasoningEffort(for: codexId, values: [:]) == "low"
            )
        }
    }

    /// Catalog replacement is total: entries absent from the new map (a
    /// disconnected provider, a slug the catalog stopped listing) must fall
    /// back to the static profile immediately.
    @Test func dynamicCatalog_replacementClearsRemovedEntries() async {
        await RemoteProviderTestLock.shared.run {
            let staleId = "openai-chatgpt/gpt-5.6-terra-\(UUID().uuidString)"
            let previous = RemoteReasoningCapabilityCatalog.snapshot()
            defer { RemoteReasoningCapabilityCatalog.replaceAll(previous) }

            RemoteReasoningCapabilityCatalog.replaceAll([
                staleId: ModelReasoningCapabilities(
                    levels: [.init(id: "low"), .init(id: "ultra")],
                    defaultLevelId: "low"
                )
            ])
            #expect(ModelProfileRegistry.reasoningCapabilities(for: staleId) != nil)

            RemoteReasoningCapabilityCatalog.replaceAll([:])
            #expect(ModelProfileRegistry.reasoningCapabilities(for: staleId) == nil)

            // Back on the static OpenAI profile, `ultra` no longer validates.
            let normalized = ModelProfileRegistry.normalizedOptions(
                for: staleId,
                persisted: ["reasoningEffort": .string("ultra")]
            )
            #expect(normalized["reasoningEffort"] == nil)
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

    // MARK: - OpenAI static profile audit (documented per-version contracts)

    /// Segment ids the registry offers for a model's `reasoningEffort`
    /// option, or nil when the model exposes no segmented reasoning option.
    private func reasoningSegmentIds(for modelId: String) -> [String]? {
        guard
            let option = ModelProfileRegistry.options(for: modelId)
                .first(where: { $0.id == "reasoningEffort" }),
            case .segmented(let segments) = option.kind
        else { return nil }
        return segments.map(\.id)
    }

    /// o-series accepts only low/medium/high — `minimal` (valid on original
    /// gpt-5) and `none` (valid on gpt-5.1+) are rejected by the API for
    /// these ids, so the option surface must not offer them and stale
    /// persisted values must be dropped.
    @Test func openAIOSeries_offersLowMediumHighOnly() {
        for id in ["o3", "o3-mini", "o4-mini", "o1-2024-12-17", "openai/o3-pro"] {
            #expect(reasoningSegmentIds(for: id) == ["low", "medium", "high"], "id: \(id)")
        }
        for stale in ["minimal", "none"] {
            let normalized = ModelProfileRegistry.normalizedOptions(
                for: "o3-mini",
                persisted: ["reasoningEffort": .string(stale)]
            )
            #expect(normalized["reasoningEffort"] == nil, "o-series must drop \(stale)")
        }
    }

    /// Original gpt-5 family (no minor version) keeps the minimal…high set.
    @Test func openAIGPT5Original_offersMinimalThroughHigh() {
        for id in ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-codex", "openai/gpt-5-mini"] {
            #expect(
                reasoningSegmentIds(for: id) == ["minimal", "low", "medium", "high"],
                "id: \(id)"
            )
        }
    }

    /// gpt-5.1 replaced `minimal` with `none` (API default `none`) and does
    /// not accept `xhigh`; gpt-5.2+ adds `xhigh`. Stale values from the old
    /// generic four-tier profile must be dropped, not sent.
    @Test func openAIGPT5Minors_matchDocumentedEffortSets() {
        #expect(reasoningSegmentIds(for: "gpt-5.1") == ["none", "low", "medium", "high"])
        #expect(
            ModelProfileRegistry.defaults(for: "gpt-5.1")["reasoningEffort"]?.stringValue == "none"
        )
        for id in ["gpt-5.2", "gpt-5.3-codex", "gpt-5.5", "proxy/gpt-5.5"] {
            #expect(
                reasoningSegmentIds(for: id) == ["none", "low", "medium", "high", "xhigh"],
                "id: \(id)"
            )
        }

        let staleMinimal = ModelProfileRegistry.normalizedOptions(
            for: "gpt-5.1",
            persisted: ["reasoningEffort": .string("minimal")]
        )
        #expect(staleMinimal["reasoningEffort"] == nil)
        let staleXhigh = ModelProfileRegistry.normalizedOptions(
            for: "gpt-5.1",
            persisted: ["reasoningEffort": .string("xhigh")]
        )
        #expect(staleXhigh["reasoningEffort"] == nil)
        let validXhigh = ModelProfileRegistry.normalizedOptions(
            for: "gpt-5.5",
            persisted: ["reasoningEffort": .string("xhigh")]
        )
        #expect(validXhigh["reasoningEffort"]?.stringValue == "xhigh")

        // The umbrella predicate (wire behavior: max_completion_tokens,
        // temperature stripping) still spans every OpenAI reasoning id.
        for id in ["o3-mini", "gpt-5", "gpt-5.1", "gpt-5.5", "gpt-5.6-sol"] {
            #expect(OpenAIReasoningProfile.matches(modelId: id), "umbrella must match \(id)")
        }
    }

    /// Adjustable reasoning exists only on mistral-small-* and
    /// mistral-medium-3-5/3.5. Plain mistral-medium-latest, mistral-large,
    /// and the always-reasoning magistral family reject `reasoning_effort`
    /// with HTTP 400 and must not match the profile.
    @Test func mistral_nonAdjustableModels_doNotMatchReasoningProfile() {
        for id in [
            "mistral-medium-latest", "mistral-large-latest", "magistral-small-latest",
            "magistral-medium-latest", "codestral-latest",
        ] {
            #expect(
                ModelProfileRegistry.profile(for: id)?.displayName
                    != MistralReasoningProfile.displayName,
                "\(id) must not offer reasoning_effort"
            )
        }
        // The 3-5 / 3.5 spellings both stay matched.
        for id in ["mistral-medium-3-5", "mistral-medium-3.5", "mistral-small-latest"] {
            #expect(
                ModelProfileRegistry.profile(for: id)?.displayName
                    == MistralReasoningProfile.displayName,
                "\(id) must keep the reasoning profile"
            )
        }
    }

    /// Gemini 3.1 Flash *Lite* Image supports only 1K output; it must not
    /// inherit the full 3.1 Flash resolution set (512px/2K/4K would be
    /// rejected on the wire). The non-Lite id keeps the extended profile.
    @Test func gemini31FlashLiteImage_isExcludedFromResolutionProfile() {
        #expect(
            !Gemini31FlashImageProfile.matches(modelId: "google/gemini-3.1-flash-lite-image")
        )
        #expect(ModelProfileRegistry.profile(for: "gemini-3.1-flash-lite-image") == nil)
        #expect(Gemini31FlashImageProfile.matches(modelId: "google/gemini-3.1-flash-image"))
    }

    // MARK: - Inline reasoning suffix (model chip "· Effort" label)

    /// The chip suffix uses the dynamic catalog's ChatGPT-style labels when
    /// capabilities exist, the static profile's own segment labels
    /// otherwise, and is absent for models without a segmented reasoning
    /// option. Explicit values win over display defaults.
    @Test func inlineReasoningSuffix_coversDynamicAndStaticProfiles() async {
        await RemoteProviderTestLock.shared.run {
            let terraId = "openai-chatgpt/gpt-5.6-terra-\(UUID().uuidString)"
            let previous = RemoteReasoningCapabilityCatalog.snapshot()
            defer { RemoteReasoningCapabilityCatalog.replaceAll(previous) }
            RemoteReasoningCapabilityCatalog.replaceAll([
                terraId: ModelReasoningCapabilities(
                    levels: ["low", "medium", "xhigh", "ultra"].map { .init(id: $0) },
                    defaultLevelId: "medium"
                )
            ])

            // Dynamic: catalog default, then explicit override.
            #expect(
                ModelProfileRegistry.inlineReasoningSuffixLabel(for: terraId, values: [:])
                    == "Medium"
            )
            #expect(
                ModelProfileRegistry.inlineReasoningSuffixLabel(
                    for: terraId,
                    values: ["reasoningEffort": .string("xhigh")]
                ) == "Extra High"
            )

            // Static segmented profile: profile default label, then the
            // segment's own label for an explicit choice.
            let dsv4 = "dsv4-flash-jangtq-k"
            #expect(
                ModelProfileRegistry.inlineReasoningSuffixLabel(for: dsv4, values: [:])
                    == "Instruct"
            )
            #expect(
                ModelProfileRegistry.inlineReasoningSuffixLabel(
                    for: dsv4,
                    values: ["reasoningEffort": .string("max")]
                ) == "Max"
            )

            // Toggle-only model (Qwen): no segmented reasoning option, no
            // suffix.
            #expect(
                ModelProfileRegistry.inlineReasoningSuffixLabel(
                    for: "qwen3.5-35b-a3b-4bit",
                    values: [:]
                ) == nil
            )
        }
    }
}
