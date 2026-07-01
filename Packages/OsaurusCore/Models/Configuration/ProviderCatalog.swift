//
//  ProviderCatalog.swift
//  osaurus
//
//  Single source of truth for the remote-provider picker. Every selectable
//  provider is described once here (preset + supported auth methods + where it
//  appears in the picker); onboarding, the settings add-sheet, and the
//  providers empty state all render from this catalog instead of hand-rolling
//  their own lists, cards, and per-provider auth branches.
//
//  Adding a new provider (for example a future hosted "Osaurus API") is a
//  single `ProviderCatalogEntry` here — no view edits required. See the
//  `Adding a provider` note on `ProviderCatalog` below.
//

import Foundation

// MARK: - Auth method

/// How a provider authenticates in the picker. Generalizes the old
/// per-provider credential-mode enums (OpenAI / OpenRouter / xAI) so new
/// providers declare their methods declaratively instead of bolting on a
/// bespoke enum plus a matching `if provider == .x` branch in every view.
///
/// Distinct from `ProviderAuthMethod` in `ProviderCredentialInstructions`
/// (a coarser apiKey/oauth split for the credential sheet) — this one carries
/// the concrete OAuth flavor the picker needs to route sign-in.
enum ProviderPickerAuthMethod: Equatable {
    /// Browser sign-in (PKCE). The associated `ProviderOAuthKind` selects the
    /// concrete OAuth service and its user-facing copy.
    case oauth(ProviderOAuthKind)
    /// A pasted API key, persisted to the Keychain.
    case apiKey
    /// No credential required (local servers such as Ollama).
    case none

    var isOAuth: Bool {
        if case .oauth = self { return true }
        return false
    }
}

/// The concrete OAuth flavor behind `ProviderPickerAuthMethod.oauth`. Owns the
/// browser-sign-in copy so the picker and forms don't special-case providers.
enum ProviderOAuthKind: String, Equatable, Sendable {
    case openAICodex
    case openRouter
    case xai

    /// Primary CTA label shown on the form's action button. Parallel
    /// "Sign in with <brand>" across providers; the subscription/account
    /// detail lives in `subtitle`.
    var ctaTitle: String {
        switch self {
        case .openAICodex: return "Sign in with ChatGPT"
        case .openRouter: return "Sign in with OpenRouter"
        case .xai: return "Sign in with Grok"
        }
    }

    /// One-line explanation shown as the OAuth picker-row subtitle and on the
    /// form's "here's what sign-in does" banner. Parallel "Uses your <account>"
    /// so the three OAuth rows read consistently.
    var subtitle: String {
        switch self {
        case .openAICodex: return "Uses your ChatGPT Plus/Pro subscription."
        case .openRouter: return "Uses your OpenRouter account."
        case .xai: return "Uses your SuperGrok or X Premium+ subscription."
        }
    }

    var icon: String { "person.crop.circle.badge.checkmark" }
}

// MARK: - Catalog entry

/// A single selectable provider in the picker.
struct ProviderCatalogEntry: Identifiable {
    let preset: ProviderPreset
    /// Supported auth methods in priority order. `authMethods.first` is the
    /// default for the surface the entry is selected from.
    let authMethods: [ProviderPickerAuthMethod]
    /// Primary location in the picker. Entries placed at `.oauthTopLevel` that
    /// also list `.apiKey` are additionally surfaced inside the "Use an API
    /// key" sub-list (see `ProviderCatalog.apiKeyGroups`), so a single entry
    /// can appear at both levels without being declared twice.
    let placement: Placement
    /// Subtitle for the entry's API-key picker row. Defaults to the preset's
    /// generic description; dual-mode providers override it with paste-a-key
    /// copy so the API-key row reads correctly even though the same provider
    /// also has an OAuth row at the top level.
    let apiKeySubtitle: String

    var id: String { preset.id }

    enum Placement: Equatable {
        /// One-click OAuth providers shown as first-class rows at the top.
        case oauthTopLevel
        /// Paste-a-key vendors shown only inside the "Use an API key" sub-list.
        case apiKey
        /// Local, no-key servers (Ollama).
        case local
        /// The custom / OpenAI-compatible escape hatch.
        case custom
    }

    init(
        _ preset: ProviderPreset,
        authMethods: [ProviderPickerAuthMethod],
        placement: Placement,
        apiKeySubtitle: String? = nil
    ) {
        self.preset = preset
        self.authMethods = authMethods
        self.placement = placement
        self.apiKeySubtitle = apiKeySubtitle ?? preset.description
    }

    /// The OAuth method this entry leads with, if any. Drives the top-level
    /// row subtitle and the form CTA / banner.
    var primaryOAuthKind: ProviderOAuthKind? {
        for method in authMethods {
            if case .oauth(let kind) = method { return kind }
        }
        return nil
    }

    var supportsAPIKey: Bool { authMethods.contains(.apiKey) }

