//
//  BrainSource.swift
//  osaurus
//
//  Lightweight value type for the Configure AI onboarding step's brain choice.
//  Selecting a brain is a payment-free event: it records the source and
//  advances onboarding.
//

import Foundation

// MARK: - Brain source

/// Where a dino's "brain" comes from. Recorded on the Configure AI step so the
/// funnel can join the path choice to the first message sent, and so the chosen
/// path can pin its model after onboarding finishes.
enum BrainSource: Equatable {
    /// A local MLX model running on this Mac.
    case local
    /// A bring-your-own-key cloud provider (OpenAI, Anthropic, xAI, Venice, …).
    case providerKey(ProviderPreset)

    /// Low-cardinality analytics token for `brain_source_selected` and the
    /// `brain_source` dimension on `message_sent`.
    var telemetryValue: String {
        switch self {
        case .local: return "local"
        case .providerKey: return "provider_key"
        }
    }

    /// The provider raw value for the `provider` analytics property — only the
    /// bring-your-own-key path carries one.
    var providerTelemetryValue: String? {
        if case .providerKey(let preset) = self { return preset.rawValue }
        return nil
    }
}
