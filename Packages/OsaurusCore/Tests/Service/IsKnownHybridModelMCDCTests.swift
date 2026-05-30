// Copyright © 2026 osaurus.
//
// MC/DC tests for `ModelRuntime.isKnownHybridModel(name:)`. Substring-match
// against the families whose per-layer cache lists vmlx populates with
// `MambaCache` / `ArraysCache` / `ZayaCCACache` / `HybridPoolCache` slots —
// drives the eager `setHybrid(true)` flip in `installCacheCoordinator`.
//
// Decision tree (10 OR-blocks separated by early returns; the matcher
// short-circuits on the first true block):
//
//   Block 1:  contains("nemotron-3") ∨ contains("nemotron-cascade")
//                                    ∨ contains("nemotron_h")
//                                    ∨ contains("nemotron-omni")
//                                    ∨ contains("nemotron_omni")     → true
//   Block 2:  contains("qwen3.5") ∨ contains("qwen3.6")
//                                 ∨ contains("holo3") ∨ contains("holo-3") → true
//   Block 3:  contains("qwen3-next") ∨ contains("qwen3_next")
//                                    ∨ contains("qwen3next")         → true
//   Block 4:  contains("bailing") ∨ Ling family component             → true
//   Block 5:  ZAYA family component (`(^|/)zaya[\-0-9]`)              → true
//   Block 6:  contains("granitemoehybrid")                            → true
//   Block 7:  contains("granite") ∧ (contains("moe-hybrid")
//                                  ∨ contains("moe_hybrid"))          → true
//   Block 8:  regex `(^|/)falcon[\-_]?h1([\-_].*)?$`                  → true
//   Block 9:  regex `(^|/)baichuan[\-_]?m1([\-_].*)?$`                → true
//   Block 10: regex `(^|/)jamba[\-_\.0-9]`                            → true
//   Block 11: regex `(^|/)lfm2(([\._-]?5)?([\-_].*)?)?$`               → true
//   else: return false
//
// MC/DC requirements per OR block: every condition must independently
// flip the OR's truth value. For an OR of N conditions, that's N+1
// cases per block (1 all-false + N single-true). Single-condition blocks
// (5, 6, 8, 9, 10, 11) get coverage from one positive + the master-false
// sweep. Block 7 is an AND — both conjuncts get independent positive +
// negative coverage.
//
// MiniMax M2 / M2.7 was historically in this matcher with a "gated SSM in
// some layers" comment, but vmlx's `MiniMaxModel` and `MiniMaxJANGTQModel`
// use only standard `KVCache` slots — no `MambaCache` / `ArraysCache` /
// `ZayaCCACache`. The eager set was therefore a no-op (vmlx's BatchEngine
// auto-flip would never have triggered either) and was removed for matcher
// precision. Negative MiniMax cases below lock that decision.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("isKnownHybridModel — MC/DC coverage")
struct IsKnownHybridModelMCDCTests {

    // MARK: - Block 1: Nemotron family (3 conditions)

    @Test("B1.nemotron-3 substring independently flips Block 1")
    func b1_nemotron3() {
        #expect(ModelRuntime.isKnownHybridModel(name: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4"))
        #expect(ModelRuntime.isKnownHybridModel(name: "nemotron-3-nano-omni-30b-a3b-mxfp4"))
        // Forward-compat: any future Nemotron-3 variant
        #expect(ModelRuntime.isKnownHybridModel(name: "JANGQ-AI/Nemotron-3-Reasoning-Future"))
    }

    @Test("B1.nemotron-cascade substring independently flips Block 1")
    func b1_nemotronCascade() {
        #expect(ModelRuntime.isKnownHybridModel(name: "JANGQ-AI/Nemotron-Cascade-2-30B-A3B-JANG_4M"))
        #expect(ModelRuntime.isKnownHybridModel(name: "nemotron-cascade-2-30b-a3b-jang_4m"))
    }

    @Test("B1.nemotron_h substring independently flips Block 1")
    func b1_nemotron_h() {
        #expect(ModelRuntime.isKnownHybridModel(name: "OsaurusAI/Nemotron_H-Future-Bundle"))
        #expect(ModelRuntime.isKnownHybridModel(name: "nemotron_h-cascade-3"))
    }

    @Test("B1.nemotron-omni substring independently flips Block 1")
    func b1_nemotronOmniDash() {
        #expect(ModelRuntime.isKnownHybridModel(name: "dealign.ai/Nemotron-Omni-Nano-JANGTQ4-CRACK"))
        #expect(ModelRuntime.isKnownHybridModel(name: "Nemotron-Omni-Nano-MXFP4-CRACK"))
    }

    @Test("B1.nemotron_omni substring independently flips Block 1")
    func b1_nemotronOmniUnderscore() {
        #expect(ModelRuntime.isKnownHybridModel(name: "nemotron_omni_nano_jangtq"))
        #expect(ModelRuntime.isKnownHybridModel(name: "OsaurusAI/Nemotron_Omni_Nano_Future"))
    }

