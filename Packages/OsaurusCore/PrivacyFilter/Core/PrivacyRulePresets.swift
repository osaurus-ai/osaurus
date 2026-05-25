//
//  PrivacyRulePresets.swift
//  osaurus / PrivacyFilter
//
//  Opt-in catalogue of well-known PII / secret patterns the user can
//  enable from settings without writing regex by hand. Each preset
//  has a stable string id (used as the persistence key in
//  `PrivacyFilterConfiguration.presetRules`) so renaming a preset's
//  display name later doesn't reset user choices.
//
//  Patterns are intentionally conservative — we'd rather miss a
//  weird local format than fire on common English words. False
//  positives still show up in the review sheet for the user to
//  untick, but they erode trust faster than false negatives here.
//

import Foundation

public enum PrivacyRulePresets {
    /// One catalogue entry. `id` is the persistence key; `pattern`
    /// is the raw regex string; `sample` is shown in the settings UI
    /// so users can sanity-check what the preset is supposed to
    /// catch before turning it on.
    public struct Preset: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let pattern: String
        public let category: EntityCategory
        public let sample: String

        public init(
            id: String,
            name: String,
            pattern: String,
            category: EntityCategory,
            sample: String
        ) {
            self.id = id
            self.name = name
            self.pattern = pattern
            self.category = category
            self.sample = sample
        }
    }

    /// US driver's license — pattern is intentionally generic across
    /// states (8-9 alphanumerics anchored by the phrase "license")
    /// because per-state shapes diverge enough that listing them all
    /// here would blow up the false-positive rate on every digit run.
    public static let driversLicense = Preset(
        id: "driversLicense",
        name: "US Driver's License",
        pattern: #"(?i)\b(?:DL|driver'?s?\s*license)[#:\s]*([A-Z0-9]{6,12})\b"#,
        category: .accountNumber,
        sample: "DL: A1234567"
    )

    /// US passport — 9 digits, optionally preceded by a single
    /// capital letter (newer issuances). The "passport" keyword
    /// anchor cuts out random 9-digit numerics.
    public static let passport = Preset(
        id: "passport",
        name: "US Passport Number",
        pattern: #"(?i)\bpassport[#:\s]*([A-Z]?\d{9})\b"#,
        category: .accountNumber,
        sample: "Passport: 123456789"
    )

    /// IBAN — 2 letter country code, 2 check digits, up to 30
    /// alphanumerics. Word-anchored on both sides; the spec allows
    /// internal spaces but storing them is bank-dependent and we'd
    /// rather miss a spaced variant than flag every two-letter+digits
    /// run as a bank account.
    public static let iban = Preset(
        id: "iban",
        name: "IBAN (Bank Account)",
        pattern: #"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#,
        category: .accountNumber,
        sample: "GB82WEST12345698765432"
    )

    /// AWS access key id — `AKIA` (long-lived) or `ASIA` (session
    /// token) prefix followed by 16 base32 uppercase chars.
    public static let awsKey = Preset(
        id: "awsKey",
        name: "AWS Access Key",
        pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        category: .secret,
        sample: "AKIAIOSFODNN7EXAMPLE"
    )

    /// GitHub PAT family — `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`
    /// prefix + 36+ url-safe chars. Covers both fine-grained and
    /// classic tokens since they share the underscore-prefix shape.
    public static let githubToken = Preset(
        id: "githubToken",
        name: "GitHub Token",
        pattern: #"\bgh[pousr]_[A-Za-z0-9]{36,251}\b"#,
        category: .secret,
        sample: "ghp_1234567890abcdef1234567890abcdef1234"
    )

    /// Full catalogue. Order here drives the order rows render in
    /// the settings panel, so list category-by-category rather than
    /// alphabetically.
    public static let all: [Preset] = [
        driversLicense,
        passport,
        iban,
        awsKey,
        githubToken,
    ]

    /// Lookup by id — used by the detector when applying the
    /// `presetRules` enabled map from the config snapshot.
    public static func preset(id: String) -> Preset? {
        all.first { $0.id == id }
    }
}
