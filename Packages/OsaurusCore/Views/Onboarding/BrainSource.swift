//
//  BrainSource.swift
//  osaurus
//
//  Lightweight value types for the Configure AI onboarding step's brain
//  choice. Selecting a brain is a payment-free event: it records the source
//  and advances onboarding. Funding (for the hosted path) is initiated later,
//  at or just before first send.
//

import SwiftUI

// MARK: - Brain source

/// Where a dino's "brain" comes from. Recorded on the Configure AI step so the
/// funnel can join the path choice to the first message sent, and so the
/// hosted path can pin its routed model after onboarding finishes.
enum BrainSource: Equatable {
    /// A local MLX model running on this Mac.
    case local
    /// Osaurus hosted — routed through Venice via the managed Osaurus Router
    /// and billed against a prepaid balance. No API key, no separate signup.
    case hostedOsaurus
    /// A bring-your-own-key cloud provider (OpenAI, Anthropic, xAI, Venice, …).
    case providerKey(ProviderPreset)

    /// Low-cardinality analytics token for `brain_source_selected` and the
    /// `brain_source` dimension on `message_sent`.
    var telemetryValue: String {
        switch self {
        case .local: return "local"
        case .hostedOsaurus: return "hosted"
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

// MARK: - Venice privacy tier

/// Venice privacy posture for the model(s) exposed on the hosted path. Drives
/// the hosted card's privacy copy so a later change to which models the router
/// exposes can't silently leave a stale no-storage claim on screen.
enum VenicePrivacyTier: String {
    /// Contract-enforced zero retention (Venice Private). The no-storage line
    /// is accurate.
    case privateZeroRetention
    /// Frontier provider may retain content (Venice Anonymous). The no-storage
    /// line does NOT hold for these models.
    case anonymized
    /// Hardware-isolated secure enclave (Venice Pro TEE).
    case tee
    /// End-to-end encrypted (Venice Pro E2EE).
    case e2ee

    /// Analytics token for the `privacy_tier` property on
    /// `brain_source_selected`. Explicit snake_case (not the camelCase raw
    /// value) to match the other low-cardinality telemetry tokens.
    var telemetryValue: String {
        switch self {
        case .privateZeroRetention: return "private_zero_retention"
        case .anonymized: return "anonymized"
        case .tee: return "tee"
        case .e2ee: return "e2ee"
        }
    }

    /// Privacy line. Attributed to Venice's stated policy rather than an
    /// absolute Osaurus guarantee, and qualified by routing. The no-storage
    /// claim appears only for the tier where it actually holds.
    var privacyLine: LocalizedStringKey {
        switch self {
        case .privateZeroRetention:
            return
                "Your chats stay on your Mac. Inference is routed through Venice, a privacy-first provider whose policy is not to store prompts or responses."
        case .anonymized:
            return
                "Your chats stay on your Mac. Inference is routed through Venice; for this model the underlying provider may retain content."
        case .tee:
            return
                "Your chats stay on your Mac. Inference runs in Venice's hardware-isolated secure enclave."
        case .e2ee:
            return "Your chats stay on your Mac. Inference is end-to-end encrypted through Venice."
        }
    }
}

// MARK: - Hosted option

/// The managed-cloud ("Osaurus Cloud") option surfaced as the always-visible,
/// pre-selected lead card above the brain step's tabs. Stored state is all
/// `Sendable`, so the shared `default` is concurrency-safe.
struct HostedOption {
    let privacyTier: VenicePrivacyTier

    /// Funding-model value line for the card. Deliberately rail-neutral: the
    /// payment rail is an open decision and the live flow is browser checkout,
    /// so the card does not name a specific method (e.g. Apple Pay) it can't
    /// guarantee. Lives here, not on `VenicePrivacyTier`, because it's a
    /// property of the offering rather than of any privacy posture.
    var valueLine: LocalizedStringKey {
        "Pay as you go. No API key, no separate signup."
    }

    /// The single Private-tier default. A single default keeps the privacy copy
    /// stable and the card simple (open decision 9.5 — single default, not a
    /// per-model picker).
    static let `default` = HostedOption(privacyTier: .privateZeroRetention)
}
