//
//  ModelRuntimeIsHybridTests.swift
//
//  Regression coverage for `ModelRuntime.isKnownHybridModel(name:)` —
//  the substring-matcher that decides whether `installCacheCoordinator`
//  eagerly calls `coordinator.setHybrid(true)` after `enableCaching`.
//
//  Per `vmlx-swift-lm/Libraries/MLXLMCommon/BatchEngine/OMNI-OSAURUS-HOOKUP.md`
//  §5.1 the eager-set is harmless and complementary to BatchEngine's
//  auto-flip. The matcher is the source of truth for which model
//  families get the eager-set; tests below lock the family list so a
//  future drift (renaming the bundle, dropping a family, adding a new
//  hybrid quant tier) shows up as a test diff first.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ModelRuntime.isKnownHybridModel — eager setHybrid family list")
struct ModelRuntimeIsHybridTests {

    // MARK: - Hybrid families that must flip the flag

    @Test("Nemotron-3 (Mamba + Attn + MoE) — all quant tiers + picker form")
    func nemotron3_isHybrid() {
        for id in [
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ",
            "nemotron-3-nano-omni-30b-a3b-mxfp4",  // case-folded picker form
            "dealign.ai/Nemotron-Omni-Nano-JANGTQ4-CRACK",
            "dealign.ai/Nemotron-Omni-Nano-MXFP4-CRACK",
            "nemotron_omni_nano_jangtq",
            "nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            "NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            "JANGQ-AI/Nemotron-3-Reasoning-Future-Variant",  // forward-compat
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "Nemotron-3 family must flip setHybrid eagerly: \(id)"
            )
        }
    }

    @Test("Nemotron-Cascade-2 (older lineage) is also hybrid")
    func nemotronCascade2_isHybrid() {
        for id in [
            "JANGQ-AI/Nemotron-Cascade-2-30B-A3B-JANG_4M",
            "dealignai/Nemotron-Cascade-2-30B-A3B-JANG_2L-CRACK",
        ] {
            #expect(ModelRuntime.isKnownHybridModel(name: id))
        }
    }

    @Test("Qwen 3.5 / 3.6 MoE family + Holo3 — qwen3_5_moe model_type")
    func qwen3MoE_isHybrid() {
        for id in [
            "OsaurusAI/Qwen3.6-35B-A3B-mxfp4",
            "dealignai/Qwen3.6-35B-A3B-MXFP4-CRACK-MTP",
            "qwen3.6-35b-a3b-jangtq4",
            "qwen3.5-vl-9b-8bit",
            "JANGQ-AI/Holo3-35B-A3B-JANGTQ",
            "holo3-35b-a3b-jangtq4",
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "Qwen 3.5/3.6 MoE family + Holo3 must flip setHybrid: \(id)"
            )
        }
    }

    @Test("Bailing / Ling Linear-Attn hybrid family")
    func bailingLing_isHybrid() {
        for id in [
            "OsaurusAI/Ling-2.6-flash-MXFP4",
            "OsaurusAI/Ling-2.6-flash-JANGTQ",
            "bailing_hybrid",
            "bailing_moe_v2_5",
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "Bailing/Ling hybrid family must flip setHybrid eagerly: \(id)"
            )
        }
    }

    /// Zyphra ZAYA1 CCA-attention hybrid: per-layer cache list contains
    /// `ZayaCCACache` (KV + path-dependent `conv_state` + `prev_hs`).
    /// vmlx's `extractSSMStates` / `restoreSSMStates` round-trips the
    /// CCA state through the `SSMStateCache` companion, so eager
    /// `setHybrid(true)` parallels the Mamba families above.
    @Test("Zyphra ZAYA1 CCA hybrid family — eager setHybrid")
    func zaya_isHybrid() {
        for id in [
            "Zyphra/Zaya1-8B-JANGTQ4",
            "Zyphra/Zaya1-8B-MXFP4",
            "OsaurusAI/Zaya1-8B-JANGTQ2",
            "Zaya1-8B-JANGTQ4",  // bare picker
            "zaya1-8b-mxfp4",  // case-folded
            "Zyphra/Zaya-S-7B-Future",  // dash-boundary, forward-compat
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "ZAYA CCA hybrid must flip setHybrid eagerly: \(id)"
            )
        }
    }

    // MARK: - Non-hybrid families that must NOT flip (regression guards)

    /// Dense models without SSM layers must NOT eager-flip the hybrid flag.
    /// Even though `setHybrid(true)` is harmless (the SSM state cache key
    /// just misses on lookup), tagging a dense model as hybrid wastes a
    /// per-request lookup; the matcher should be precise.
    @Test("Dense LLM families do NOT flip setHybrid")
    func denseFamilies_areNotHybrid() {
        for id in [
            "lmstudio-community/gpt-oss-20b-MLX-8bit",
            "lmstudio-community/gpt-oss-120b-MLX-8bit",
            "OsaurusAI/Gemma-4-31B-it-JANG_4M",
            "OsaurusAI/gemma-4-26B-A4B-it-4bit",
            "gemma-4-e2b-it-4bit-osaurus",
            "JANGQ-AI/DeepSeekV4-Flash-JANG_2L",  // dense bf16, not Mamba
            "dealignai/Mistral-Small-4-119B-JANG_2L-CRACK",
            "foundation",  // Apple's built-in
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "dense family must NOT flip setHybrid: \(id)"
            )
        }
    }

    /// MiniMax M2 / M2.7 was historically in the eager-flip list with a
    /// "gated SSM in some layers" comment, but vmlx's `MiniMaxModel` and
    /// `MiniMaxJANGTQModel` use only standard `KVCache` — no `MambaCache`
    /// / `ArraysCache` / `ZayaCCACache`. Removed in the 2026-05-07
    /// vmlx bump cleanup. Locked here so a future regression doesn't
    /// silently re-add the misclassification.
    @Test("MiniMax M2 / M2.7 — dense MoE, NOT Mamba/SSM hybrid")
    func minimaxM2_isNotMambaHybrid() {
        for id in [
            "OsaurusAI/MiniMax-M2.7-JANGTQ",
            "OsaurusAI/MiniMax-M2.7-JANGTQ4",
            "minimax-m2.7-small-jangtq",
            "minimax_m2-mxfp4",
            "MiniMax_M2-3-future",
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "MiniMax has no MambaCache layers — must NOT eager-flip setHybrid: \(id)"
            )
        }
    }

    /// DSV4-Flash JANGTQ uses Compressor/Indexer hybrid attention, but its
    /// per-layer cache list does NOT contain `MambaCache` / `ArraysCache`
    /// (it's a custom `DeepseekV4Cache`). vmlx's auto-flip only matches on
    /// Mamba-style cache types, while DSV4's `HybridPoolCache` flips the
    /// paged-incompatible disk-serializer path in vmlx. Lock that in:
    /// DSV4 must NOT match this SSM-family list.
    @Test("DSV4-Flash JANGTQ does NOT match (uses DeepseekV4Cache, not SSM companion)")
    func dsv4Flash_isNotMambaHybrid() {
        for id in [
            "JANGQ-AI/DeepSeekV4-Flash-JANGTQ",
            "JANGQ-AI/DeepSeek-V4-Flash-JANGTQ2",
            "DeepSeek-V4-Flash-JANGTQ2",
            "deepseekv4-flash-jangtq",
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "DSV4 hybrid attention is a different cache topology than the Mamba families this matcher targets: \(id)"
            )
        }
    }

    /// Poolside Laguna (`model_type=laguna`) — its hybrid is sliding-window
    /// + full attention with per-layer head counts (48 full / 64 SWA),
    /// handled by `RotatingKVCache` + `KVCacheSimple` per-layer in vmlx.
    /// That is NOT the Mamba/SSM hybrid that `setHybrid(true)` is for —
    /// the `setHybrid` flag only controls whether the
    /// `SSMStateCache` companion is consulted on fetch/store, and Laguna
    /// has no SSM-state to round-trip. Match must therefore be NEGATIVE.
    @Test("Laguna (SWA + full attention hybrid) does NOT match (no SSM-state companion)")
    func laguna_isNotMambaHybrid() {
        for id in [
            "OsaurusAI/Laguna-XS.2-mxfp4",
            "OsaurusAI/Laguna-XS.2-JANGTQ2",
            "JANGQ-AI/Laguna-XS.2-JANGTQ2",
            "laguna-xs.2-mxfp4",  // case-folded picker form
            "OsaurusAI/Laguna-S.3-JANGTQ4",  // forward-compat (future variant)
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "Laguna SWA-hybrid is RotatingKVCache + KVCacheSimple, not Mamba — must NOT eager-flip setHybrid: \(id)"
            )
        }
    }

    /// Mistral Medium 3.5 (`model_type=mistral3` outer + `text_config.
    /// model_type=ministral3` inner). Dense GQA 96/8 with Pixtral vision
    /// tower. No Mamba layers, no SSM state. Must NOT match.
    @Test("Mistral Medium 3.5 (dense GQA + Pixtral) does NOT match")
    func mistralMedium35_isNotMambaHybrid() {
        for id in [
            "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4",
            "OsaurusAI/Mistral-Medium-3.5-128B-JANGTQ2",
            "JANGQ-AI/Mistral-Medium-3.5-128B-JANGTQ2",
            "mistral-medium-3.5-128b-mxfp4",
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "Mistral 3.5 dense GQA + Pixtral has no Mamba layers — must NOT eager-flip setHybrid: \(id)"
            )
        }
    }

    // MARK: - Extended hybrid coverage (2026-05-07)

    /// Qwen3-Next (`model_type=qwen3_next`) — newer hybrid MoE that vmlx
    /// dispatches via `Models/Qwen3Next.swift`, with `ArraysCache` companion
    /// slots in the linear-attention path. Same eager-flip rationale as the
    /// 3.5 / 3.6 family — locked here so a registry rename can't drop it.
    @Test("Qwen3-Next hybrid family — eager setHybrid")
    func qwen3Next_isHybrid() {
        for id in [
            "Qwen/Qwen3-Next-80B-MXFP4",
            "qwen3-next-80b-mxfp4",
            "qwen3_next-80b-jangtq",
            "qwen3next-future",
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "Qwen3-Next must flip setHybrid eagerly: \(id)"
            )
        }
    }

    /// IBM Granite-MoE-Hybrid (`model_type=granitemoehybrid`) — Mamba+Attn
    /// MoE; vmlx `Models/GraniteMoeHybrid.swift` allocates `MambaCache`
    /// for the SSM layers. The matcher accepts the collapsed model_type
    /// AND the conventional bundle-id form (`granite-3.0-moe-hybrid-7b`)
    /// gated by `granite` + `moe-hybrid` so dense Granite-MoE
    /// (`granitemoe`, no `hybrid`) stays negative.
    @Test("Granite-MoE-Hybrid family — eager setHybrid")
    func graniteMoeHybrid_isHybrid() {
        for id in [
            "ibm-granite/granite-3.0-moe-hybrid-7b",  // canonical HF id form
            "ibm-granite/granite-4.0-moe-hybrid-13b",  // forward-compat
            "granite-3.0-moe-hybrid-7b",
            "granite-moe-hybrid-7b",
            "granite_moe_hybrid_7b",
            "granitemoehybrid",  // collapsed model_type form
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "Granite-MoE-Hybrid must flip setHybrid eagerly: \(id)"
            )
        }
        // Boundary regression: dense Granite (`granitemoe`, no `hybrid`)
        // and adversarial substrings without the `granite` prefix must
        // NOT trip the matcher.
        for id in [
            "ibm-granite/granite-3.0-moe-3b",  // granitemoe (dense), not hybrid
            "ibm-granite/granite-3.0-3b-instruct",  // dense Granite
            "moe-hybridge",  // contains "moe-hybrid" but no "granite"
            "data/some-moe-hybrid-llm",  // unrelated family
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "Granite matcher must require both `granite` and `moe-hybrid`: \(id)"
            )
        }
    }

    /// Falcon-H1 (`model_type=falcon_h1`) — TII hybrid Mamba+Attn. Locked
    /// boundary regex `(^|/)falcon[-_]?h1([-_].*)?$` rejects adjacent
    /// numerals (`falcon-h11`, `falcon-h12`) and `falconh10` etc.
    @Test("Falcon-H1 hybrid family — eager setHybrid + boundary guard")
    func falconH1_isHybrid() {
        for id in [
            "tiiuae/Falcon-H1-7B",
            "falcon-h1-7b",
            "falcon_h1-7b",
            "falconh1",
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "Falcon-H1 must flip setHybrid eagerly: \(id)"
            )
        }
        // Boundary regression: `falcon-h11` / `falcon-h2` etc. must NOT
        // match — they are different families (or future renames) and
        // the eager-flip would be wrong for the wrong cache topology.
        for id in [
            "falcon-h11",  // adjacent numeral, not Falcon-H1
            "falcon-h10",
            "falcon-h2",  // future Falcon-H2 family — would need its own entry
            "tiiuae/falcon-h11-7b",
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "Falcon-H1 boundary regex must reject adjacent-numeral / sibling families: \(id)"
            )
        }
    }

    /// Baichuan-M1 (`model_type=baichuan_m1`) — Baichuan hybrid (linear +
    /// SWA + Mamba mix). Same boundary regex pattern as Falcon-H1.
    @Test("Baichuan-M1 hybrid family — eager setHybrid + boundary guard")
    func baichuanM1_isHybrid() {
        for id in [
            "baichuan-inc/Baichuan-M1-7B",
            "baichuan-m1-7b",
            "baichuan_m1-7b",
            "baichuanm1",
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "Baichuan-M1 must flip setHybrid eagerly: \(id)"
            )
        }
        for id in [
            "baichuan-m12",  // adjacent numeral
            "baichuan-m10",
            "baichuan-m2",  // future variant — would need its own entry
            "baichuan",  // bare base name
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "Baichuan-M1 boundary regex must reject adjacent-numeral / sibling families: \(id)"
            )
        }
    }

    /// Jamba (`model_type=jamba_3b`) — AI21 hybrid Mamba+Attn-MoE.
    /// Boundary regex `(^|/)jamba[\-_\.0-9]` requires a separator OR digit
    /// after `jamba` so adversarial names like `jambalaya` don't trip.
    @Test("Jamba hybrid family — eager setHybrid + boundary guard")
    func jamba_isHybrid() {
        for id in [
            "ai21/Jamba-3B-Instruct",
            "jamba-3b",
            "jamba_3b",
            "jamba.3b",
            "jamba1.6-7b",
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "Jamba must flip setHybrid eagerly: \(id)"
            )
        }
        for id in [
            "data/jambalaya",
            "jambasaurus",  // letter-after-jamba boundary
            "jamba",  // bare base name with no separator
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "Jamba boundary regex must reject adjacent-letter names: \(id)"
            )
        }
    }

    /// LFM2 / LFM2.5 / LFM2-MoE (`model_type=lfm2` / `lfm2_moe`) —
    /// Liquid Foundation Mamba hybrid. Boundary regex matches the bare
    /// model id `lfm2`, `lfm2-*` / `lfm2_*`, and dot-versioned LFM2.5
    /// bundle ids like `LFM2.5-8B-A1B-JANG_2L`, but rejects `lfm21` /
    /// `lfm22` (next-gen would need its own entry) and `lfm2x`.
    @Test("LFM2 hybrid family — eager setHybrid + boundary guard")
    func lfm2_isHybrid() {
        for id in [
            "LiquidAI/LFM2-7B",
            "lfm2-7b",
            "lfm2_moe",
            "lfm2-moe-7b",
            "lfm2.5",
            "lfm2_5",
            "lfm25",
            "LiquidAI/LFM2.5-8B-A1B",
            "JANGQ-AI/LFM2.5-8B-A1B-JANG_2L",
            "JANGQ-AI/LFM2.5-8B-A1B-MXFP4",
            "lfm2",  // bare base name
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "LFM2 must flip setHybrid eagerly: \(id)"
            )
        }
        for id in [
            "lfm21",  // next-gen, would need own entry
            "lfm22",
            "lfm2x",  // adjacent letter, not a separator
            "lfm2alpha",
            "data/lfm22-foo",
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "LFM2 boundary regex must reject adjacent-numeral / sibling families: \(id)"
            )
        }
    }
}
