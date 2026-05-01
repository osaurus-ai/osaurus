//
//  ModelMediaCapabilities.swift
//  osaurus
//
//  Per-model capability detection for audio + video drag/drop in the
//  chat composer. Reads (a) the model's `config.json` for vision/audio
//  config presence, (b) the model_type / model_id substring + regex
//  matching, and (c) the bundled `config_omni.json` sidecar for omni
//  (Nemotron-3) bundles.
//
//  Why a dedicated detector vs piggy-backing on `VLMDetection`:
//
//   - VLMDetection answers "is there a vision_config?" — fine for
//     image-attachment routing, but neither necessary nor sufficient
//     for video (some VLMs are image-only) and unrelated to audio.
//   - Per-family video support is config-parametric. Mistral 3 / 3.5
//     have a vision_config but no video preprocessor. Qwen 3 VL hardcodes
//     `targetFPS=2` in the model class.
//   - Audio support today is exclusively Nemotron-3-Nano-Omni — gated by
//     the `config_omni.json` sidecar.
//
//  The matrix here mirrors `vmlx-swift-lm/Libraries/MLXLMCommon/
//  BatchEngine/MEDIA-MODEL-MATRIX.md`. Keep them in sync — when vmlx
//  adds video support to a new family (e.g. Mistral 3.5 follow-up),
//  update both this matcher AND the matrix doc.
//

import Foundation

public enum ModelMediaCapabilities {

    /// Per-modality capability flags for a single model. Drives the
    /// chat composer's drag/drop allowlist + the file-picker's
    /// `allowedContentTypes`.
    public struct Capabilities: Equatable, Sendable {
        public let supportsImage: Bool
        public let supportsVideo: Bool
        public let supportsAudio: Bool

        public static let textOnly = Capabilities(
            supportsImage: false,
            supportsVideo: false,
            supportsAudio: false
        )

        public static let imageOnly = Capabilities(
            supportsImage: true,
            supportsVideo: false,
            supportsAudio: false
        )

        public static let imageVideo = Capabilities(
            supportsImage: true,
            supportsVideo: true,
            supportsAudio: false
        )

        public static let omni = Capabilities(
            supportsImage: true,
            supportsVideo: true,
            supportsAudio: true
        )

        public var anyMedia: Bool {
            supportsImage || supportsVideo || supportsAudio
        }

        public var summary: String {
            var parts: [String] = []
            if supportsImage { parts.append("image") }
            if supportsVideo { parts.append("video") }
            if supportsAudio { parts.append("audio") }
            return parts.isEmpty ? "text-only" : parts.joined(separator: " + ")
        }
    }

    // MARK: - Detection by model_id (substring + regex)
    //
    // Fast path used by the UI before / without the model being
    // downloaded. Mirrors the spec in MEDIA-MODEL-MATRIX.md.

