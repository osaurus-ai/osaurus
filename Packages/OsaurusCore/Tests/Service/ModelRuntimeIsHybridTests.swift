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
            "nemotron-3-nano-omni-30b-a3b-mxfp4",            // case-folded picker form
            "JANGQ-AI/Nemotron-3-Reasoning-Future-Variant",  // forward-compat
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "Nemotron-3 family must flip setHybrid eagerly: \(id)")
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
            "qwen3.6-35b-a3b-jangtq4",
            "qwen3.5-vl-9b-8bit",
            "JANGQ-AI/Holo3-35B-A3B-JANGTQ",
            "holo3-35b-a3b-jangtq4",
        ] {
            #expect(
                ModelRuntime.isKnownHybridModel(name: id),
                "Qwen 3.5/3.6 MoE family + Holo3 must flip setHybrid: \(id)")
        }
    }

    @Test("MiniMax M2 / M2.7 family")
    func minimaxM2_isHybrid() {
        for id in [
            "OsaurusAI/MiniMax-M2.7-JANGTQ",
            "OsaurusAI/MiniMax-M2.7-JANGTQ4",
            "minimax-m2.7-small-jangtq",
        ] {
            #expect(ModelRuntime.isKnownHybridModel(name: id))
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
            "JANGQ-AI/DeepSeekV4-Flash-JANG_2L",   // dense bf16, not Mamba
            "dealignai/Mistral-Small-4-119B-JANG_2L-CRACK",
            "foundation",                          // Apple's built-in
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "dense family must NOT flip setHybrid: \(id)")
        }
    }

    /// DSV4-Flash JANGTQ uses Compressor/Indexer hybrid attention, but its
    /// per-layer cache list does NOT contain `MambaCache` / `ArraysCache`
    /// (it's a custom `DeepseekV4Cache`). vmlx's auto-flip only matches on
    /// Mamba-style cache types, so neither path treats DSV4 as hybrid in
    /// this sense — and DSV4 has its own `DSV4_KV_MODE` env var to control
    /// cache topology. Lock that in: DSV4 must NOT match this family list.
    @Test("DSV4-Flash JANGTQ does NOT match (uses DeepseekV4Cache, controlled via DSV4_KV_MODE)")
    func dsv4Flash_isNotMambaHybrid() {
        for id in [
            "JANGQ-AI/DeepSeekV4-Flash-JANGTQ",
            "deepseekv4-flash-jangtq",
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "DSV4 hybrid attention is a different cache topology than the Mamba families this matcher targets: \(id)")
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
            "laguna-xs.2-mxfp4",            // case-folded picker form
            "OsaurusAI/Laguna-S.3-JANGTQ4", // forward-compat (future variant)
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "Laguna SWA-hybrid is RotatingKVCache + KVCacheSimple, not Mamba — must NOT eager-flip setHybrid: \(id)")
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
                "Mistral 3.5 dense GQA + Pixtral has no Mamba layers — must NOT eager-flip setHybrid: \(id)")
        }
    }
}
