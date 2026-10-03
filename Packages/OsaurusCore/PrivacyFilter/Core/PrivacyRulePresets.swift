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
//  The catalogue is region-aware. Every preset carries an ISO 3166-1
//  alpha-2 `regionCode` (`nil` = Global) and one of three tiers:
//
//    • `.validated` — the ID has a public check digit, so the
//      pattern may fire on a bare number; `validator` rejects the
//      ~90 % of same-shaped digit runs that fail the checksum.
//    • `.anchored` — fixed shape but no checksum. The pattern
//      requires the document's local name / abbreviation nearby
//      (e.g. `CNIC`, `cédula`) so random digit runs don't fire.
//    • `.generic` — Global, multilingual keyword-anchored fallbacks
//      (passport / ID card / licence / tax ID / bank account) that
//      give every ISO region baseline coverage, including the ones
//      with no country-specific preset.
//
//  Patterns are intentionally conservative — we'd rather miss a
//  weird local format than fire on common words. False positives
//  still show up in the review sheet for the user to untick, but
//  they erode trust faster than false negatives here.
//
//  The per-region catalogue files (`PrivacyRulePresets+Global.swift`,
//  `+Americas`, `+EuropeWest`, `+EuropeEast`, `+AsiaPacific`,
//  `+MiddleEastAfrica`) each contribute a static array; `all`
//  concatenates them in display order.
//

import Foundation

public enum PrivacyRulePresets {
    // MARK: - Model

    /// What kind of document / value a preset targets. Drives the
    /// row icon and the sort order inside a region group.
    public enum Kind: String, Sendable, CaseIterable, Hashable {
        case nationalID
        case taxID
        case healthID
        case passport
        case driversLicense
        case bankAccount
        case network
        case crypto
        case secret
        case generic

        /// SF Symbol for the row.
        public var symbolName: String {
            switch self {
            case .nationalID: return "person.text.rectangle"
            case .taxID: return "doc.text"
            case .healthID: return "cross.case"
            case .passport: return "airplane"
            case .driversLicense: return "car"
            case .bankAccount: return "building.columns"
            case .network: return "network"
            case .crypto: return "bitcoinsign.circle"
            case .secret: return "key"
            case .generic: return "globe"
            }
        }

        /// Display order inside a region group.
        var sortOrder: Int {
            switch self {
            case .nationalID: return 0
            case .taxID: return 1
            case .healthID: return 2
            case .passport: return 3
            case .driversLicense: return 4
            case .bankAccount: return 5
            case .generic: return 6
            case .network: return 7
            case .crypto: return 8
            case .secret: return 9
            }
        }
    }

    /// How much the pattern can be trusted to fire on its own.
    public enum Tier: String, Sendable, Hashable {
        /// Checksum-verified; may match bare numbers.
        case validated
        /// Shape + keyword anchor; no checksum available.
        case anchored
        /// Multilingual keyword fallback (Global group only).
        case generic

        /// Localization key for the short hint shown under the row.
        public var localizationKey: String { "privacy.presets.tier.\(rawValue)" }
    }

    /// For Global presets: when does choosing a region auto-enable
    /// this preset? Region-scoped presets ignore this (they're always
    /// enabled with their own region).
    public enum AutoEnable: Sendable, Hashable {
        /// Never auto-enabled; strictly opt-in (secrets, network, crypto).
        case never
        /// Enabled whenever at least one region is chosen (generic fallbacks).
        case anyRegion
        /// Enabled when any chosen region is in the set (IBAN, EU VAT).
        case regions(Set<String>)
    }

    /// One catalogue entry. `id` is the persistence key; `pattern` is
    /// the raw regex source; `sample` must match and pass the
    /// validator; `counterexample` must not (tests enforce both).
    ///
    /// Patterns that carry a keyword anchor put the redactable token
    /// in capture group 1 — the detector substitutes only that group,
    /// so the model still sees "Passport: [ACCT_1]" and knows what
    /// kind of value was removed. Patterns without a group redact the
    /// whole match.
    public struct Preset: Identifiable, Hashable, Sendable {
        public let id: String
        /// English display title (xcstrings `privacy.presets.<id>.title`
        /// overrides it at render time; this is the fallback).
        public let name: String
        /// English one-line description (fallback for
        /// `privacy.presets.<id>.description`).
        public let summary: String
        public let pattern: String
        public let category: EntityCategory
        public let sample: String
        public let counterexample: String?
        /// ISO 3166-1 alpha-2, or `nil` for Global.
        public let regionCode: String?
        public let kind: Kind
        public let tier: Tier
        public let autoEnable: AutoEnable
        /// Post-filter run on the captured token. `nil` = accept
        /// everything the regex matched.
        public let validator: (@Sendable (String) -> Bool)?

