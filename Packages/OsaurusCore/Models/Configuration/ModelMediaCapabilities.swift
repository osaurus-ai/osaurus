// Installed media permissions come from configuration and actual weight headers.
// Display names never grant or deny a local model a modality.

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

        /// Adds audio when the bundle's checkpoint proves it, never removes it.
        /// A name-based verdict cannot see the weights, so it may only be too
        /// conservative here — the checkpoint is the stronger evidence.
        public func withAudio(_ hasAudio: Bool) -> Capabilities {
            guard hasAudio, !supportsAudio else { return self }
            return Capabilities(
                supportsImage: supportsImage,
                supportsVideo: supportsVideo,
                supportsAudio: true
            )
        }

        public var summary: String {
            var parts: [String] = []
            if supportsImage { parts.append("image") }
            if supportsVideo { parts.append("video") }
            if supportsAudio { parts.append("audio") }
            return parts.isEmpty ? "text-only" : parts.joined(separator: " + ")
        }
    }

    /// Resolve installed facts. An unknown ID carries no local media permission.
    public static func from(modelId: String) -> Capabilities {
        guard let directory = VLMDetection.localDirectory(forModelId: modelId) else { return .textOnly }
        return from(directory: directory, modelId: modelId)
    }

    /// Local facts are authoritative, including an explicit negative result.
    /// The image fallback is for provider metadata; it cannot invent local video.
    public static func composerCapabilities(
        modelId: String?,
        fallbackSupportsImages: Bool,
        localModelType: String? = nil,
        localHasAudioTensors: Bool = false,
        localCapabilities: Capabilities? = nil
    ) -> Capabilities {
        if let localCapabilities { return localCapabilities }
        if localModelType != nil { return .textOnly }
        return Capabilities(supportsImage: fallbackSupportsImages, supportsVideo: false,
                            supportsAudio: localHasAudioTensors)
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
        fallbackSupportsImages: Bool,
        localModelType: String? = nil,
        localHasAudioTensors: Bool = false,
        localCapabilities: Capabilities? = nil
    ) -> Descriptor {
        let normalized = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayId = normalized.isEmpty ? "unspecified model" : normalized
        let capabilities = composerCapabilities(
            modelId: modelId,
            fallbackSupportsImages: fallbackSupportsImages,
            localModelType: localModelType,
            localHasAudioTensors: localHasAudioTensors,
            localCapabilities: localCapabilities
        )
        let source = localCapabilities != nil || localModelType != nil
            ? "installed bundle evidence" : "provider capability metadata"
        return buildDescriptor(
            modelId: displayId,
            capabilities: capabilities,
            source: source
        )
    }

    /// Configuration and actual tensor headers must agree. No name fallback.
    /// LocalVisionEvidence memoizes both vision and audio by directory and
    /// invalidates on localModelsChanged; avoid a second memo that could hide
    /// a refreshed preflight result from the composer.
    public static func from(directory: URL, modelId: String) -> Capabilities {
        let evidence = LocalVisionEvidence.inspect(directory)
        return capabilities(evidence)
    }

    private static func capabilities(_ evidence: LocalVisionEvidence.Result) -> Capabilities {
        let type = evidence.modelType.lowercased()
        let audio = evidence.tensorNames.contains {
            $0.contains("embed_audio.embedding_projection.") && $0.hasSuffix(".weight")
        } || (type.contains("omni") && evidence.tensorNames.contains {
            $0.contains("sound_projection.") && $0.hasSuffix(".weight")
        })
        return Capabilities(
            supportsImage: evidence.hasVision,
            supportsVideo: evidence.hasVision && videoCapableModelTypes.contains(type),
            supportsAudio: audio
        )
    }

    public static func descriptor(directory: URL, modelId: String, refresh: Bool = false) -> Descriptor {
        let evidence = LocalVisionEvidence.inspect(directory, refresh: refresh)
        let caps = capabilities(evidence)
        let base = buildDescriptor(modelId: modelId, capabilities: caps, source: "installed bundle evidence")
        return Descriptor(modelId: modelId, capabilities: caps,
            image: .init(modality: .image, status: caps.supportsImage ? .supported : .unsupported,
                         reason: evidence.reason), video: base.video, audio: base.audio)
    }

    public static func bundleCarriesAudio(directory: URL) -> Bool {
        capabilities(LocalVisionEvidence.inspect(directory)).supportsAudio
    }

    struct UnsupportedAttachment: LocalizedError {
        let modality: String
        var errorDescription: String? {
            "The selected model has no verified \(modality) input capability. The attachment was retained; choose a compatible model or remove it before sending."
        }
    }

    static func validateAttachments(_ attachments: [Attachment], capabilities: Capabilities) throws {
        for attachment in attachments {
            switch attachment.kind {
            case .image, .imageRef:
                if !capabilities.supportsImage { throw UnsupportedAttachment(modality: "image") }
            case .video, .videoRef:
                if !capabilities.supportsVideo { throw UnsupportedAttachment(modality: "video") }
            case .audio, .audioRef:
                if !capabilities.supportsAudio { throw UnsupportedAttachment(modality: "audio") }
            case .document, .documentRef: break
            }
        }
    }

    // MARK: - Helpers

    private static let videoCapableModelTypes: Set<String> = [
        "qwen2_vl", "qwen2_5_vl", "qwen3_vl",
        "qwen3_5", "qwen3_5_moe", "qwen4_exp",
        "qwen3_6", "qwen3_6_moe",
        "smolvlm",
        "nemotron_h_omni",
        "NemotronH_Nano_Omni_Reasoning_V3".lowercased(),
        // Muse Glimmer's vision tower carries `patch_temporal: 2`, i.e. it
        // consumes frames in temporal pairs, and the chat template has a
        // dedicated `<|video|>` placeholder alongside `<|patch|>`. Without this
        // entry the bundle's own `has_video: true` is overruled here and video
        // requests are rejected as unsupported.
        "muse_glimmer",
    ]

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
        return ModalityDescriptor(
            modality: .audio, status: .unsupported,
            reason: "Audio input is not backed by the installed bundle or provider metadata."
        )
    }
}
