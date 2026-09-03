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
    /// The managed Osaurus Router — hosted models that are ready with no
    /// download or key. The onboarding default.
    case osaurus
    /// A local MLX model running on this Mac.
    case local
    /// A bring-your-own-key cloud provider (OpenAI, Anthropic, xAI, Venice, …).
    case providerKey(ProviderPreset)
    /// The user's own signed-in Claude Code CLI. Distinct from every other
    /// case: it stores no credential (the CLI owns the session), creates no
    /// `RemoteProvider`, and runs as a local subprocess even though the model
    /// itself is remote — so it is neither `local` nor `provider_key`.
    case claudeCode

    /// Low-cardinality analytics token for `brain_source_selected` and the
    /// `brain_source` dimension on `message_sent`. `hosted` matches the
    /// vocabulary `FeatureTelemetry.recordOnboardingBrainSource` documents
    /// (`local` | `hosted` | `provider_key` | `claude_code`).
    ///
    /// `claude_code` extends that vocabulary rather than folding into an
    /// existing token: reporting it as `local` would overstate on-device usage,
    /// and as `provider_key` would imply a stored credential that doesn't exist.
    var telemetryValue: String {
        switch self {
        case .osaurus: return "hosted"
        case .local: return "local"
        case .providerKey: return "provider_key"
        case .claudeCode: return "claude_code"
        }
    }

    /// The provider raw value for the `provider` analytics property — only the
    /// bring-your-own-key path carries one.
    var providerTelemetryValue: String? {
        if case .providerKey(let preset) = self { return preset.rawValue }
        return nil
    }
}
