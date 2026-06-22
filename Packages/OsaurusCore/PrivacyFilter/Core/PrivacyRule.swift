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

    /// Raw `NSRegularExpression` pattern source. Used directly when
    /// `kind == .regex`; ignored (and typically empty) when
    /// `kind == .builder`, where `builder.compile()` produces the
    /// effective pattern instead.
    public var pattern: String

    /// Category placeholder tokens use — `.secret` is the typical
    /// pick for API keys / IDs the built-in classifier doesn't model.
    public var category: EntityCategory

    /// User-facing on/off without forcing them to delete the rule.
    public var enabled: Bool

    /// Whether this rule carries a raw regex (`.regex`, the default and
    /// the only shape older config files know) or a structured
    /// `RuleBuilder` spec (`.builder`) authored in the editor's "Simple"
    /// mode so the user never has to write regex.
    public var kind: RuleKind

    /// Case-insensitive matching when false. Default `true` preserves
    /// the historical behaviour (custom rules used to compile with
    /// `options: []`, i.e. case-sensitive).
    public var caseSensitive: Bool

    /// Structured match spec, present only when `kind == .builder`.
    public var builder: RuleBuilder?

    /// Optional custom placeholder label, e.g. `CUSTOMER` mints
    /// `[CUSTOMER_1]` instead of the category default `[SECRET_1]`.
    /// `nil` uses the category prefix. Sanitized to uppercase ASCII
    /// letters at use (`effectivePlaceholderLabel`) so the inbound
    /// `StreamingUnscrubber` — which only recognises `[A-Z]+_<digits>`
    /// tokens — can still restore it on the response.
    public var placeholderLabel: String?

    public init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        category: EntityCategory,
        enabled: Bool = true,
        kind: RuleKind = .regex,
        caseSensitive: Bool = true,
        builder: RuleBuilder? = nil,
        placeholderLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.category = category
        self.enabled = enabled
        self.kind = kind
        self.caseSensitive = caseSensitive
        self.builder = builder
        self.placeholderLabel = placeholderLabel
    }

    /// `placeholderLabel` sanitized to uppercase ASCII letters, or
    /// `nil` when unset / empty after sanitizing. Centralises the
    /// `[A-Z]+` constraint the placeholder-token recogniser
    /// (`StreamingUnscrubber.looksLikePlaceholder`) enforces, so a
    /// hand-edited or stale label can never mint a token that fails
    /// to unscrub on the inbound side.
    public var effectivePlaceholderLabel: String? {
        Self.sanitizedLabel(placeholderLabel)
    }

    public static func sanitizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let scalars = raw.uppercased().unicodeScalars.filter { $0 >= "A" && $0 <= "Z" }
        let filtered = String(String.UnicodeScalarView(scalars))
        return filtered.isEmpty ? nil : filtered
    }

    /// The regex source the detector should compile, resolving the
    /// builder when present. Returns `nil` when a builder rule has
    /// insufficient input (e.g. no terms) so the detector can drop it
    /// cleanly — same posture as an uncompilable raw pattern.
    public var effectivePattern: String? {
        switch kind {
        case .regex:
            return pattern
        case .builder:
            return builder?.compile()
        }
    }

    // MARK: - Codable (hand-rolled for forward/backward compat)

    private enum CodingKeys: String, CodingKey {
        case id, name, pattern, category, enabled, kind, caseSensitive, builder
        case placeholderLabel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        // Lenient on fields that, while always written by current
        // builds, might be absent in a hand-edited or future file —
        // a single missing key must not fail the whole config decode
        // and reset every privacy setting (PrivacyFilterStore.load
        // falls back to .default on any throw).
        self.pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        self.category = try c.decode(EntityCategory.self, forKey: .category)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.kind = try c.decodeIfPresent(RuleKind.self, forKey: .kind) ?? .regex
        self.caseSensitive =
            try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? true
        self.builder = try c.decodeIfPresent(RuleBuilder.self, forKey: .builder)
        self.placeholderLabel = try c.decodeIfPresent(String.self, forKey: .placeholderLabel)
    }
}

/// Whether a `PrivacyRule` is a raw regex or a structured builder.
public enum RuleKind: String, Codable, Hashable, Sendable, CaseIterable {
    case regex
    case builder
}

