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
//  The matrix here mirrors `vmlx-swift/Libraries/MLXLMCommon/
//  BatchEngine/MEDIA-MODEL-MATRIX.md`. Keep them in sync — when vmlx
//  adds video support to a new family (e.g. Mistral 3.5 follow-up),
//  update both this matcher AND the matrix doc.
//

import Foundation

public enum ModelMediaCapabilities {

    public enum Modality: String, CaseIterable, Sendable {
        case image
        case video
        case audio

        public var label: String { rawValue }
    }

    public enum ModalityStatus: String, Sendable {
        case supported
        case unsupported
        case unproven
        case disabled

        public var isUsable: Bool {
            self == .supported
        }
    }

    public struct ModalityDescriptor: Equatable, Sendable {
        public let modality: Modality
        public let status: ModalityStatus
        public let reason: String

        public var isUsable: Bool { status.isUsable }

        public var summary: String {
            switch status {
            case .supported:
                return "\(modality.label): supported"
            case .unsupported:
                return "\(modality.label): unsupported"
            case .unproven:
                return "\(modality.label): proof required"
            case .disabled:
                return "\(modality.label): disabled"
            }
        }
    }

    public struct Descriptor: Equatable, Sendable {
        public let modelId: String
        public let capabilities: Capabilities
        public let image: ModalityDescriptor
        public let video: ModalityDescriptor
        public let audio: ModalityDescriptor

        public func descriptor(for modality: Modality) -> ModalityDescriptor {
            switch modality {
            case .image: return image
            case .video: return video
            case .audio: return audio
            }
        }

        public var statusSummary: String {
            [image, video, audio].map(\.summary).joined(separator: "; ")
        }

        public func rejectionMessage(for modality: Modality) -> String {
            let target = descriptor(for: modality)
            if capabilities.anyMedia {
                return "\(target.reason) The current model supports \(capabilities.summary) only."
            }
            return "\(target.reason) The current model is text-only."
        }
    }

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