        public init(
            id: String,
            name: String,
            summary: String,
            pattern: String,
            category: EntityCategory,
            sample: String,
            counterexample: String? = nil,
            regionCode: String?,
            kind: Kind,
            tier: Tier,
            autoEnable: AutoEnable = .never,
            validator: (@Sendable (String) -> Bool)? = nil
        ) {
            self.id = id
            self.name = name
            self.summary = summary
            self.pattern = pattern
            self.category = category
            self.sample = sample
            self.counterexample = counterexample
            self.regionCode = regionCode
            self.kind = kind
            self.tier = tier
            self.autoEnable = autoEnable
            self.validator = validator
        }

        public static func == (lhs: Preset, rhs: Preset) -> Bool { lhs.id == rhs.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }

        /// Localization key of the display title.
        public var titleKey: String { "privacy.presets.\(id).title" }
        /// Localization key of the description.
        public var descriptionKey: String { "privacy.presets.\(id).description" }

        /// Title resolved against the package catalog, falling back to
        /// the English `name` when the key is absent.
        public var localizedTitle: String {
            Bundle.module.localizedString(forKey: titleKey, value: name, table: nil)
        }

        /// Description resolved against the package catalog, falling
        /// back to the English `summary`.
        public var localizedSummary: String {
            Bundle.module.localizedString(forKey: descriptionKey, value: summary, table: nil)
        }
    }

    // MARK: - Catalogue

    /// Full catalogue. Global first, then regions in the order the
    /// per-region files list them; the UI regroups by region anyway.
    public static let all: [Preset] =
        global + americas + europeWest + europeEast + asiaPacific + middleEastAfrica

    private static let byId: [String: Preset] = {
        var map: [String: Preset] = [:]
        for preset in all { map[preset.id] = preset }
        return map
    }()

    /// Lookup by id — used by the detector when applying the
    /// `presetRules` enabled map from the config snapshot.
    public static func preset(id: String) -> Preset? {
        byId[id]
    }

    /// Global (region-less) presets, in catalogue order.
    public static let globalPresets: [Preset] = all.filter { $0.regionCode == nil }

    /// Region → its presets sorted by kind then title. Built once; the
    /// Rules tab asks for this per region per render, and the region
    /// picker asks for ~250 regions per keystroke, so a linear filter
    /// over the 200+ catalogue each call beachballed the UI.
    private static let byRegion: [String: [Preset]] = {
        var map: [String: [Preset]] = [:]
        for preset in all {
            guard let region = preset.regionCode else { continue }
            map[region, default: []].append(preset)
        }
        for key in map.keys {
            map[key]?.sort {
                if $0.kind.sortOrder != $1.kind.sortOrder { return $0.kind.sortOrder < $1.kind.sortOrder }
                return $0.name < $1.name
            }
        }
        return map
    }()

    /// Every region code that has at least one specific preset,
    /// sorted by the current locale's display name.
    public static let regionCodes: [String] =
        byRegion.keys.sorted { regionDisplayName($0) < regionDisplayName($1) }

    /// Presets for one region (not Global), sorted by kind then title.
    public static func presets(in regionCode: String) -> [Preset] {
        byRegion[regionCode] ?? []
    }

    /// Whether `regionCode` has country-specific (Tier 1/2) presets.
    /// Regions without any still get the Global generic fallbacks.
    public static func hasSpecificCoverage(_ regionCode: String) -> Bool {
        byRegion[regionCode] != nil
    }