/// Structured, no-regex match specification compiled into an
/// `NSRegularExpression` source by `compile()`. Backs the editor's
/// "Simple" mode: the user picks a match type and types literals; we
/// generate (and escape) the pattern so a malformed regex is
/// impossible by construction.
public struct RuleBuilder: Codable, Hashable, Sendable {
    /// The bucket of match the user is expressing.
    public enum MatchType: String, Codable, Hashable, Sendable, CaseIterable {
        /// Whole word(s)/phrase(s), bounded by `\b`.
        case exactWord
        /// Any of the literal terms, anywhere (substring) — the
        /// "redact this list of strings" mode.
        case anyOfTerms
        /// A token that starts with one of the terms.
        case startsWith
        /// A token that ends with one of the terms.
        case endsWith
        /// A token that contains one of the terms.
        case contains
        /// A run of digits of a configurable length.
        case numberSequence
        /// Everything between a start marker and an end marker.
        case betweenMarkers
    }

    public var matchType: MatchType
    /// Literal terms for the term-based match types. Auto-escaped.
    public var terms: [String]
    /// Minimum digit count for `.numberSequence`.
    public var digitsMin: Int
    /// Maximum digit count for `.numberSequence`. `0` (or less than
    /// `digitsMin`) means "no upper bound".
    public var digitsMax: Int
    /// Delimiters for `.betweenMarkers`. Auto-escaped.
    public var startMarker: String
    public var endMarker: String

    public init(
        matchType: MatchType = .anyOfTerms,
        terms: [String] = [],
        digitsMin: Int = 4,
        digitsMax: Int = 0,
        startMarker: String = "",
        endMarker: String = ""
    ) {
        self.matchType = matchType
        self.terms = terms
        self.digitsMin = digitsMin
        self.digitsMax = digitsMax
        self.startMarker = startMarker
        self.endMarker = endMarker
    }

    // MARK: - Codable (lenient so older/newer files round-trip)

    private enum CodingKeys: String, CodingKey {
        case matchType, terms, digitsMin, digitsMax, startMarker, endMarker
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.matchType =
            try c.decodeIfPresent(MatchType.self, forKey: .matchType) ?? .anyOfTerms
        self.terms = try c.decodeIfPresent([String].self, forKey: .terms) ?? []
        self.digitsMin = try c.decodeIfPresent(Int.self, forKey: .digitsMin) ?? 4
        self.digitsMax = try c.decodeIfPresent(Int.self, forKey: .digitsMax) ?? 0
        self.startMarker = try c.decodeIfPresent(String.self, forKey: .startMarker) ?? ""
        self.endMarker = try c.decodeIfPresent(String.self, forKey: .endMarker) ?? ""
    }

    /// Cleaned, non-empty terms in author order.
    private var cleanedTerms: [String] {
        terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Build the `NSRegularExpression` source. Returns `nil` when the
    /// required inputs for the chosen match type are missing, so both
    /// the editor (disable Save) and the detector (drop the rule) can
    /// react without compiling a degenerate pattern.
    public func compile() -> String? {
        switch matchType {
        case .exactWord, .anyOfTerms, .startsWith, .endsWith, .contains:
            let cleaned = cleanedTerms
            guard !cleaned.isEmpty else { return nil }
            let alt =
                cleaned
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            let group = "(?:\(alt))"
            // A token continuation that includes the common word /
            // identifier punctuation so startsWith/contains capture a
            // whole token rather than just the literal fragment.
            let run = #"[\w.\-]*"#
            switch matchType {
            case .exactWord:
                return #"\b"# + group + #"\b"#
            case .anyOfTerms:
                return group
            case .startsWith:
                return #"\b"# + group + run
            case .endsWith:
                return run + group + #"\b"#
            case .contains:
                return run + group + run
            default:
                return nil
            }
        case .numberSequence:
            guard digitsMin > 0 else { return nil }
            if digitsMax >= digitsMin {
                return #"\b\d{"# + "\(digitsMin),\(digitsMax)" + #"}\b"#
            }
            return #"\b\d{"# + "\(digitsMin)," + #"}\b"#
        case .betweenMarkers:
            let s = startMarker.trimmingCharacters(in: .whitespacesAndNewlines)
            let e = endMarker.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, !e.isEmpty else { return nil }
            let es = NSRegularExpression.escapedPattern(for: s)
            let ee = NSRegularExpression.escapedPattern(for: e)
            // Non-greedy so consecutive marked spans don't collapse
            // into one giant match.
            return es + #"[\s\S]*?"# + ee
        }
    }
}
