//
//  HostRunRequest.swift
//  osaurus
//
//  A user turn's request for another of the user's devices to run the
//  chat's agent. See "Hosted runs" in osaurus-sync's docs/app-data.md and
//  docs/SYNC_MOBILE_CONTRACT.md §3. Fields past `requestedMs` are optional;
//  a host on an older build ignores them.
//

import Foundation

public struct HostRunRequest: Codable, Equatable, Sendable {
    /// Sync device id of the host that should answer the turn.
    public var device: String
    public var requestedMs: Int64
    /// The model to run this turn on, as the host's picker names it. Nil
    /// runs the agent's model.
    public var model: String?
    public var options: Options?
    /// Set on the turns of a voice call.
    public var voiceCall: VoiceCall?
    /// The Privacy Filter for this turn: `auto` redacts every detection
    /// without a review, `off` sends it as written. Nil follows the Mac's
    /// settings.
    public var privacy: String?
    /// Set when `model` is an image model.
    public var image: ImageSettings?

    public struct Options: Codable, Equatable, Sendable {
        /// One of the model's reasoning effort tiers (`low`, `medium`, `high`, …).
        public var reasoningEffort: String?
        public var thinking: Bool?

        public init(reasoningEffort: String? = nil, thinking: Bool? = nil) {
            self.reasoningEffort = reasoningEffort
            self.thinking = thinking
        }
    }

    public struct VoiceCall: Codable, Equatable, Sendable {
        /// The caller's instructions for spoken replies. Used for this run
        /// only, never saved into the chat.
        public var instructions: String?

        public init(instructions: String? = nil) {
            self.instructions = instructions
        }
    }

    /// The image composer's settings, as the Mac's image composer names them.
    public struct ImageSettings: Codable, Equatable, Sendable {
        public var width: Int?
        public var height: Int?
        public var steps: Int?
        public var guidance: Double?
        public var seed: Int?
        public var strength: Double?
        public var negativePrompt: String?
        public var aspectRatio: String?
        public var resolution: String?
        public var quality: String?
        public var count: Int?

        public init(
            width: Int? = nil, height: Int? = nil, steps: Int? = nil, guidance: Double? = nil, seed: Int? = nil,
            strength: Double? = nil, negativePrompt: String? = nil, aspectRatio: String? = nil,
            resolution: String? = nil, quality: String? = nil, count: Int? = nil
        ) {
            self.width = width
            self.height = height
            self.steps = steps
            self.guidance = guidance
            self.seed = seed
            self.strength = strength
            self.negativePrompt = negativePrompt
            self.aspectRatio = aspectRatio
            self.resolution = resolution
            self.quality = quality
            self.count = count
        }

        /// `base` (the model's defaults) with what the phone chose. Values
        /// are clamped where the run builds its request, as for the composer.
        public func applied(to base: ImageComposerSettings) -> ImageComposerSettings {
            var settings = base
            if let width { settings.width = width }
            if let height { settings.height = height }
            if let steps { settings.steps = steps }
            if let guidance { settings.guidance = guidance }
            if let seed { settings.seed = String(seed) }
            if let strength { settings.strength = strength }
            if let negativePrompt { settings.negativePrompt = negativePrompt }
            if let aspectRatio { settings.aspectRatio = aspectRatio }
            if let resolution { settings.resolution = resolution }
            if let quality { settings.quality = quality }
            if let count { settings.imageCount = count }
            return settings
        }
    }

    /// Longest `voiceCall.instructions` a host applies.
    public static let instructionsLimit = 8_000

    public init(
        device: String,
        requestedMs: Int64 = Int64((Date().timeIntervalSince1970 * 1000).rounded()),
        model: String? = nil,
        options: Options? = nil,
        voiceCall: VoiceCall? = nil,
        privacy: String? = nil,
        image: ImageSettings? = nil
    ) {
        self.device = device
        self.requestedMs = requestedMs
        self.model = model
        self.options = options
        self.voiceCall = voiceCall
        self.privacy = privacy
        self.image = image
    }

    /// A field a newer caller spells differently is dropped, not fatal: the
    /// turn still runs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decode(String.self, forKey: .device)
        requestedMs = try container.decode(Int64.self, forKey: .requestedMs)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        options = try? container.decodeIfPresent(Options.self, forKey: .options)
        voiceCall = try? container.decodeIfPresent(VoiceCall.self, forKey: .voiceCall)
        privacy = try? container.decodeIfPresent(String.self, forKey: .privacy)
        image = try? container.decodeIfPresent(ImageSettings.self, forKey: .image)
    }

    private enum CodingKeys: String, CodingKey {
        case device, requestedMs, model, options, voiceCall, privacy, image
    }

    /// The generation controls `options` asks for, nil when it asks for none.
    var generationOverrides: ChatTurnOverrides? {
        guard let options else { return nil }
        let effort = options.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrides = ChatTurnOverrides(
            reasoningEffort: (effort?.isEmpty ?? true) ? nil : effort,
            enableThinking: options.thinking
        )
        return overrides.isEmpty ? nil : overrides
    }

    /// The pinned model, nil when the turn runs the agent's.
    var pinnedModel: String? {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
