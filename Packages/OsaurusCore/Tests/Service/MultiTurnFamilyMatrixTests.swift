//
// Multi-turn × per-family capability matrix on the OSAURUS side.
//
// Companion to vmlx's MultiTurnFamilyMatrixTests. That suite locks the
// engine-side parser/dispatch invariants. This suite locks the osaurus-
// side translation invariants: model_id → media-capability → composer
// drag-drop → MessageContentPart routing.
//
// Why split: the engine doesn't know "this user has a flat-layout
// `MiniMax-M2.7-Small-JANGTQ` directory and tried to drop an image on
// it" — the engine just gets a chat message with parts. Osaurus is the
// layer that gates which parts even get to be in the message in the
// first place. A regression here means the engine never sees the
// image (UI silently rejects it) or sees an image the engine can't
// process (model loads but generation fails).
//
// Sections:
//   A. Capability detection by `model_id` (pre-load fast path)
//   B. Capability detection by bundle directory (post-load refined)
//   C. Multi-turn capability stability — switching models doesn't
//      orphan or alias capability for the prior model
//   D. Per-family multi-turn drag-drop accept matrix
//   E. Real-world bundle name coverage — every name we ship in the
//      curated catalog AND every name found on Eric's ext drive
//

import Foundation
import Testing

@testable import OsaurusCore

// =====================================================================
// MARK: - A. Capability detection by model_id (pre-load fast path)
// =====================================================================

@Suite("ModelMediaCapabilities — model_id matrix (pre-load)")
struct CapabilityFromModelIdTests {

    /// Omni: image + video + audio. Only Nemotron-3-Nano-Omni today.
    @Test(arguments: [
        "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
        "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
        "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ2",
        "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-Multimodal-Addon",
        "JANGQ-AI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
        "Nemotron-3-Nano-Omni-30B-A3B-MXFP4",  // flat-layout
        "nemotron-3-nano-omni-30b-a3b-mxfp4",  // lowercased
        "NEMOTRON-3-NANO-OMNI-30B-A3B-MXFP4",  // uppercased
    ])
    func omniBundles(_ id: String) {
        let cap = ModelMediaCapabilities.from(modelId: id)
        #expect(cap == .omni, "[\(id)] must resolve to omni")
        #expect(cap.supportsImage)
        #expect(cap.supportsVideo)
        #expect(cap.supportsAudio)
    }

    /// Image + video (no audio): Qwen 2/2.5/3 VL families, Qwen 3.5/3.6 VL,
    /// SmolVLM2.
    @Test(arguments: [
        "Qwen/Qwen2-VL-7B-Instruct",
        "mlx-community/Qwen2.5-VL-32B-Instruct-mxfp4",
        "Qwen/Qwen3-VL-8B",
        "mlx-community/SmolVLM2-2.2B-Instruct",
        "OsaurusAI/Holo3-35B-A3B-vl-mxfp4",
        "OsaurusAI/Holo3-35B-A3B-mxfp4",  // outer qwen3_5_moe + vision_config (no -vl in name)
        "OsaurusAI/Qwen3.5-VL-mxfp4",
    ])
    func imageVideoBundles(_ id: String) {
        let cap = ModelMediaCapabilities.from(modelId: id)
        #expect(cap == .imageVideo, "[\(id)] must resolve to imageVideo")
        #expect(cap.supportsImage)
        #expect(cap.supportsVideo)
        #expect(!cap.supportsAudio, "video-only families must not claim audio")
    }

    /// Image only: every other VLM family.
    @Test(arguments: [
        "google/paligemma-3b-pt-224",
        "HuggingFaceM4/Idefics3-8B",
        "apple/FastVLM-7B",
        "mistral-community/pixtral-12b",
        "mlx-community/Mistral-Medium-3.5-128B-mxfp4",
        "OsaurusAI/Mistral-Medium-3.5-128B-JANGTQ",
        "thu-ml/glm_ocr-9b",
        "LiquidAI/LFM2-VL-1.6B",
        "google/gemma-3-12b-it",
        "google/gemma-4-it-mxfp4",
    ])
    func imageOnlyBundles(_ id: String) {
        let cap = ModelMediaCapabilities.from(modelId: id)
        #expect(cap == .imageOnly, "[\(id)] must resolve to imageOnly")
        #expect(cap.supportsImage)
        #expect(!cap.supportsVideo)
        #expect(!cap.supportsAudio)
    }