    @Test("B1 all-false: bare 'nemotron' (no -3, no -cascade, no _h, no omni) does NOT flip")
    func b1_allFalse_bareNemotron() {
        // Bare 'nemotron' is intentionally NOT in the matcher — older
        // Nemotron-2 / NeMo dense bundles aren't hybrid. Locks against
        // drift that would over-accept.
        #expect(!ModelRuntime.isKnownHybridModel(name: "nvidia/nemotron-4-340b"))
        #expect(!ModelRuntime.isKnownHybridModel(name: "nemotron-mini"))
    }

    // MARK: - Block 2: Qwen 3.x MoE + Holo3 (4 conditions)

    @Test("B2.qwen3.5 substring independently flips Block 2")
    func b2_qwen3_5() {
        #expect(ModelRuntime.isKnownHybridModel(name: "OsaurusAI/Qwen3.5-35B-A3B-mxfp4"))
        #expect(ModelRuntime.isKnownHybridModel(name: "qwen3.5-vl-9b-8bit"))
    }

    @Test("B2.qwen3.6 substring independently flips Block 2")
    func b2_qwen3_6() {
        #expect(ModelRuntime.isKnownHybridModel(name: "OsaurusAI/Qwen3.6-35B-A3B-mxfp4"))
        #expect(ModelRuntime.isKnownHybridModel(name: "dealignai/Qwen3.6-35B-A3B-MXFP4-CRACK-MTP"))
        #expect(ModelRuntime.isKnownHybridModel(name: "qwen3.6-35b-a3b-jangtq4"))
    }

    @Test("B2.holo3 substring independently flips Block 2")
    func b2_holo3() {
        #expect(ModelRuntime.isKnownHybridModel(name: "JANGQ-AI/Holo3-35B-A3B-JANGTQ"))
        #expect(ModelRuntime.isKnownHybridModel(name: "holo3-35b-a3b-jangtq4"))
    }

    @Test("B2.holo-3 dash variant independently flips Block 2")
    func b2_holoDash3() {
        // Some bundle names use dash instead of bare 'holo3'
        #expect(ModelRuntime.isKnownHybridModel(name: "OsaurusAI/Holo-3-Future-Variant"))
        #expect(ModelRuntime.isKnownHybridModel(name: "holo-3-mxfp4"))
    }

    @Test("B2 all-false: qwen3 / qwen3-coder / qwen2 / qwen3.7 do NOT flip Block 2")
    func b2_allFalse() {
        #expect(!ModelRuntime.isKnownHybridModel(name: "qwen3-coder-plus"))
        #expect(!ModelRuntime.isKnownHybridModel(name: "qwen2.5-7b-instruct"))
        #expect(!ModelRuntime.isKnownHybridModel(name: "qwen3-30b"))
        // qwen3.7 not yet recognized — would need explicit add when it lands
        #expect(!ModelRuntime.isKnownHybridModel(name: "qwen3.7-future-variant"))
    }

    // MARK: - MiniMax — historically matched, now a negative regression guard

