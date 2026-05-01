// Copyright © 2026 osaurus.
//
// MC/DC tests for `ModelRuntime.isKnownHybridModel(name:)`
// (ModelRuntime.swift:462). Substring-match against the families whose
// per-layer cache lists vmlx populates with `MambaCache` / `ArraysCache`
// slots — drives the eager `setHybrid(true)` flip in
// `installCacheCoordinator`.
//
// Decision tree (3 OR-blocks separated by early returns):
//
//   Block 1: contains("nemotron-3") ∨ contains("nemotron-cascade")
//                                   ∨ contains("nemotron_h")    → return true
//   Block 2: contains("qwen3.5")  ∨ contains("qwen3.6")
//                                  ∨ contains("holo3") ∨ contains("holo-3") → return true
//   Block 3: contains("minimax-m2") ∨ contains("minimax_m2")    → return true
//   else: return false
//
// MC/DC requirements per OR block: every condition must independently
// flip the OR's truth value. For an OR of N conditions, that's N+1
// cases per block (1 all-false + N single-true).
//
// Total minimum cases: (3+1) + (4+1) + (2+1) + 1 master-false = 13.

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

    @Test("B1 all-false: bare 'nemotron' (no -3, no -cascade, no _h) does NOT flip")
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

    // MARK: - Block 3: MiniMax M2 family (2 conditions)

    @Test("B3.minimax-m2 substring independently flips Block 3")
    func b3_minimaxDashM2() {
        #expect(ModelRuntime.isKnownHybridModel(name: "OsaurusAI/MiniMax-M2.7-JANGTQ"))
        #expect(ModelRuntime.isKnownHybridModel(name: "minimax-m2.7-small-jangtq"))
    }

    @Test("B3.minimax_m2 underscore variant independently flips Block 3")
    func b3_minimaxUnderscoreM2() {
        // Underscore form (rare but seen in some HF repos).
        #expect(ModelRuntime.isKnownHybridModel(name: "minimax_m2-mxfp4"))
        #expect(ModelRuntime.isKnownHybridModel(name: "MiniMax_M2-3-future"))
    }

    @Test("B3 all-false: minimax-m1 / minimax-text-01 do NOT flip Block 3")
    func b3_allFalse() {
        // MiniMax-Text-01 is dense, not hybrid — must NOT match.
        #expect(!ModelRuntime.isKnownHybridModel(name: "minimax/MiniMax-Text-01"))
        #expect(!ModelRuntime.isKnownHybridModel(name: "minimax-m1-pro"))
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
            "foundation",  // Apple's built-in
            "deepseekv4-flash-jangtq",  // DSV4 has its own cache topology
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

        // Block 3: caps in minimax
        #expect(ModelRuntime.isKnownHybridModel(name: "MINIMAX-M2-mxfp4"))
    }
}
