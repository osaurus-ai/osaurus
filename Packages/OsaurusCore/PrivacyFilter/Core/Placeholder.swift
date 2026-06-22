//
//  Placeholder.swift
//  osaurus / PrivacyFilter
//
//  Stable placeholder tokens emitted into outbound LLM payloads in
//  place of detected PII. The token shape (`[CATEGORY_N]`) is also what
//  `StreamingUnscrubber` looks for on the inbound side, so the prefix
//  table here is the single source of truth for both directions.
//

import Foundation

/// Privacy-filter category exposed in placeholders, settings UI, and
/// review sheets. Maps 1:1 to the vendored `EntityType` from
/// `PrivacyFilterKit` but uses Osaurus-side prefixes so the token
/// strings stay short and grep-friendly.
public enum EntityCategory: String, CaseIterable, Codable, Sendable {
    case accountNumber
    case address
    case email
    case person
    case phone
    case url
    case date
    case secret

    /// Short uppercase prefix used inside placeholder tokens, e.g.
    /// `[PERSON_1]`. Kept short so models don't waste attention on it.
    public var prefix: String {
        switch self {
        case .accountNumber: return "ACCT"
        case .address: return "ADDR"
        case .email: return "EMAIL"
        case .person: return "PERSON"
        case .phone: return "PHONE"
        case .url: return "URL"
        case .date: return "DATE"
        case .secret: return "SECRET"
        }
    }

    /// Localization key for the human-readable category name shown in
    /// the settings UI (rule rows, dry-run groups, the category picker)
    /// and the review sheet / block messages. Single source of truth so
    /// the settings, review, and pipeline call sites can't drift apart.
    public var localizationKey: String {
        switch self {
        case .accountNumber: return "privacy.category.accountNumber"
        case .address: return "privacy.category.address"
        case .email: return "privacy.category.email"
        case .person: return "privacy.category.person"
        case .phone: return "privacy.category.phone"
        case .url: return "privacy.category.url"
        case .date: return "privacy.category.date"
        case .secret: return "privacy.category.secret"
        }
    }

    /// `localizationKey` resolved against the package catalog — the
    /// display name for String contexts (block messages, review rows)
    /// that can't use a SwiftUI `LocalizedStringKey`. View code should
    /// prefer `LocalizedStringKey(localizationKey)` so SwiftUI tracks
    /// locale changes.
    public var localizedName: String {
        String(localized: String.LocalizationValue(stringLiteral: localizationKey), bundle: .module)
    }

    /// Build a category from the vendored kit's `EntityType` enum.
    /// Kept as a free initializer (rather than a typealias) so the
    /// kit's wire-format strings can drift without breaking the
    /// settings/UI side.
    public init?(_ vendor: EntityType) {
        switch vendor {
        case .accountNumber: self = .accountNumber
        case .address: self = .address
        case .email: self = .email
        case .person: self = .person
        case .phone: self = .phone
        case .url: self = .url
        case .date: self = .date
        case .secret: self = .secret
        }
    }
}

/// A specific placeholder occurrence — `category` + an index counted
/// per-category within a single `RedactionMap`. Two distinct originals
/// of the same category get different indices; one original used many
/// times in the same conversation reuses one placeholder (the map
/// interns by original string).
public struct Placeholder: Hashable, Codable, Sendable {
    public let category: EntityCategory
    public let index: Int

    /// Optional custom prefix from a `PrivacyRule.placeholderLabel`,
    /// already sanitized to uppercase ASCII letters. `nil` falls back
    /// to `category.prefix`. Optional so older encoded placeholders
    /// (without the key) still decode (missing → `nil`).
    public let prefixOverride: String?

    public init(category: EntityCategory, index: Int, prefixOverride: String? = nil) {
        self.category = category
        self.index = index
        self.prefixOverride = prefixOverride
    }

    /// The effective uppercase prefix used in the token: the custom
    /// label when set, otherwise the category default.
    public var prefix: String { prefixOverride ?? category.prefix }

    /// Wire format: `[PERSON_1]`, `[EMAIL_3]`, `[CUSTOMER_2]`, etc.
    public var token: String { "[\(prefix)_\(index)]" }
}
