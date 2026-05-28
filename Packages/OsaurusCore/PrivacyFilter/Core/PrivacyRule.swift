//
//  PrivacyRule.swift
//  osaurus / PrivacyFilter
//
//  User-defined regex rule for the configurable detection layer. One
//  `PrivacyRule` instance is a row in the "Custom rules" settings
//  section: it carries a display name, a raw regex pattern, the
//  category its hits should be filed under (so substitutions reuse
//  the standard `[CATEGORY_N]` placeholder shape), and an enabled
//  toggle so users can keep a pattern around without it firing.
//
//  Compilation is the detector's responsibility — this type is just
//  the persisted shape and is intentionally Codable + Sendable so it
//  flows through the `PrivacyFilterConfiguration` snapshot.
//

import Foundation

public struct PrivacyRule: Codable, Identifiable, Hashable, Sendable {
    /// Stable identifier — survives renames and pattern edits so the
    /// detector's compiled-regex cache can invalidate entries
    /// keyed by `(id, pattern)` when the pattern text changes.
    public let id: UUID

    /// Display name shown in settings and (when this rule produces a
    /// hit) in the redaction review sheet.
    public var name: String

    /// Raw `NSRegularExpression` pattern source.
    public var pattern: String

    /// Category placeholder tokens use — `.secret` is the typical
    /// pick for API keys / IDs the built-in classifier doesn't model.
    public var category: EntityCategory

    /// User-facing on/off without forcing them to delete the rule.
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        category: EntityCategory,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.category = category
        self.enabled = enabled
    }
}