    /// Text only: every dense LLM and reasoning LLM (no vision).
    /// Critical that none of these accidentally trigger a media match
    /// from the substring patterns — a Laguna LLM bundle named
    /// `Laguna-XS.2-mxfp4` must NOT pick up the `imageVideo` regex.
    @Test(arguments: [
        // NOTE: Holo3 family was previously listed as text-only here based
        // on the lack of a `-vl` suffix; in fact Holo3 bundles ship a
        // vision_config under outer model_type=qwen3_5_moe and route via
        // Qwen35MoE VLM. Moved to imageVideoBundles below — see
        // ModelMediaCapabilities Holo3 family pattern.
        "JANGQ-AI/Laguna-XS.2-JANGTQ",
        "OsaurusAI/Laguna-XS.2-mxfp4",
        "JANGQ-AI/Laguna-XS.2-mxfp4",
        "JANGQ-AI/MiniMax-M2.7-JANGTQ4",
        "JANGQ-AI/MiniMax-M2.7-Small-JANGTQ",
        "JANGQ-AI/DeepSeek-V4-Flash-JANGTQ",
        "JANGQ-AI/DeepSeek-V4-Flash-JANGTQ2",
        "JANGQ-AI/Kimi-K2.6-Med-JANGTQ",
        "JANGQ-AI/Kimi-K2.6-Small-JANGTQ",
        "JANGQ-AI/Qwen3.5-35B-A3B-JANG_4K",        // text-only Qwen3.5 (no `vl`)
        "JANGQ-AI/Qwen3.6-35B-A3B-JANGTQ4",        // text-only Qwen3.6
        // NOTE: Mistral 3 / 3.5 LLM-only bundles can't be disambiguated
        // from VLM bundles by id alone (both ship with `mistral-medium-3.5`
        // in the name); the `from(directory:modelId:)` post-load path
        // refines via vision_config presence.
        "meta-llama/Llama-3.3-70B-Instruct",
        "microsoft/Phi-4-mini",
        // Flat-layout local ids
        "MiniMax-M2.7-Small-JANGTQ",
        "Laguna-XS.2-JANGTQ",
        "Kimi-K2.6-Med-JANGTQ",
    ])
    func textOnlyBundles(_ id: String) {
        let cap = ModelMediaCapabilities.from(modelId: id)
        #expect(cap == .textOnly, "[\(id)] must resolve to textOnly")
        #expect(!cap.anyMedia)
    }

    /// Empty / nonsense ids: text-only fallback, never crash.
    @Test(arguments: ["", " ", "?", "garbage", "//", "no-slash-id"])
    func degenerateIdsAreTextOnly(_ id: String) {
        let cap = ModelMediaCapabilities.from(modelId: id)
        #expect(cap == .textOnly)
    }
}

// =====================================================================
// MARK: - B. Capability detection by bundle directory (post-load)
// =====================================================================

@Suite("ModelMediaCapabilities — bundle directory matrix (post-load)")
struct CapabilityFromDirectoryTests {

    private func makeBundle(
        modelType: String,
        hasVisionConfig: Bool,
        hasOmniSidecar: Bool
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-mediacap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var configJSON: [String: Any] = ["model_type": modelType]
        if hasVisionConfig {
            configJSON["vision_config"] = ["image_size": 224]
        }
        let data = try JSONSerialization.data(withJSONObject: configJSON)
        try data.write(to: dir.appendingPathComponent("config.json"))

        if hasOmniSidecar {
            let omniPayload: [String: Any] = ["enabled": true]
            let omniData = try JSONSerialization.data(withJSONObject: omniPayload)
            try omniData.write(to: dir.appendingPathComponent("config_omni.json"))
        }
        return dir
    }

