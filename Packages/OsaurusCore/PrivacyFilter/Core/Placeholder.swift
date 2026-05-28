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

    public init(category: EntityCategory, index: Int) {
        self.category = category
        self.index = index
    }

    /// Wire format: `[PERSON_1]`, `[EMAIL_3]`, etc.
    public var token: String { "[\(category.prefix)_\(index)]" }
}
