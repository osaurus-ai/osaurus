//
//  RemoteModelMetadata.swift
//  osaurus
//
//  Provider-neutral per-model metadata captured during remote model
//  discovery. Every field is optional: `nil` means the provider's `/models`
//  response made no claim, which the picker renders as "unknown" rather than
//  inventing a value. Providers that publish richer catalogs (OpenRouter,
//  Venice, Mistral, xAI, Gemini, Anthropic, Ollama) fill what they know.
//

import Foundation

public struct RemoteModelMetadata: Sendable, Equatable, Hashable {
    /// Human-readable name published by the provider (e.g. Anthropic's
    /// `display_name`, OpenRouter's `name`). Nil when the id is the only name.
    public var displayName: String?
    /// Provider-authored description, when published.
    public var description: String?
    /// Context window in tokens.
    public var contextLength: Int?
    /// Maximum completion/output tokens, when published separately.
    public var maxOutputTokens: Int?
    /// Whether the model accepts image input. Nil = no claim either way.
    public var supportsVision: Bool?
    /// Whether the model accepts tool/function definitions. Nil = no claim.
    public var supportsToolCalling: Bool?
    /// Whether the model exposes a reasoning/thinking channel. Nil = no claim.
    public var supportsReasoning: Bool?
    /// Whether the model accepts audio input. Nil = no claim.
    public var supportsAudioInput: Bool?
    /// Input price in micro-USD per million tokens. `0` means published as free.
    public var inputPriceMicroPerMTok: Int64?
    /// Output price in micro-USD per million tokens. `0` means published as free.
    public var outputPriceMicroPerMTok: Int64?
    /// Whether the provider flagged the model as deprecated/retired.
    public var isDeprecated: Bool
    /// The provider's suggested replacement for a deprecated model, if any.
    public var deprecationReplacement: String?
    /// A provider-published "recommended" signal (e.g. Venice's `default` /
    /// `fastest` traits). Rendered verbatim-ish as the Recommended badge
    /// tooltip; nil when the provider doesn't rank its own models.
    public var recommendedReason: String?
    /// Parameter count published by the provider (Ollama's `parameter_size`),
    /// e.g. "8B". Nil for hosted APIs that don't disclose it.
    public var parameterCount: String?
    /// Quantization published by the provider (Ollama's `quantization_level`,
    /// Venice's `capabilities.quantization`), e.g. "Q4_K_M" / "fp16".
    public var quantization: String?
    /// Unix creation timestamp, when published.
    public var created: Int?

    public init(
        displayName: String? = nil,
        description: String? = nil,
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsVision: Bool? = nil,
        supportsToolCalling: Bool? = nil,
        supportsReasoning: Bool? = nil,
        supportsAudioInput: Bool? = nil,
        inputPriceMicroPerMTok: Int64? = nil,
        outputPriceMicroPerMTok: Int64? = nil,
        isDeprecated: Bool = false,
        deprecationReplacement: String? = nil,
        recommendedReason: String? = nil,
        parameterCount: String? = nil,
        quantization: String? = nil,
        created: Int? = nil
    ) {
        self.displayName = Self.cleaned(displayName)
        self.description = Self.cleaned(description)
        self.contextLength = contextLength.flatMap { $0 > 0 ? $0 : nil }
        self.maxOutputTokens = maxOutputTokens.flatMap { $0 > 0 ? $0 : nil }
        self.supportsVision = supportsVision
        self.supportsToolCalling = supportsToolCalling
        self.supportsReasoning = supportsReasoning
        self.supportsAudioInput = supportsAudioInput
        self.inputPriceMicroPerMTok = inputPriceMicroPerMTok.flatMap { $0 >= 0 ? $0 : nil }
        self.outputPriceMicroPerMTok = outputPriceMicroPerMTok.flatMap { $0 >= 0 ? $0 : nil }
        self.isDeprecated = isDeprecated
        self.deprecationReplacement = Self.cleaned(deprecationReplacement)
        self.recommendedReason = Self.cleaned(recommendedReason)
        self.parameterCount = Self.cleaned(parameterCount)
        self.quantization = Self.cleaned(quantization)
        self.created = created
    }

