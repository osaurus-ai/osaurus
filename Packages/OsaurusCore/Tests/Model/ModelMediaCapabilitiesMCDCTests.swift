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
//   D5: matches ZAYA1-VL family                                 → .imageOnly
//   D6: any of {paligemma, idefics3, fastvlm, llava-qwen2,
//               pixtral, glm-ocr, lfm2-vl, gemma-3, gemma3,
//               gemma-4-it}                                    → .imageOnly
//   D7: matches `mistral[-_](3|medium-3)`                     → .imageOnly
//   D8: matches `mistral[-_]?4.*[-_]vl`                       → .imageOnly
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

    @Test("D1: short local Nemotron-Omni-Nano form → .omni")
    func d1_nemotronOmniShortLocal() {
        #expect(ModelMediaCapabilities.from(modelId: "Nemotron-Omni-Nano-JANGTQ-CRACK") == .omni)
        #expect(ModelMediaCapabilities.from(modelId: "nemotron-omni-nano-jangtq-crack") == .omni)
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

    @Test("D1 boundary: Nemotron 3 Ultra is text-only unless it is Omni")
    func d1_nemotronUltraTextOnly() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"model_type":"nemotron_h","vision_config":{"hidden_size":1280}}"#
            .write(to: tmp.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let cap = ModelMediaCapabilities.from(
            directory: tmp,
            modelId: "nvidia-nemotron-3-ultra-550b-a55b-jangtq_1l"
        )

        #expect(cap == .textOnly)
    }

    @Test("D1 boundary: Nemotron 3 Ultra composer fallback stays text-only")
    func d1_nemotronUltraComposerFallbackTextOnly() {
        for modelId in [
            "nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            "NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            "nemotron-3-ultra-550b-a55b-jangtq-1l",
        ] {
            let cap = ModelMediaCapabilities.composerCapabilities(
                modelId: modelId,
                fallbackSupportsImages: true
            )
            #expect(
                cap == .textOnly,
                "explicit text-only Nemotron Ultra must not inherit stale image fallback: \(modelId)"
            )
        }
    }

    @Test("Step 3.7 text runtime does not advertise media")
    func step37TextRuntimeDoesNotAdvertiseMedia() {
        #expect(ModelMediaCapabilities.from(modelId: "JANGQ-AI/Step-3.7-Flash-JANG_2L") == .textOnly)
        #expect(ModelMediaCapabilities.from(modelId: "step-3.7-flash-jangtq_k") == .textOnly)
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

    // MARK: - D5: ZAYA1-VL image-only family

    @Test("D5: ZAYA1-VL → .imageOnly")
    func d5_zaya1VL() {
        let cap = ModelMediaCapabilities.from(modelId: "Zyphra/ZAYA1-VL-8B-MXFP4")
        #expect(cap == .imageOnly)
        #expect(cap.supportsImage)
        #expect(!cap.supportsVideo)
        #expect(!cap.supportsAudio)
    }

    @Test("D5: ZAYA1-VL flat picker id → .imageOnly")
    func d5_zaya1VLFlatPicker() {
        #expect(ModelMediaCapabilities.from(modelId: "zaya1-vl-8b-mxfp4") == .imageOnly)
    }

    @Test("D5 boundary: text ZAYA remains text-only")
    func d5_textZaya_notVL() {
        #expect(ModelMediaCapabilities.from(modelId: "Zyphra/ZAYA1-8B-MXFP4") == .textOnly)
        #expect(ModelMediaCapabilities.from(modelId: "zaya1-8b-mxfp4") == .textOnly)
    }

    // MARK: - D6: Image-only VLM families

    @Test("D6: PaliGemma → .imageOnly")
    func d6_paligemma() {
        #expect(ModelMediaCapabilities.from(modelId: "google/paligemma2-3b-mix") == .imageOnly)
    }

    @Test("D6: Idefics 3 → .imageOnly")
    func d6_idefics3() {
        #expect(ModelMediaCapabilities.from(modelId: "HuggingFaceM4/Idefics3-8B") == .imageOnly)
    }

    @Test("D6: FastVLM / LLava-Qwen2 → .imageOnly")
    func d6_fastVLM() {
        #expect(ModelMediaCapabilities.from(modelId: "apple/FastVLM-7B") == .imageOnly)
        #expect(ModelMediaCapabilities.from(modelId: "llava-hf/llava_qwen2-7b") == .imageOnly)
    }

    @Test("D6: Pixtral standalone → .imageOnly")
    func d6_pixtral() {
        #expect(ModelMediaCapabilities.from(modelId: "mistralai/Pixtral-12B-2409") == .imageOnly)
    }

    @Test("D6: GLM OCR → .imageOnly")
    func d6_glmOcr() {
        #expect(ModelMediaCapabilities.from(modelId: "THUDM/GLM-OCR-large") == .imageOnly)
    }

    @Test("D6: LFM2-VL → .imageOnly")
    func d6_lfm2VL() {
        #expect(ModelMediaCapabilities.from(modelId: "LiquidAI/LFM2-VL-1.6B") == .imageOnly)
    }

    @Test("D6: Gemma 3 / 4 (VLM) → .imageOnly")
    func d6_gemmaVLM() {
        #expect(ModelMediaCapabilities.from(modelId: "google/gemma-3-27b-it") == .imageOnly)
        #expect(ModelMediaCapabilities.from(modelId: "OsaurusAI/Gemma-4-it-26B-A4B") == .imageOnly)
        #expect(ModelMediaCapabilities.from(modelId: "gemma-4-12b-it-jang_4m") == .imageOnly)
        #expect(ModelMediaCapabilities.from(modelId: "gemma-4-12b-it-mxfp4") == .imageOnly)
        #expect(ModelMediaCapabilities.from(modelId: "gemma-4-12b-it-mxfp8") == .imageOnly)
    }

    @Test("D6: DiffusionGemma is image-only, not video/audio")
    func d6_diffusionGemmaImageOnly() {
        for modelId in [
            "google/diffusiongemma-26B-A4B-it",
            "OsaurusAI/diffusiongemma-26B-A4B-it-MXFP4",
            "diffusion_gemma",
        ] {
            let cap = ModelMediaCapabilities.from(modelId: modelId)
            #expect(cap == .imageOnly, "\(modelId) must advertise image only")
            #expect(cap.supportsImage)
            #expect(!cap.supportsVideo)
            #expect(!cap.supportsAudio)
        }
    }

    // MARK: - D7: Mistral 3 / 3.5 (image only via Pixtral wrap)

    @Test("D7: Mistral 3 / 3.5 → .imageOnly")
    func d7_mistral3() {
        #expect(ModelMediaCapabilities.from(modelId: "mistralai/Mistral-3-Small-24B") == .imageOnly)
        #expect(
            ModelMediaCapabilities.from(modelId: "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4")
                == .imageOnly
        )
    }

    @Test("D7 boundary: bare 'mistral-7b' (no 3 or medium-3) → .textOnly")
    func d7_bareMistral_notImage() {
        #expect(ModelMediaCapabilities.from(modelId: "mistralai/Mistral-7B-v0.3") == .textOnly)
    }

    // MARK: - D8: Mistral 4 VLM (image only)

    @Test("D8: Mistral 4 VL → .imageOnly")
    func d8_mistral4VL() {
        #expect(
            ModelMediaCapabilities.from(modelId: "OsaurusAI/Mistral-4-VL-Future") == .imageOnly
        )
    }

    @Test("D8 boundary: Mistral 4 dense (no -vl) → .textOnly")
    func d8_mistral4Dense_notImage() {
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

    @Test("Descriptor gates Gemma4 audio per-bundle when only the name is known")
    func descriptor_gemma4AudioBundleGatedByName() {
        // Name-only detection cannot see the weight map, so audio stays
        // unproven with the per-bundle gating message. Installed-bundle
        // detection (`from(directory:)`) flips audio on iff the weight map
        // ships embed_audio.embedding_projection (12B unified + E-series).
        let descriptor = ModelMediaCapabilities.descriptor(
            modelId: "OsaurusAI/Gemma-4-12B-it-MXFP4"
        )

        #expect(descriptor.capabilities == .imageOnly)
        #expect(descriptor.image.status == .supported)
        #expect(descriptor.audio.status == .unproven)
        #expect(!descriptor.audio.isUsable)
        #expect(descriptor.rejectionMessage(for: .audio).contains("Gemma4 audio is enabled per-bundle"))
    }

    @Test("Descriptor keeps Nemotron Omni audio supported")
    func descriptor_nemotronOmniAudioSupported() {
        let descriptor = ModelMediaCapabilities.descriptor(
            modelId: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4"
        )

        #expect(descriptor.capabilities == .omni)
        #expect(descriptor.audio.status == .supported)
        #expect(descriptor.audio.isUsable)
    }

    @Test("Composer capabilities merge image fallback only")
    func composerCapabilities_mergeImageFallbackOnly() {
        #expect(
            ModelMediaCapabilities.composerCapabilities(
                modelId: "unknown-remote-vlm",
                fallbackSupportsImages: true
            ) == .imageOnly
        )
        #expect(
            ModelMediaCapabilities.composerCapabilities(
                modelId: "JANGQ-AI/Laguna-XS.2-JANGTQ",
                fallbackSupportsImages: false
            ) == .textOnly
        )
        #expect(
            ModelMediaCapabilities.composerCapabilities(
                modelId: "Qwen/Qwen3-VL-8B",
                fallbackSupportsImages: false
            ) == .imageVideo
        )
        #expect(
            ModelMediaCapabilities.composerCapabilities(
                modelId: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
                fallbackSupportsImages: false
            ) == .omni
        )
    }
}