    /// `config_omni.json` sidecar trumps everything else — even if the
    /// model_type itself is something boring, the sidecar means the omni
    /// pipeline is wired (Parakeet ASR + RADIO ViT). Required for the
    /// Nemotron-3 Multimodal-Addon which ships JUST the audio/video
    /// preprocessor on top of an existing text bundle.
    @Test func omniSidecarTrumpsModelType() throws {
        let dir = try makeBundle(
            modelType: "nemotron_h",  // base text type
            hasVisionConfig: false,
            hasOmniSidecar: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = ModelMediaCapabilities.from(directory: dir, modelId: "Nemotron-Whatever")
        #expect(cap == .omni, "config_omni.json must resolve to omni")
    }

    /// Vision config + video-capable model_type → imageVideo.
    @Test(arguments: [
        "qwen2_vl", "qwen2_5_vl", "qwen3_vl",
        "qwen3_5", "qwen3_5_moe",
        "smolvlm",
        "nemotron_h_omni",
    ])
    func visionConfigVideoCapableFamilies(_ modelType: String) throws {
        let dir = try makeBundle(modelType: modelType, hasVisionConfig: true, hasOmniSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = ModelMediaCapabilities.from(directory: dir, modelId: "test")
        #expect(cap == .imageVideo, "[\(modelType)] vision_config + video-capable → imageVideo")
    }

    /// Vision config + image-only model_type → imageOnly.
    @Test(arguments: [
        "paligemma", "idefics3", "smolvlm2",
        "fastvlm", "llava_qwen2",
        "pixtral", "mistral3", "mistral3_text",
        "lfm2_vl", "glm_ocr",
        "gemma3", "gemma4",
    ])
    func visionConfigImageOnlyFamilies(_ modelType: String) throws {
        let dir = try makeBundle(modelType: modelType, hasVisionConfig: true, hasOmniSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = ModelMediaCapabilities.from(directory: dir, modelId: "test")
        // smolvlm2 isn't in the explicit allowlist for imageVideo, only
        // bare "smolvlm" is. Document that explicitly.
        if modelType == "smolvlm2" {
            #expect(cap == .imageOnly,
                "smolvlm2 has vision_config but not in video allowlist → imageOnly")
        } else {
            #expect(cap == .imageOnly, "[\(modelType)] should resolve to imageOnly")
        }
    }

    /// No vision_config → textOnly regardless of model_type.
    @Test(arguments: [
        "llama", "mistral", "mistral4",
        "qwen3", "qwen3_5_moe", "qwen3_next",
        "nemotron_h", "deepseek_v4", "minimax_m2",
        "kimi_k2", "kimi_k25", "glm4_moe", "laguna",
    ])
    func noVisionConfigIsTextOnly(_ modelType: String) throws {
        let dir = try makeBundle(modelType: modelType, hasVisionConfig: false, hasOmniSidecar: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = ModelMediaCapabilities.from(directory: dir, modelId: "test")
        #expect(cap == .textOnly, "[\(modelType)] no vision_config → textOnly")
    }

    /// Unreadable / missing config.json → falls back to model_id matcher.
    @Test func unreadableConfigFallsBackToModelId() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-mediacap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // No config.json present.
        let cap = ModelMediaCapabilities.from(
            directory: dir,
            modelId: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4")
        #expect(cap == .omni, "missing config.json must fall back to model_id matcher")
    }
}

// =====================================================================
// MARK: - C. Multi-turn capability stability across model switches
// =====================================================================

@Suite("Multi-turn capability — switching between models")
struct MultiTurnModelSwitchTests {

    /// Switching turn-by-turn between an omni model, a text-only LLM,
    /// and a VL model: each call to `from(modelId:)` must resolve
    /// independently — no cached state from prior calls.
    @Test func threeTurnAlternatingModelSwitch() {
        let ids = [
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",  // omni
            "JANGQ-AI/Laguna-XS.2-JANGTQ",                   // text-only
            "Qwen/Qwen3-VL-8B",                              // imageVideo
            "JANGQ-AI/MiniMax-M2.7-Small-JANGTQ",            // text-only
            "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4", // omni again
        ]
        let expected: [ModelMediaCapabilities.Capabilities] = [
            .omni, .textOnly, .imageVideo, .textOnly, .omni,
        ]
        for (i, id) in ids.enumerated() {
            let cap = ModelMediaCapabilities.from(modelId: id)
            #expect(cap == expected[i],
                "turn \(i): [\(id)] expected \(expected[i].summary), got \(cap.summary)")
        }
    }

    /// Repeated calls for the same id are stable — pure function.
    @Test(arguments: [
        "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
        "JANGQ-AI/Laguna-XS.2-JANGTQ",
        "Qwen/Qwen3-VL-8B",
    ])
    func repeatedCallsForSameIdAreStable(_ id: String) {
        let r1 = ModelMediaCapabilities.from(modelId: id)
        let r2 = ModelMediaCapabilities.from(modelId: id)
        let r3 = ModelMediaCapabilities.from(modelId: id)
        #expect(r1 == r2 && r2 == r3)
    }
}

// =====================================================================
// MARK: - D. Drag-drop accept matrix per family
// =====================================================================

@Suite("Drag-drop accept matrix — per-family modality gating")
struct DragDropAcceptMatrixTests {

    /// Model is text-only → composer must reject all media drops.
    @Test func textOnlyRejectsAllMedia() {
        let cap = ModelMediaCapabilities.from(modelId: "JANGQ-AI/Laguna-XS.2-JANGTQ")
        #expect(!cap.supportsImage, "text-only must reject image drop")
        #expect(!cap.supportsVideo, "text-only must reject video drop")
        #expect(!cap.supportsAudio, "text-only must reject audio drop")
        #expect(!cap.anyMedia)
    }

    /// Image-only model → image drop OK, video and audio rejected.
    @Test func imageOnlyAcceptsImageRejectsVideoAudio() {
        let cap = ModelMediaCapabilities.from(modelId: "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4")
        #expect(cap.supportsImage)
        #expect(!cap.supportsVideo)
        #expect(!cap.supportsAudio)
    }

    /// VL model with video (Qwen 3 VL) → image + video OK, audio rejected.
    @Test func imageVideoAcceptsAudioRejected() {
        let cap = ModelMediaCapabilities.from(modelId: "Qwen/Qwen3-VL-8B")
        #expect(cap.supportsImage)
        #expect(cap.supportsVideo)
        #expect(!cap.supportsAudio,
            "Qwen 3 VL has no audio path — audio drop must be rejected")
    }

    /// Omni model → all three modalities accepted.
    @Test func omniAcceptsAll() {
        let cap = ModelMediaCapabilities.from(
            modelId: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4")
        #expect(cap.supportsImage)
        #expect(cap.supportsVideo)
        #expect(cap.supportsAudio)
    }

    /// Multi-turn drag-drop: turn 1 user drops audio on omni, turn 2
    /// they switch to a Mistral 3 image-only model and drop image, turn
    /// 3 they go back to omni and drop video. Each turn's accept matrix
    /// is computed from the current model; no cross-turn aliasing.
    @Test func multiTurnDragDrop_perTurnAccept() {
        struct Turn { let modelId: String; let attempted: String; let shouldAccept: Bool }
        let turns: [Turn] = [
            // Turn 1: omni model + audio attachment → accept
            .init(modelId: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
                  attempted: "audio", shouldAccept: true),
            // Turn 2: switch to Mistral 3 image-only + image → accept
            .init(modelId: "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4",
                  attempted: "image", shouldAccept: true),
            // Turn 3: switch back to omni + video → accept
            .init(modelId: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
                  attempted: "video", shouldAccept: true),
            // Turn 4: switch to text-only Laguna + image → REJECT
            .init(modelId: "JANGQ-AI/Laguna-XS.2-JANGTQ",
                  attempted: "image", shouldAccept: false),
            // Turn 5: same Laguna + audio → REJECT
            .init(modelId: "JANGQ-AI/Laguna-XS.2-JANGTQ",
                  attempted: "audio", shouldAccept: false),
            // Turn 6: switch to Mistral 3 + video → REJECT (image-only)
            .init(modelId: "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4",
                  attempted: "video", shouldAccept: false),
            // Turn 7: switch to Mistral 3 + audio → REJECT
            .init(modelId: "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4",
                  attempted: "audio", shouldAccept: false),
        ]
        for (i, t) in turns.enumerated() {
            let cap = ModelMediaCapabilities.from(modelId: t.modelId)
            let actual: Bool = {
                switch t.attempted {
                case "image": return cap.supportsImage
                case "video": return cap.supportsVideo
                case "audio": return cap.supportsAudio
                default: return false
                }
            }()
            #expect(actual == t.shouldAccept,
                "turn \(i): [\(t.modelId)] dropping \(t.attempted) — expected accept=\(t.shouldAccept), got accept=\(actual)")
        }
    }
}

// =====================================================================
// MARK: - E. End-to-end: model_id → capability → composer accept-set
// =====================================================================

@Suite("End-to-end — model id flows through to composer accept-set")
struct EndToEndComposerAcceptSetTests {