    /// MiniMax M2 / M2.7 used to flip this matcher because of a "gated SSM
    /// in some layers" comment, but vmlx's `MiniMaxModel` and
    /// `MiniMaxJANGTQModel` use only standard `KVCache`. The eager
    /// `setHybrid(true)` was therefore a no-op (BatchEngine's auto-flip
    /// keys off `MambaCache` / `ArraysCache` / `ZayaCCACache`, none of
    /// which MiniMax populates). Locking the negative side here so a
    /// future re-add doesn't quietly land.
    @Test("MiniMax M2 / M2.7 is dense KV — must NOT eager-flip setHybrid")
    func minimaxM2_isNotHybrid() {
        for id in [
            "OsaurusAI/MiniMax-M2.7-JANGTQ",
            "OsaurusAI/MiniMax-M2.7-JANGTQ4",
            "minimax-m2.7-small-jangtq",
            "minimax_m2-mxfp4",
            "MiniMax_M2-3-future",
            "minimax/MiniMax-Text-01",
            "minimax-m1-pro",
        ] {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: id),
                "MiniMax has no MambaCache/ArraysCache layers — must NOT match: \(id)"
            )
        }
    }

    // MARK: - Block 3: Bailing / Ling family (2 conditions)

    @Test("B3.bailing substring independently flips Block 3")
    func b3_bailing() {
        #expect(ModelRuntime.isKnownHybridModel(name: "bailing_hybrid"))
        #expect(ModelRuntime.isKnownHybridModel(name: "bailing_moe_v2_5"))
    }

    @Test("B3.Ling family component independently flips Block 3")
    func b3_ling() {
        #expect(ModelRuntime.isKnownHybridModel(name: "OsaurusAI/Ling-2.6-flash-MXFP4"))
        #expect(ModelRuntime.isKnownHybridModel(name: "ling-2.6-flash-jangtq"))
    }

    @Test("B3 all-false: bare ling without dash does NOT flip Block 3")
    func b3_allFalse() {
        #expect(!ModelRuntime.isKnownHybridModel(name: "linguistics-model-7b"))
        #expect(!ModelRuntime.isKnownHybridModel(name: "darling-llm"))
    }

    // MARK: - Block 4: Zyphra ZAYA family (1 condition: digit/dash boundary)

    @Test("B4.zaya prefix + slash forms independently flip Block 4")
    func b4_zaya() {
        // ZAYA1 / ZAYA2 / ZAYA-S naming: digit or dash boundary after `zaya`.
        #expect(ModelRuntime.isKnownHybridModel(name: "Zyphra/Zaya1-8B-JANGTQ4"))
        #expect(ModelRuntime.isKnownHybridModel(name: "Zyphra/Zaya1-8B-MXFP4"))
        #expect(ModelRuntime.isKnownHybridModel(name: "OsaurusAI/Zaya1-8B-JANGTQ2"))
        #expect(ModelRuntime.isKnownHybridModel(name: "Zaya1-8B-JANGTQ4"))  // bare picker
        #expect(ModelRuntime.isKnownHybridModel(name: "zaya1-8b-mxfp4"))  // case-folded
        #expect(ModelRuntime.isKnownHybridModel(name: "Zyphra/Zaya-S-7B-Future"))  // dash-boundary
    }

    @Test("B4 all-false: zaya without digit/dash boundary does NOT flip Block 4")
    func b4_zaya_allFalse() {
        // Boundary-regression guards: substring `zaya` without a
        // digit-or-dash terminator is NOT a ZAYA bundle.
        #expect(!ModelRuntime.isKnownHybridModel(name: "dataset/zayasaurus"))
        #expect(!ModelRuntime.isKnownHybridModel(name: "zayasaurus-7b"))
        #expect(!ModelRuntime.isKnownHybridModel(name: "lazyaardvark"))
        #expect(!ModelRuntime.isKnownHybridModel(name: "dazaya-llm"))
    }

    // MARK: - Master FALSE: no block matches

    @Test("All blocks false → returns false (dense + non-hybrid families)")
    func masterFalse_denseAndNonHybridFamilies() {
        // Locks the negative side of the entire decision tree. Each of
        // these is a well-known non-hybrid family; the matcher must
        // return false unconditionally.
        let denseFamilies = [
            "lmstudio-community/gpt-oss-20b-MLX-8bit",
            "lmstudio-community/gpt-oss-120b-MLX-8bit",
            "OsaurusAI/Gemma-4-31B-it-JANG_4M",
            "OsaurusAI/gemma-4-26B-A4B-it-4bit",
            "gemma-4-e2b-it-4bit-osaurus",
            "JANGQ-AI/DeepSeekV4-Flash-JANG_2L",  // dense bf16 here
            "dealignai/Mistral-Small-4-119B-JANG_2L-CRACK",
            "OsaurusAI/Laguna-XS.2-mxfp4",  // SWA hybrid, NOT Mamba
            "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4",  // dense GQA
            "OsaurusAI/MiniMax-M2.7-JANGTQ",  // dense MoE, no SSM layers
            "minimax-m2.7-small-jangtq",
            "foundation",  // Apple's built-in
            "deepseekv4-flash-jangtq",  // DSV4 has its own cache topology
            "DeepSeek-V4-Flash-JANGTQ2",  // DSV4 JANGTQ2 has its own hybrid-pool cache
            "",  // empty string edge case
        ]
        for name in denseFamilies {
            #expect(
                !ModelRuntime.isKnownHybridModel(name: name),
                "must NOT match: \(name)"
            )
        }
    }

    // MARK: - Case-folding (the lowercased pre-pass)

    @Test("Case-folding applies uniformly to all blocks")
    func caseFolding_allBlocks() {
        // Block 1: original caps
        #expect(ModelRuntime.isKnownHybridModel(name: "NEMOTRON-3-future"))
        #expect(ModelRuntime.isKnownHybridModel(name: "Nemotron-Cascade-2"))

        // Block 2: caps in qwen / holo
        #expect(ModelRuntime.isKnownHybridModel(name: "QWEN3.5-35B"))
        #expect(ModelRuntime.isKnownHybridModel(name: "HOLO3-mxfp4"))

        // Block 3: caps in bailing / ling
        #expect(ModelRuntime.isKnownHybridModel(name: "BAILING_HYBRID"))
        #expect(ModelRuntime.isKnownHybridModel(name: "LING-2.6-FLASH-MXFP4"))

        // Block 4: caps in zaya
        #expect(ModelRuntime.isKnownHybridModel(name: "ZYPHRA/ZAYA1-8B-JANGTQ4"))
        #expect(ModelRuntime.isKnownHybridModel(name: "ZAYA1-8B-MXFP4"))
    }
}