    /// Subtitle for a picker row. `preferAPIKey` is true for rows rendered in
    /// the "Use an API key" sub-list; false for the OAuth-first top level.
    func pickerSubtitle(preferAPIKey: Bool) -> String {
        if preset == .custom { return "Together AI, LM Studio, and more" }
        if preferAPIKey { return apiKeySubtitle }
        if let kind = primaryOAuthKind { return kind.subtitle }
        return preset.description
    }
}

// MARK: - Catalog

/// The registry of selectable providers plus the grouping the picker renders.
///
/// ## Adding a provider
/// Append one `ProviderCatalogEntry` to `entries`. For example, a future hosted
/// Osaurus API provider is a single line here once it has a `ProviderPreset`
/// case whose `configuration.providerType` is `RemoteProviderType.osaurus`
/// (already defined) and, if it uses browser sign-in, a new
/// `ProviderOAuthKind.osaurus` carrying its CTA/subtitle copy:
/// ```swift
/// // OAuth-first, also accepts a pasted key:
/// ProviderCatalogEntry(.osaurus, authMethods: [.oauth(.osaurus), .apiKey], placement: .oauthTopLevel)
/// // or API-key only:
/// ProviderCatalogEntry(.osaurus, authMethods: [.apiKey], placement: .apiKey)
/// ```
/// No onboarding/settings/empty-state view changes are needed: the top level,
/// the API-key sub-list grouping, the shared row card, the CTA copy, and the
/// save/test branches all derive from the entry. (The save/test switch on
/// `ProviderOAuthKind` is the only place a brand-new OAuth flavor needs wiring,
/// to call its sign-in service.)
enum ProviderCatalog {
    /// One entry per selectable provider. Top-level OAuth providers lead (in
    /// curated order); the API-key sub-list is derived and alphabetized, so the
    /// raw order below only affects the top-level row order.
    static let entries: [ProviderCatalogEntry] = [
        ProviderCatalogEntry(
            .openai,
            authMethods: [.oauth(.openAICodex), .apiKey],
            placement: .oauthTopLevel,
            apiKeySubtitle: "Paste a key from platform.openai.com."
        ),
        ProviderCatalogEntry(
            .xai,
            authMethods: [.oauth(.xai), .apiKey],
            placement: .oauthTopLevel,
            apiKeySubtitle: "Paste a key from console.x.ai."
        ),
        ProviderCatalogEntry(
            .openrouter,
            authMethods: [.oauth(.openRouter), .apiKey],
            placement: .oauthTopLevel,
            apiKeySubtitle: "Paste a key from openrouter.ai/keys."
        ),
        ProviderCatalogEntry(.anthropic, authMethods: [.apiKey], placement: .apiKey),
        ProviderCatalogEntry(.atlasCloud, authMethods: [.apiKey], placement: .apiKey),
        ProviderCatalogEntry(.azureOpenAI, authMethods: [.apiKey], placement: .apiKey),
        ProviderCatalogEntry(.deepseek, authMethods: [.apiKey], placement: .apiKey),
        ProviderCatalogEntry(.google, authMethods: [.apiKey], placement: .apiKey),
        ProviderCatalogEntry(.mistral, authMethods: [.apiKey], placement: .apiKey),
        ProviderCatalogEntry(.minimax, authMethods: [.apiKey], placement: .apiKey),
        ProviderCatalogEntry(.venice, authMethods: [.apiKey], placement: .apiKey),
        ProviderCatalogEntry(.ollama, authMethods: [.none], placement: .local),
        ProviderCatalogEntry(.custom, authMethods: [.apiKey], placement: .custom),
    ]

    /// OAuth-first providers surfaced as first-class rows at the top, in the
    /// curated `entries` order.
    static var topLevel: [ProviderCatalogEntry] {
        entries.filter { $0.placement == .oauthTopLevel }
    }

    /// A labeled section in the "Use an API key" drill-in.
    struct Section: Identifiable {
        let id: String
        /// Localization key the view localizes via the `.module` bundle.
        let title: String
        let entries: [ProviderCatalogEntry]
    }

    /// Sections for the "Use an API key" drill-in: key vendors (including the
    /// dual-mode OAuth providers, since each also takes a pasted key), the local
    /// Ollama option, and the custom escape hatch. Onboarding omits Azure
    /// OpenAI (needs extra endpoint/deployment fields) via `includeAzure`.
    /// Empty sections are dropped.
    static func apiKeyGroups(includeAzure: Bool) -> [Section] {
        let keyVendors =
            entries
            .filter { $0.supportsAPIKey && ($0.placement == .oauthTopLevel || $0.placement == .apiKey) }
            .filter { includeAzure || $0.preset != .azureOpenAI }
            .sorted { $0.preset.name.localizedCaseInsensitiveCompare($1.preset.name) == .orderedAscending }
        let local = entries.filter { $0.placement == .local }
        let custom = entries.filter { $0.placement == .custom }
        return [
            Section(id: "apiKey", title: "API key", entries: keyVendors),
            Section(id: "local", title: "Local", entries: local),
            Section(id: "custom", title: "Custom", entries: custom),
        ].filter { !$0.entries.isEmpty }
    }

    static func entry(for preset: ProviderPreset) -> ProviderCatalogEntry? {
        entries.first { $0.preset == preset }
    }
}