    /// Comprehensive matrix: every shipping family × every modality.
    /// One row per (model_id, modality) — assert pass/fail.
    @Test(arguments: [
        // (modelId, modality, shouldAccept)
        ("OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4", "image", true),
        ("OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4", "video", true),
        ("OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4", "audio", true),
        ("OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4", "audio", true),
        ("Qwen/Qwen3-VL-8B", "image", true),
        ("Qwen/Qwen3-VL-8B", "video", true),
        ("Qwen/Qwen3-VL-8B", "audio", false),
        ("mlx-community/Qwen2.5-VL-32B-Instruct-mxfp4", "image", true),
        ("mlx-community/Qwen2.5-VL-32B-Instruct-mxfp4", "video", true),
        ("mlx-community/SmolVLM2-2.2B-Instruct", "video", true),
        ("OsaurusAI/Mistral-Medium-3.5-128B-mxfp4", "image", true),
        ("OsaurusAI/Mistral-Medium-3.5-128B-mxfp4", "video", false),
        ("OsaurusAI/Mistral-Medium-3.5-128B-mxfp4", "audio", false),
        ("google/paligemma-3b-pt-224", "image", true),
        ("google/paligemma-3b-pt-224", "video", false),
        ("HuggingFaceM4/Idefics3-8B", "image", true),
        ("HuggingFaceM4/Idefics3-8B", "audio", false),
        ("apple/FastVLM-7B", "image", true),
        ("mistral-community/pixtral-12b", "image", true),
        ("OsaurusAI/Holo3-35B-A3B-mxfp4", "image", true),   // Holo3 has vision_config
        ("OsaurusAI/Holo3-35B-A3B-mxfp4", "video", true),
        ("OsaurusAI/Holo3-35B-A3B-mxfp4", "audio", false),  // image+video, no audio
        ("JANGQ-AI/Laguna-XS.2-JANGTQ", "image", false),
        ("JANGQ-AI/Laguna-XS.2-JANGTQ", "video", false),
        ("JANGQ-AI/MiniMax-M2.7-Small-JANGTQ", "audio", false),
        ("JANGQ-AI/MiniMax-M2.7-JANGTQ4", "image", false),
        ("JANGQ-AI/DeepSeek-V4-Flash-JANGTQ", "video", false),
        ("JANGQ-AI/Kimi-K2.6-Med-JANGTQ", "audio", false),
        ("JANGQ-AI/Qwen3.5-35B-A3B-JANG_4K", "image", false),
        ("JANGQ-AI/Qwen3.6-35B-A3B-JANGTQ4", "audio", false),
    ])
    func everyFamilyEveryModality(_ row: (String, String, Bool)) {
        let (id, modality, shouldAccept) = row
        let cap = ModelMediaCapabilities.from(modelId: id)
        let actual: Bool = {
            switch modality {
            case "image": return cap.supportsImage
            case "video": return cap.supportsVideo
            case "audio": return cap.supportsAudio
            default: return false
            }
        }()
        #expect(actual == shouldAccept,
            "[\(id)] \(modality): expected \(shouldAccept), got \(actual)")
    }
}