        // Nemotron-3-Nano-Omni / Nemotron-Omni-Nano — only family with
        // native audio today.
        // Matches:
        //   OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4 / -JANGTQ4 / -JANGTQ
        //   nemotron-3-nano-omni-* (case-folded picker form)
        //   local crack bundles like Nemotron-Omni-Nano-JANGTQ-CRACK
        if ModelFamilyNames.isNemotronOmniFamily(modelId)
            || regexMatches(lower, pattern: #"nemotron-3-nano-omni|nemotron[_-]h[_-]omni"#)
        {
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

        // ZAYA1-VL — native image/text only. The vmlx engine rejects video
        // input for this family until a real ZAYA video processor exists.
        if ModelFamilyNames.isZayaVLFamily(modelId) {
            return .imageOnly
        }

        // Image-only VLM families. Substring-match the bundle name.
        let imageOnlyPatterns: [String] = [
            "paligemma", "idefics3", "fastvlm", "llava-qwen2", "llava_qwen2",
            "pixtral",  // standalone pixtral, not the Mistral 3 wrap
            "glm-ocr", "glm_ocr",
            "lfm2-vl", "lfm2_vl",
            "gemma-3", "gemma3",
            "gemma-4-it",  // VLM Gemma 4 (the dense LLM gemma-4 also exists)
            "gemma-4-12b-it",
            "gemma-4-26b-it",
            "gemma-4-26b-a4b-it",
            "gemma-4-31b-it",
            "gemma-4-31b-a4b-it",
            "gemma4-12b-it",
            "gemma4-26b-it",
            "gemma4-26b-a4b-it",
            "gemma4-31b-it",
            "gemma4-31b-a4b-it",
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

    /// Capabilities for the chat composer. `from(modelId:)` is the
    /// family-specific source of truth for local models. The
    /// `fallbackSupportsImages` bit lets externally discovered VLMs
    /// (notably remote/provider models that do not match local family
    /// names) keep image paste/drop support without accidentally
    /// granting audio or video.
    public static func composerCapabilities(
        modelId: String?,
        fallbackSupportsImages: Bool
    ) -> Capabilities {
        guard let modelId,
            !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return fallbackSupportsImages ? .imageOnly : .textOnly
        }

        let detected = from(modelId: modelId)
        if detected == .textOnly,
            ModelFamilyNames.isNemotronThinkingFamily(modelId),
            !ModelFamilyNames.isNemotronOmniFamily(modelId)
        {
            return .textOnly
        }
        guard fallbackSupportsImages, !detected.supportsImage else {
            return detected
        }
        return Capabilities(
            supportsImage: true,
            supportsVideo: detected.supportsVideo,
            supportsAudio: detected.supportsAudio
        )
    }

    public static func descriptor(modelId: String) -> Descriptor {
        buildDescriptor(
            modelId: modelId,
            capabilities: from(modelId: modelId),
            source: "model id"
        )
    }

    public static func composerDescriptor(
        modelId: String?,
        fallbackSupportsImages: Bool
    ) -> Descriptor {
        let normalized = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayId = normalized.isEmpty ? "unspecified model" : normalized
        let capabilities = composerCapabilities(
            modelId: modelId,
            fallbackSupportsImages: fallbackSupportsImages
        )
        let detected = normalized.isEmpty ? Capabilities.textOnly : from(modelId: normalized)
        let source =
            fallbackSupportsImages && capabilities.supportsImage && !detected.supportsImage
            ? "composer fallback"
            : "model id"
        return buildDescriptor(
            modelId: displayId,
            capabilities: capabilities,
            source: source
        )
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

        if ModelFamilyNames.isNemotronThinkingFamily(modelId)
            && !ModelFamilyNames.isNemotronOmniFamily(modelId)
        {
            return .textOnly
        }

        let modelType = (json["model_type"] as? String)?.lowercased() ?? ""
        let hasVisionConfig = json["vision_config"] != nil

        // No vision config → not even image-capable. (Audio without
        // vision is only the omni path, already handled above.)
        guard hasVisionConfig else {
            return .textOnly
        }

        // Gemma4: audio capability is checkpoint-fact-driven, not
        // name-driven. The same family ships three different audio
        // realities (verified against the OsaurusAI QAT weight maps):
        //   12B (gemma4_unified)  — encoder-free `embed_audio` raw-frame
        //                           projection; vMLX decodes raw audio
        //                           natively via unified chunking.
        //   E2B/E4B (gemma4)      — mel + conformer `audio_tower` plus
        //                           `embed_audio`.
        //   26B-A4B / 31B         — NO audio tensors in the checkpoint;
        //                           audio is impossible there, not
        //                           "unwired", so it stays unsupported.
        if modelType.hasPrefix("gemma4") {
            return Capabilities(
                supportsImage: true,
                supportsVideo: false,
                supportsAudio: gemma4BundleSupportsAudio(directory: directory)
            )
        }

        // Cross-check the family-by-model_type for video support.
        // model_types known to support video at the engine level:
        let videoCapableModelTypes: Set<String> = [
            "qwen2_vl", "qwen2_5_vl", "qwen3_vl",
            "qwen3_5", "qwen3_5_moe",
            "qwen3_6", "qwen3_6_moe",
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

    public static func descriptor(directory: URL, modelId: String) -> Descriptor {
        buildDescriptor(
            modelId: modelId,
            capabilities: from(directory: directory, modelId: modelId),
            source: "bundle config"
        )
    }

    /// True when a locally-installed Gemma4 bundle ships the audio input
    /// tensors the runtime needs. Checks the safetensors weight map for
    /// `embed_audio.embedding_projection` — present in the 12B unified
    /// (raw-frame) and E2B/E4B (mel + `audio_tower`) checkpoints, absent
    /// from 26B-A4B / 31B. A raw byte scan is used instead of full JSON
    /// decoding because the 12B index is multi-MB and this runs on the
    /// capability-resolution path.
    private static func gemma4BundleSupportsAudio(directory: URL) -> Bool {
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: indexURL, options: .mappedIfSafe) {
            return data.range(of: Data("embed_audio.embedding_projection".utf8)) != nil
        }
        // Single-file bundles: fall back to the config's audio marker.
        // Gemma4 configs always carry audio_token_id, so use audio_config
        // presence (E-series) only; without an index we cannot prove the
        // unified embed_audio tensor exists, so stay conservative.
        let configURL = directory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let audioConfig = json["audio_config"], !(audioConfig is NSNull)
        {
            return true
        }
        return false
    }

    // MARK: - Helpers

    private static func buildDescriptor(
        modelId: String,
        capabilities: Capabilities,
        source: String
    ) -> Descriptor {
        Descriptor(
            modelId: modelId,
            capabilities: capabilities,
            image: ModalityDescriptor(
                modality: .image,
                status: capabilities.supportsImage ? .supported : .unsupported,
                reason: capabilities.supportsImage
                    ? "Image input is enabled by \(source)."
                    : "Image input is not advertised for \(modelId)."
            ),
            video: ModalityDescriptor(
                modality: .video,
                status: capabilities.supportsVideo ? .supported : .unsupported,
                reason: capabilities.supportsVideo
                    ? "Video input is enabled by \(source)."
                    : "Video input is not advertised for \(modelId)."
            ),
            audio: audioDescriptor(
                modelId: modelId,
                capabilities: capabilities,
                source: source
            )
        )
    }

    private static func audioDescriptor(
        modelId: String,
        capabilities: Capabilities,
        source: String
    ) -> ModalityDescriptor {
        if capabilities.supportsAudio {
            return ModalityDescriptor(
                modality: .audio,
                status: .supported,
                reason: "Audio input is enabled by \(source)."
            )
        }
        if isGemma4VisionFamily(modelId, capabilities: capabilities) {
            // Bundle-fact gate: `from(directory:)` only reports audio for
            // Gemma4 bundles whose weight map actually ships
            // `embed_audio.embedding_projection`. When detection ran against
            // the installed bundle, reaching here means this checkpoint has
            // no audio input tensors (26B-A4B / 31B) — audio is impossible
            // for the checkpoint, not pending runtime wiring. Name-only
            // detection cannot see the weight map, so it must not claim
            // checkpoint facts.
            if source == "bundle config" {
                return ModalityDescriptor(
                    modality: .audio,
                    status: .unsupported,
                    reason:
                        "This Gemma4 checkpoint ships no audio input tensors (no embed_audio/audio_tower in the weight map); audio input is not possible for this bundle."
                )
            }
            return ModalityDescriptor(
                modality: .audio,
                status: .unproven,
                reason:
                    "Gemma4 audio is enabled per-bundle from the installed weight map (12B unified and E-series ship audio tensors; 26B-A4B/31B do not). Install the model so the bundle can be inspected."
            )
        }
        return ModalityDescriptor(
            modality: .audio,
            status: .unsupported,
            reason: "Audio input is not advertised for \(modelId)."
        )
    }

    private static func isGemma4VisionFamily(
        _ modelId: String,
        capabilities: Capabilities? = nil
    ) -> Bool {
        let lower = modelId.lowercased()
        guard lower.contains("gemma-4") || lower.contains("gemma4") else {
            return false
        }
        if let capabilities {
            return capabilities.supportsImage
        }
        return lower.contains("-it") || lower.contains("_it")
    }

    private static func regexMatches(_ s: String, pattern: String) -> Bool {
        guard let re = regexCache.regex(for: pattern) else { return false }
        let range = NSRange(s.startIndex ..< s.endIndex, in: s)
        return re.firstMatch(in: s, options: [], range: range) != nil
    }

    // Compile each pattern once. `from(modelId:)` runs inside SwiftUI
    // body evaluations on the composer's render path, and ICU regex
    // compilation is slow enough under memory pressure to register as
    // a main-thread hang.
    private static let regexCache = RegexCache()

    private final class RegexCache: @unchecked Sendable {
        private var storage: [String: NSRegularExpression] = [:]
        private let lock = NSLock()

        func regex(for pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let hit = storage[pattern] { return hit }
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            storage[pattern] = re
            return re
        }
    }
}