    /// True when the provider carried no usable metadata at all, so callers
    /// can skip storing an empty record for the id.
    public var isEmpty: Bool {
        displayName == nil && description == nil && contextLength == nil && maxOutputTokens == nil
            && supportsVision == nil && supportsToolCalling == nil && supportsReasoning == nil
            && supportsAudioInput == nil && inputPriceMicroPerMTok == nil
            && outputPriceMicroPerMTok == nil && !isDeprecated && deprecationReplacement == nil
            && recommendedReason == nil && parameterCount == nil && quantization == nil
            && created == nil
    }

    /// Both prices published and both zero: the provider lists the model as
    /// free. Nil prices are unknown, not free.
    public var isFree: Bool {
        guard let input = inputPriceMicroPerMTok, let output = outputPriceMicroPerMTok else {
            return false
        }
        return input == 0 && output == 0
    }

    /// Overlay `other` on top of `self`: any field `other` knows about wins,
    /// unknown (`nil`) fields keep the receiver's value. Used when a generic
    /// OpenAI-compatible decode is enriched by a provider-specific catalog
    /// (e.g. xAI `/language-models`, Ollama `/api/tags`).
    public func merging(_ other: RemoteModelMetadata) -> RemoteModelMetadata {
        var merged = self
        if let value = other.displayName { merged.displayName = value }
        if let value = other.description { merged.description = value }
        if let value = other.contextLength { merged.contextLength = value }
        if let value = other.maxOutputTokens { merged.maxOutputTokens = value }
        if let value = other.supportsVision { merged.supportsVision = value }
        if let value = other.supportsToolCalling { merged.supportsToolCalling = value }
        if let value = other.supportsReasoning { merged.supportsReasoning = value }
        if let value = other.supportsAudioInput { merged.supportsAudioInput = value }
        if let value = other.inputPriceMicroPerMTok { merged.inputPriceMicroPerMTok = value }
        if let value = other.outputPriceMicroPerMTok { merged.outputPriceMicroPerMTok = value }
        if other.isDeprecated { merged.isDeprecated = true }
        if let value = other.deprecationReplacement { merged.deprecationReplacement = value }
        if let value = other.recommendedReason { merged.recommendedReason = value }
        if let value = other.parameterCount { merged.parameterCount = value }
        if let value = other.quantization { merged.quantization = value }
        if let value = other.created { merged.created = value }
        return merged
    }

    // MARK: - Unit conversions

    /// OpenRouter publishes prices as decimal strings in USD per *token*
    /// (e.g. `"0.0000025"`). Convert to micro-USD per million tokens:
    /// USD/token × 1e6 tokens × 1e6 micro = × 1e12. Returns nil for
    /// non-numeric or negative input (OpenRouter uses `-1` for "varies").
    public static func microPerMTok(fromUSDPerToken text: String?) -> Int64? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
            let usdPerToken = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
            usdPerToken >= 0
        else { return nil }
        let micro = usdPerToken * Decimal(sign: .plus, exponent: 12, significand: 1)
        return int64(rounding: micro)
    }

    /// Venice publishes USD per million tokens as a JSON number. Convert to
    /// micro-USD per million tokens (× 1e6).
    public static func microPerMTok(fromUSDPerMTok value: Double?) -> Int64? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return int64(rounding: Decimal(value) * Decimal(1_000_000))
    }

    /// xAI publishes integer USD *cents per 100 million tokens*. Per million
    /// tokens that is cents / 100; in micro-USD (1 cent = 10,000 micro):
    /// cents × 10,000 / 100 = cents × 100.
    public static func microPerMTok(fromCentsPer100MTok cents: Int?) -> Int64? {
        guard let cents, cents >= 0 else { return nil }
        return Int64(cents) * 100
    }

    private static func int64(rounding decimal: Decimal) -> Int64? {
        var value = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        let doubleValue = NSDecimalNumber(decimal: rounded).doubleValue
        guard doubleValue.isFinite, doubleValue >= 0, doubleValue < Double(Int64.max) else { return nil }
        return Int64(doubleValue)
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