    /// Resolve capabilities from a Hugging Face repo id or osaurus
    /// model name string. Case-insensitive substring + regex match
    /// against the families with known modality support. Returns
    /// `.textOnly` for unknown / dense LLMs.
    ///
    /// This is the surface the chat composer uses BEFORE the model is
    /// loaded so the drag-drop UI knows whether to advertise audio /
    /// video accept slots. After load, `from(directory:modelId:)`
    /// can refine via the bundle's `config_omni.json` sidecar.
    public static func from(modelId: String) -> Capabilities {
        let lower = modelId.lowercased()

        // Nemotron-3-Nano-Omni — only family with native audio today.
        // Matches:
        //   OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4 / -JANGTQ4 / -JANGTQ
        //   nemotron-3-nano-omni-* (case-folded picker form)
        if regexMatches(lower, pattern: #"nemotron-3-nano-omni|nemotron[_-]h[_-]omni"#) {
            return .omni
        }

        // Qwen 2 VL / 2.5 VL / 3 VL — image + video, no audio.
        // Matches: qwen2-vl-*, qwen2.5-vl-*, qwen3-vl-* (and underscore variants)
        if regexMatches(lower, pattern: #"qwen[2-3](\.\d+|_\d+)?[-_]?vl"#) {
            return .imageVideo
        }

        // Qwen 3.5 / 3.6 MoE VL bundles — image + video via Qwen35
        // class. Hybrid SSM eager-flipped via osaurus matcher.
        // Note: text-only Qwen 3.5/3.6 bundles also exist; gating on
        // `vl` substring lets text-only fall through to .textOnly.
        if regexMatches(lower, pattern: #"qwen3\.[5-6].*[-_]vl|holo3.*[-_]vl"#) {
            return .imageVideo
        }
        // Holo3 base bundles (no `-vl` suffix) — these still ship a
        // vision_config under the hood (the bundle's outer model_type is
        // `qwen3_5_moe` with vision_config + pixtral-style image
        // preprocessor). Recognise the family by name so the picker
        // advertises image+video pre-load. Post-load, the directory-
        // based detector confirms via vision_config. Without this, drag-
        // drop UI rejects images for Holo3-35B-A3B-mxfp4 even though the
        // engine is fully wired for them.
        if regexMatches(lower, pattern: #"^(.+/)?holo3"#) {
            return .imageVideo
        }

        // SmolVLM 2 — image + video with adaptive fps.
        if lower.contains("smolvlm") || lower.contains("smol-vlm") {
            return .imageVideo
        }

        // Image-only VLM families. Substring-match the bundle name.
        let imageOnlyPatterns: [String] = [
            "paligemma", "idefics3", "fastvlm", "llava-qwen2", "llava_qwen2",
            "pixtral",  // standalone pixtral, not the Mistral 3 wrap
            "glm-ocr", "glm_ocr",
            "lfm2-vl", "lfm2_vl",
            "gemma-3", "gemma3",
            "gemma-4-it",  // VLM Gemma 4 (the dense LLM gemma-4 also exists)
        ]
        if imageOnlyPatterns.contains(where: lower.contains) {
            return .imageOnly
        }

        // Mistral 3 / 3.5 — image only via Pixtral wrapper.
        // Matches: mistral-3-*, mistral-medium-3.5-*, mistral_3, ministral3
        if regexMatches(lower, pattern: #"mistral[-_](3|medium-3)"#) {
            return .imageOnly
        }

        // Mistral 4 VLM — image only. NOTE: bare `mistral-4` could be
        // either VLM or LLM. The presence of `vl` in the id disambiguates.
        if regexMatches(lower, pattern: #"mistral[-_]?4.*[-_]vl"#) {
            return .imageOnly
        }

        return .textOnly
    }

    /// Resolve capabilities by inspecting the locally-installed bundle.
    /// Use after the model is downloaded for the most accurate signal.
    /// Falls back to `from(modelId:)` if config.json is unreadable.
    public static func from(directory: URL, modelId: String) -> Capabilities {
        // Omni bundle gate: presence of config_omni.json flips the
        // VLMModelFactory dispatch to NemotronH_Nano_Omni_Reasoning_V3
        // and exposes Parakeet ASR + RADIO ViT.
        let configOmniURL = directory.appendingPathComponent("config_omni.json")
        if FileManager.default.fileExists(atPath: configOmniURL.path) {
            return .omni
        }

        // Read config.json for vision_config presence.
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return from(modelId: modelId)
        }

        let modelType = (json["model_type"] as? String)?.lowercased() ?? ""
        let hasVisionConfig = json["vision_config"] != nil

        // No vision config → not even image-capable. (Audio without
        // vision is only the omni path, already handled above.)
        guard hasVisionConfig else {
            return .textOnly
        }

        // Cross-check the family-by-model_type for video support.
        // model_types known to support video at the engine level:
        let videoCapableModelTypes: Set<String> = [
            "qwen2_vl", "qwen2_5_vl", "qwen3_vl",
            "qwen3_5", "qwen3_5_moe",
            "smolvlm",
            "nemotron_h_omni",
            "NemotronH_Nano_Omni_Reasoning_V3".lowercased(),
        ]
        if videoCapableModelTypes.contains(modelType) {
            // Audio belongs only to omni — already returned above.
            return .imageVideo
        }

        // Has vision_config but model_type is image-only.
        return .imageOnly
    }

    // MARK: - Helpers

    private static func regexMatches(_ s: String, pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(s.startIndex ..< s.endIndex, in: s)
        return re.firstMatch(in: s, options: [], range: range) != nil
    }
}