    /// The preset ids that should be ON for a user whose home regions
    /// are `regions`: every preset scoped to one of those regions,
    /// plus the Global presets whose `autoEnable` rule says so. Empty
    /// input yields an empty map (nothing is implied by "no region").
    public static func defaultPresetRules(forRegions regions: [String]) -> [String: Bool] {
        let chosen = Set(regions.map { $0.uppercased() })
        guard !chosen.isEmpty else { return [:] }
        var map: [String: Bool] = [:]
        for preset in all {
            if let region = preset.regionCode {
                if chosen.contains(region) { map[preset.id] = true }
                continue
            }
            switch preset.autoEnable {
            case .never:
                continue
            case .anyRegion:
                map[preset.id] = true
            case .regions(let set):
                if !set.isDisjoint(with: chosen) { map[preset.id] = true }
            }
        }
        return map
    }

    // MARK: - Region helpers

    /// Localized country / region name via the OS, e.g. "Germany".
    /// Falls back to the code itself when the OS has no name for it.
    public static func regionDisplayName(_ regionCode: String, locale: Locale = .current) -> String {
        let key = locale.identifier + "|" + regionCode
        displayNameLock.lock()
        defer { displayNameLock.unlock() }
        if let cached = displayNameCache[key] { return cached }
        let name = locale.localizedString(forRegionCode: regionCode) ?? regionCode
        displayNameCache[key] = name
        return name
    }

    /// `Locale.localizedString(forRegionCode:)` is a CFLocale lookup that
    /// shows up in profiles once the picker asks for 250 names per
    /// keystroke; the answer never changes for a (locale, code) pair.
    private static let displayNameLock = NSLock()
    nonisolated(unsafe) private static var displayNameCache: [String: String] = [:]

    /// Regional-indicator flag emoji for an alpha-2 code ("US" → 🇺🇸).
    public static func regionFlag(_ regionCode: String) -> String {
        let base: UInt32 = 0x1F1E6
        var flag = ""
        for scalar in regionCode.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90,
                let indicator = UnicodeScalar(base + scalar.value - 65)
            else { return "" }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    /// Every ISO 3166-1 alpha-2 region the OS knows about, excluding
    /// the macro-regions (`001`, `150`, …) and the "unknown" code, so
    /// the region picker lists countries only.
    public static let allISORegionCodes: [String] =
        Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0 != "ZZ" && $0.allSatisfy(\.isLetter) }

    // MARK: - Shared regex fragments

    /// Separators tolerated between a keyword anchor and its value:
    /// `Passport: X`, `Passport # X`, `Passport No. X`, `Passport – X`.
    static let anchorGap = #"\s*(?:(?:no|nr|num|number|n°|nº|número|numero)\.?\s*)?[:#=\-–]?\s*"#

    /// IBAN-issuing countries (ISO 13616 registry + partials), used by
    /// the IBAN preset's auto-enable rule.
    static let ibanCountries: Set<String> = [
        "AD", "AE", "AL", "AT", "AZ", "BA", "BE", "BG", "BH", "BI", "BR", "BY", "CH", "CR", "CY", "CZ",
        "DE", "DJ", "DK", "DO", "EE", "EG", "ES", "FI", "FK", "FO", "FR", "GB", "GE", "GI", "GL", "GR",
        "GT", "HR", "HU", "IE", "IL", "IQ", "IS", "IT", "JO", "KW", "KZ", "LB", "LC", "LI", "LT", "LU",
        "LV", "LY", "MC", "MD", "ME", "MK", "MN", "MR", "MT", "MU", "NI", "NL", "NO", "OM", "PK", "PL",
        "PS", "PT", "QA", "RO", "RS", "RU", "SA", "SC", "SD", "SE", "SI", "SK", "SM", "SO", "ST", "SV",
        "TL", "TN", "TR", "UA", "VA", "VG", "XK", "YE", "DZ", "AO", "BJ", "BF", "CM", "CV", "CF", "TD",
        "KM", "CG", "CI", "GA", "GN", "GQ", "GW", "HN", "IR", "MG", "ML", "MA", "MZ", "NE", "SN", "TG",
    ]

    /// EU + EEA + UK/NI VAT-issuing countries, used by the EU VAT
    /// preset's auto-enable rule.
    static let euVATCountries: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV",
        "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "GB", "NO", "IS", "LI", "CH",
    ]
}
