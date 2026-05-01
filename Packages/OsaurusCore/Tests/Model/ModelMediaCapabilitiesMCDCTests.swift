// Copyright © 2026 osaurus.
//
// MC/DC tests for `ModelMediaCapabilities.from(modelId:)` — drives the
// chat composer's drag/drop allowlist. Each modality (image/video/audio)
// must independently flip its flag based on regex/substring matching.
//
// Decision tree from the implementation:
//   D1: matches `nemotron-3-nano-omni|nemotron_h_omni`        → .omni
//   D2: matches `qwen[2-3](\.\d+|_\d+)?[-_]?vl`               → .imageVideo
//   D3: matches `qwen3\.[5-6].*[-_]vl|holo3.*[-_]vl`          → .imageVideo
//   D4: contains `smolvlm|smol-vlm`                           → .imageVideo
//   D5: any of {paligemma, idefics3, fastvlm, llava-qwen2,
//               pixtral, glm-ocr, lfm2-vl, gemma-3, gemma3,
//               gemma-4-it}                                    → .imageOnly
//   D6: matches `mistral[-_](3|medium-3)`                     → .imageOnly
//   D7: matches `mistral[-_]?4.*[-_]vl`                       → .imageOnly
//   else                                                       → .textOnly

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ModelMediaCapabilities — MC/DC coverage")
struct ModelMediaCapabilitiesMCDCTests {

    // MARK: - D1: Nemotron-3 omni (audio + video + image)

    @Test("D1: Nemotron-3-Nano-Omni HF id → .omni")
    func d1_nemotronOmniHF() {
        let cap = ModelMediaCapabilities.from(
            modelId: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4"
        )
        #expect(cap == .omni)
        #expect(cap.supportsAudio)
        #expect(cap.supportsVideo)
        #expect(cap.supportsImage)
    }

    @Test("D1: case-folded picker form → .omni")
    func d1_nemotronOmniLower() {
        #expect(ModelMediaCapabilities.from(modelId: "nemotron-3-nano-omni-30b-a3b-mxfp4") == .omni)
    }

    @Test("D1: nemotron_h_omni alternate naming → .omni")
    func d1_nemotronHOmniUnderscore() {
        #expect(ModelMediaCapabilities.from(modelId: "OsaurusAI/Nemotron_H_Omni-Future") == .omni)
    }

    @Test("D1 boundary: bare 'nemotron-3' (text-only) does NOT match omni")
    func d1_bareNemotron3_notOmni() {
        // Critical: `nemotron-3` text-only bundles must NOT advertise audio.
        let cap = ModelMediaCapabilities.from(modelId: "OsaurusAI/Nemotron-3-30B-Text-MXFP4")
        #expect(
            !cap.supportsAudio,
            "bare nemotron-3 (no -nano-omni) must NOT advertise audio support"
        )
    }

    // MARK: - D2: Qwen 2/2.5/3 VL (image + video)

    @Test("D2: Qwen2-VL → .imageVideo")
    func d2_qwen2VL() {
        let cap = ModelMediaCapabilities.from(modelId: "Qwen/Qwen2-VL-7B-Instruct-MLX-8bit")
        #expect(cap == .imageVideo)
        #expect(!cap.supportsAudio)
    }

    @Test("D2: Qwen2.5-VL with dot variant → .imageVideo")
    func d2_qwen25VL_dot() {
        #expect(
            ModelMediaCapabilities.from(modelId: "Qwen/Qwen2.5-VL-7B-MLX") == .imageVideo
        )
    }

    @Test("D2: qwen2_vl underscore variant → .imageVideo")
    func d2_qwen2VL_underscore() {
        #expect(ModelMediaCapabilities.from(modelId: "qwen2_vl-future-bundle") == .imageVideo)
    }

    @Test("D2: Qwen3-VL → .imageVideo")
    func d2_qwen3VL() {
        #expect(ModelMediaCapabilities.from(modelId: "Qwen/Qwen3-VL-30B-A3B-MLX-8bit") == .imageVideo)
    }

    // MARK: - D3: Qwen 3.5 / 3.6 MoE VL + Holo3 VL (image + video)

    @Test("D3: Qwen3.5-VL → .imageVideo")
    func d3_qwen35VL() {
        #expect(
            ModelMediaCapabilities.from(modelId: "OsaurusAI/Qwen3.5-VL-9B-8bit") == .imageVideo
        )
    }

    @Test("D3: Qwen3.6-VL → .imageVideo")
    func d3_qwen36VL() {
        #expect(
            ModelMediaCapabilities.from(modelId: "OsaurusAI/Qwen3.6-VL-30B-A3B-MXFP4") == .imageVideo
        )
    }

    @Test("D3 boundary: Qwen3.5/3.6 text-only (no -vl) → .textOnly")
    func d3_qwen35Text_notVL() {
        // Without `-vl` suffix, qwen3.5/3.6 falls through to text-only
        #expect(ModelMediaCapabilities.from(modelId: "OsaurusAI/Qwen3.5-35B-A3B-mxfp4") == .textOnly)
        #expect(ModelMediaCapabilities.from(modelId: "OsaurusAI/Qwen3.6-35B-A3B-mxfp4") == .textOnly)
    }

    @Test("D3: Holo3 VL → .imageVideo")
    func d3_holo3VL() {
        #expect(ModelMediaCapabilities.from(modelId: "JANGQ-AI/Holo3-VL-35B-JANGTQ") == .imageVideo)
    }

    // MARK: - D4: SmolVLM 2 (image + video)

    @Test("D4: SmolVLM 2 → .imageVideo")
    func d4_smolVLM2() {
        #expect(ModelMediaCapabilities.from(modelId: "HuggingFaceTB/SmolVLM2-2.2B") == .imageVideo)
        #expect(ModelMediaCapabilities.from(modelId: "smolvlm-instruct") == .imageVideo)
    }

    // MARK: - D5: Image-only VLM families

    @Test("D5: PaliGemma → .imageOnly")
    func d5_paligemma() {
        #expect(ModelMediaCapabilities.from(modelId: "google/paligemma2-3b-mix") == .imageOnly)
    }

    @Test("D5: Idefics 3 → .imageOnly")
    func d5_idefics3() {
        #expect(ModelMediaCapabilities.from(modelId: "HuggingFaceM4/Idefics3-8B") == .imageOnly)
    }

    @Test("D5: FastVLM / LLava-Qwen2 → .imageOnly")
    func d5_fastVLM() {
        #expect(ModelMediaCapabilities.from(modelId: "apple/FastVLM-7B") == .imageOnly)
        #expect(ModelMediaCapabilities.from(modelId: "llava-hf/llava_qwen2-7b") == .imageOnly)
    }

    @Test("D5: Pixtral standalone → .imageOnly")
    func d5_pixtral() {
        #expect(ModelMediaCapabilities.from(modelId: "mistralai/Pixtral-12B-2409") == .imageOnly)
    }

    @Test("D5: GLM OCR → .imageOnly")
    func d5_glmOcr() {
        #expect(ModelMediaCapabilities.from(modelId: "THUDM/GLM-OCR-large") == .imageOnly)
    }

    @Test("D5: LFM2-VL → .imageOnly")
    func d5_lfm2VL() {
        #expect(ModelMediaCapabilities.from(modelId: "LiquidAI/LFM2-VL-1.6B") == .imageOnly)
    }

    @Test("D5: Gemma 3 / 4 (VLM) → .imageOnly")
    func d5_gemmaVLM() {
        #expect(ModelMediaCapabilities.from(modelId: "google/gemma-3-27b-it") == .imageOnly)
        #expect(ModelMediaCapabilities.from(modelId: "OsaurusAI/Gemma-4-it-26B-A4B") == .imageOnly)
    }

    // MARK: - D6: Mistral 3 / 3.5 (image only via Pixtral wrap)

    @Test("D6: Mistral 3 / 3.5 → .imageOnly")
    func d6_mistral3() {
        #expect(ModelMediaCapabilities.from(modelId: "mistralai/Mistral-3-Small-24B") == .imageOnly)
        #expect(
            ModelMediaCapabilities.from(modelId: "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4")
                == .imageOnly
        )
    }

    @Test("D6 boundary: bare 'mistral-7b' (no 3 or medium-3) → .textOnly")
    func d6_bareMistral_notImage() {
        #expect(ModelMediaCapabilities.from(modelId: "mistralai/Mistral-7B-v0.3") == .textOnly)
    }

    // MARK: - D7: Mistral 4 VLM (image only)

    @Test("D7: Mistral 4 VL → .imageOnly")
    func d7_mistral4VL() {
        #expect(
            ModelMediaCapabilities.from(modelId: "OsaurusAI/Mistral-4-VL-Future") == .imageOnly
        )
    }

    @Test("D7 boundary: Mistral 4 dense (no -vl) → .textOnly")
    func d7_mistral4Dense_notImage() {
        #expect(
            ModelMediaCapabilities.from(modelId: "mistralai/Mistral-4-Small-24B-Instruct")
                == .textOnly
        )
    }

    // MARK: - Master FALSE: dense LLM families

    @Test("Master FALSE: dense LLMs all → .textOnly")
    func masterFalse_denseLLMs() {
        let denseFamilies = [
            "lmstudio-community/gpt-oss-20b-MLX-8bit",
            "OsaurusAI/Laguna-XS.2-mxfp4",  // SWA-hybrid LLM, no vision
            "deepseekv4-flash-jangtq",
            "kimi/Kimi-K2-Instruct",
            "OsaurusAI/MiniMax-M2.7-JANGTQ",  // hybrid SSM but text-only
            "nemotron-cascade-2-30b-a3b-jang_4m",  // hybrid SSM but text-only
            // Holo3 base bundles ARE image+video (no -vl suffix needed) —
            // see commit 0a14145 + the imageVideo branch in
            // ModelMediaCapabilities.from(modelId:). Keep them out of the
            // dense-LLM/text-only master-FALSE set.
            "foundation",
            "",  // empty edge case
        ]
        for id in denseFamilies {
            let cap = ModelMediaCapabilities.from(modelId: id)
            #expect(
                cap == .textOnly,
                "\(id) must resolve to text-only (got: \(cap.summary))"
            )
            #expect(!cap.anyMedia, "\(id) anyMedia must be false")
        }
    }

    // MARK: - Capabilities convenience surface

    @Test("Capabilities.summary renders modality list")
    func summary_renders() {
        #expect(ModelMediaCapabilities.Capabilities.textOnly.summary == "text-only")
        #expect(ModelMediaCapabilities.Capabilities.imageOnly.summary == "image")
        #expect(ModelMediaCapabilities.Capabilities.imageVideo.summary == "image + video")
        #expect(ModelMediaCapabilities.Capabilities.omni.summary == "image + video + audio")
    }

    @Test("Capabilities.anyMedia flips on any modality")
    func anyMedia_flips() {
        #expect(!ModelMediaCapabilities.Capabilities.textOnly.anyMedia)
        #expect(ModelMediaCapabilities.Capabilities.imageOnly.anyMedia)
        #expect(ModelMediaCapabilities.Capabilities.imageVideo.anyMedia)
        #expect(ModelMediaCapabilities.Capabilities.omni.anyMedia)
    }
}
