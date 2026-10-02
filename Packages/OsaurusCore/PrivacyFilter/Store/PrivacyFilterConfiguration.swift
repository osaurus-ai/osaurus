//
//  PrivacyFilterConfiguration.swift
//  osaurus / PrivacyFilter
//
//  Persisted user settings for the Privacy Filter feature. Stored as
//  JSON under `~/.osaurus/config/privacy-filter.json`. Per-provider
//  toggles are keyed by `RemoteProvider.id` so a provider rename or
//  re-add can't accidentally drop the user's preference.
//
//  When the master toggle is off the rest of the fields are ignored
//  by the pipeline (we don't even load the model), but they're kept
//  intact on disk so flipping it back on doesn't lose the user's
//  per-provider choices.
//

import Foundation

/// Which on-device model backend powers AI detection.
/// - `openai`: the ~2.8 GB `mlx-community/openai-privacy-filter-bf16` MoE
///   classifier (highest coverage, large download).
/// - `rampart`: the ~37 MB `OsaurusAI/rampart-mlx` BERT token classifier
///   (tiny download, no `date` category, person/address/secret/account focus).
public enum PrivacyAIBackend: String, Codable, Sendable, CaseIterable {
    case openai
    case rampart

    /// True when this backend's bundle is on disk. Pure filesystem
    /// check (no actor hop) so `resolvedAIBackend` can be called from
    /// the outbound pipeline and the settings UI alike.
    public static func isBundleInstalled(_ backend: PrivacyAIBackend) -> Bool {
        switch backend {
        case .openai: return PrivacyFilterModelBundle.exists()
        case .rampart: return RampartModelManager.bundleExists()
        }
    }
}

/// Top-level privacy-filter preference shape. `Codable` so it
/// round-trips through `JSONEncoder` / `JSONDecoder` directly.
/// Decoder is hand-rolled (rather than synthesised) so new fields
/// can land with safe defaults instead of failing the whole decode
/// when an older on-disk config file is missing them.
public struct PrivacyFilterConfiguration: Codable, Equatable, Sendable {
    /// Schema version of the on-disk JSON. Today the decoder still
    /// uses `decodeIfPresent`-with-defaults for forward compat —
    /// adding a field is non-breaking and old files just take the
    /// default. The version field exists for the BREAKING case
    /// (e.g. rename a field, drop a category enum case) where the
    /// decoder needs to branch on the source schema instead of
    /// letting silent defaults paper over the change.
    ///
    /// Bump the constant when a new schema is published and add a
    /// matching `if encoded < currentSchemaVersion { migrate }`
    /// block in `init(from:)`. Files written by older Osaurus
    /// builds decode as `0` (key absent) and the migration block
    /// promotes them to the current shape.
    ///
    /// History:
    /// - 1: first versioned schema.
    /// - 2: US SSN moved from the `accountNumber` built-in into the
    ///   `us.ssn` preset; `homeRegions` added. Migration keeps SSN
    ///   detection on for files that had account numbers enabled and
    ///   seeds `homeRegions` from the Mac locale.
    public static let currentSchemaVersion: Int = 2

    /// Schema version that produced this in-memory value. Defaults
    /// to `currentSchemaVersion` for freshly-constructed objects
    /// (so re-saving doesn't lie about the source), and to the
    /// value read off disk for decoded ones.
    public var schemaVersion: Int

    /// Master switch. When false the pipeline never invokes detection,
    /// regardless of per-provider toggles.
    public var enabled: Bool

    /// Whether the on-device AI detection model participates in
    /// detection. The deterministic regex layer (built-ins, presets,
    /// custom rules) runs independently and needs no model, so the
    /// filter is fully usable with this OFF and the ~2.8 GB bundle
    /// never downloaded.
    ///
    /// When true the pipeline loads the model and FAILS CLOSED if the
    /// bundle is missing / corrupt — the user opted into AI detection
    /// and expects it. When false the model is never touched and
    /// detection runs regex-only (never blocks on a missing model).
    public var aiDetectionEnabled: Bool

    /// Which model backend the user picked as default for AI detection.
    /// Defaults to `.openai` for backward compatibility with installs
    /// that already downloaded that bundle. This is a preference, not
    /// a guarantee the bundle exists — callers must go through
    /// `resolvedAIBackend(isInstalled:)` to find the backend that will
    /// actually run.
    public var aiDetectionBackend: PrivacyAIBackend

    /// The backend AI detection actually runs with: the user's default
    /// when its bundle is installed, otherwise whichever other backend
    /// is installed, otherwise `nil`. Installing a single model must be
    /// enough to use it — a user who downloads only Rampart should never
    /// be blocked because the untouched default still says OpenAI.
    public func resolvedAIBackend(isInstalled: (PrivacyAIBackend) -> Bool) -> PrivacyAIBackend? {
        if isInstalled(aiDetectionBackend) { return aiDetectionBackend }
        return PrivacyAIBackend.allCases.first(where: isInstalled)
    }

    /// Per-provider enable map keyed by `RemoteProvider.id.uuidString`.
    /// Missing keys fall back to `defaultForCloudProvider` (true).
    public var providerOverrides: [String: Bool]

    /// Whether to skip detection inside fenced + inline code spans.
    /// Default on — avoids flagging identifiers as people-names.
    public var skipCodeBlocks: Bool

    /// When true the review sheet auto-confirms detected entities
    /// after the first turn of each conversation (per-conversation
    /// state still lives in `SessionRedactionStore`). This is the
    /// global default — sessions can flip back on their own.
    public var alwaysApproveByDefault: Bool

    /// When true, non-interactive callers (HTTP API on
    /// `/chat/completions` and `/agents/{id}/run`, plugin chat
    /// agents, headless tools) BLOCK sends that surface detections
    /// instead of silently auto-approving. The chat UI is unaffected
    /// because it always has a presenter registered.
    ///
    /// Default ON: the user enabled the filter expecting their PII
    /// to be reviewed, and a background caller bypassing the sheet
    /// breaks that expectation. Power users can flip this off if they
    /// rely on the HTTP API and accept the silent auto-approval.
    public var requireReviewForNonInteractive: Bool

    /// Per-category toggle for the built-in `RegexEntityDetector`
    /// patterns (phone / email / url / accountNumber). A `false`
    /// value here turns the category off for BOTH the detection
    /// pass and the post-scrub invariant — consistent so the user's
    /// "don't flag phones" choice doesn't also block legit phones in
    /// tool results. Categories not in the map default to `true`.
    public var builtinPatternEnabled: [EntityCategory: Bool]

    /// Preset rules keyed by `PrivacyRulePresets.Preset.id`. Missing
    /// keys default to `false`. A fresh install seeds the presets for
    /// the Mac's locale region (`freshInstall(locale:)`) and adding a
    /// region under "My Regions" seeds that region's presets; every
    /// other preset — and any preset a later Osaurus update adds — is
    /// opt-in so an update never surprises the user with new false
    /// positives.
    public var presetRules: [String: Bool]

    /// ISO 3166-1 alpha-2 region codes the user considers "home", in
    /// the order they added them. Drives the "My regions" section of
    /// the Rules tab and the suggestion banner. Seeded from the Mac
    /// locale on a fresh install (`freshInstall(locale:)`) and fully
    /// user-editable afterwards; `init()` leaves it empty so tests
    /// stay deterministic.
    public var homeRegions: [String]

    /// User-defined rules from the settings "Custom rules" panel.
    /// Empty by default. Bad/unparseable patterns are validated in
    /// the editor and silently dropped at detection time so an old
    /// rule that no longer compiles can't crash the pipeline.
    public var customRules: [PrivacyRule]

    public init(
        enabled: Bool = false,
        aiDetectionEnabled: Bool = false,
        aiDetectionBackend: PrivacyAIBackend = .openai,
        providerOverrides: [String: Bool] = [:],
        skipCodeBlocks: Bool = true,
        alwaysApproveByDefault: Bool = false,
        requireReviewForNonInteractive: Bool = true,
        builtinPatternEnabled: [EntityCategory: Bool] = Self.defaultBuiltinPatternEnabled,
        presetRules: [String: Bool] = [:],
        homeRegions: [String] = [],
        customRules: [PrivacyRule] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.enabled = enabled
        self.aiDetectionEnabled = aiDetectionEnabled
        self.aiDetectionBackend = aiDetectionBackend
        self.providerOverrides = providerOverrides
        self.skipCodeBlocks = skipCodeBlocks
        self.alwaysApproveByDefault = alwaysApproveByDefault
        self.requireReviewForNonInteractive = requireReviewForNonInteractive
        self.builtinPatternEnabled = builtinPatternEnabled
        self.presetRules = presetRules
        self.homeRegions = homeRegions
        self.customRules = customRules
    }

    /// The configuration a brand-new install starts from: master
    /// toggle off (unchanged), `homeRegions` seeded with the locale's
    /// region, and the presets `PrivacyRulePresets.defaultPresetRules`
    /// picks for that region switched on. Everything else keeps the
    /// `init()` defaults. `PrivacyFilterStore.snapshot()` returns this
    /// when no file exists on disk.
    public static func freshInstall(locale: Locale = .current) -> PrivacyFilterConfiguration {
        var config = PrivacyFilterConfiguration()
        if let region = Self.regionCode(from: locale) {
            config.homeRegions = [region]
        }
        config.presetRules = PrivacyRulePresets.defaultPresetRules(forRegions: config.homeRegions)
        return config
    }

    /// Upper-cased ISO region of `locale`, or `nil` when the locale
    /// has none (e.g. a bare language identifier like `en`).
    static func regionCode(from locale: Locale) -> String? {
        guard let region = locale.region?.identifier, !region.isEmpty else { return nil }
        let upper = region.uppercased()
        // Skip UN M.49 numeric codes (e.g. "001" world, "419" Latin
        // America) — the picker only lists alpha-2 regions.
        guard upper.count == 2, upper.allSatisfy(\.isLetter) else { return nil }
        return upper
    }

    /// Add `region` to `homeRegions` (no-op when present) and switch on
    /// the presets `PrivacyRulePresets.defaultPresetRules` picks for it,
    /// except keys the user already explicitly set to `false` — an
    /// opt-out must survive adding a neighbouring region.
    public mutating func addHomeRegion(_ region: String) {
        let code = region.uppercased()
        if !homeRegions.contains(code) {
            homeRegions.append(code)
        }
        for (id, on) in PrivacyRulePresets.defaultPresetRules(forRegions: [code]) where on {
            if presetRules[id] == nil {
                presetRules[id] = true
            }
        }
    }

    /// Remove `region` from `homeRegions`. Leaves `presetRules` alone:
    /// nothing is silently disabled; the group just moves to "Other
    /// regions" in the UI.
    public mutating func removeHomeRegion(_ region: String) {
        let code = region.uppercased()
        homeRegions.removeAll { $0 == code }
    }

    /// Categories backed by a built-in regex pattern. New built-ins
    /// added here must also extend `Self.defaultBuiltinPatternEnabled`
    /// so they're on by default for existing users.
    public static let builtinPatternCategories: [EntityCategory] = [
        .phone, .email, .url, .accountNumber,
    ]

    /// Default map: every built-in category enabled. Used both by
    /// `init` and by the Codable decoder to fill missing keys when
    /// reading an older config file.
    public static let defaultBuiltinPatternEnabled: [EntityCategory: Bool] = {
        var map: [EntityCategory: Bool] = [:]
        for category in builtinPatternCategories {
            map[category] = true
        }
        return map
    }()

    /// Whether the built-in regex for `category` is active. Returns
    /// `true` for categories not represented in the map (forward-
    /// compat: a future build adds a new built-in; older user files
    /// don't have a key for it so default to enabled).
    public func isBuiltinPatternEnabled(_ category: EntityCategory) -> Bool {
        builtinPatternEnabled[category] ?? true
    }

    /// Whether a preset is enabled. Missing keys default to `false`
    /// (presets are opt-in).
    public func isPresetEnabled(_ presetId: String) -> Bool {
        presetRules[presetId] ?? false
    }

    public static let `default` = PrivacyFilterConfiguration()

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabled
        case aiDetectionEnabled
        case aiDetectionBackend
        case providerOverrides
        case skipCodeBlocks
        case alwaysApproveByDefault
        case requireReviewForNonInteractive
        case builtinPatternEnabled
        case presetRules
        case homeRegions
        case customRules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Default 0 = "key absent" = pre-versioning config. Future
        // migrations branch off this value before decoding the rest
        // of the struct.
        self.schemaVersion =
            try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        // Default TRUE on decode (key absent) so users upgrading from a
        // build that predates this field — who had the model installed
        // and the master toggle on — keep AI detection after the
        // update. Brand-new configs come through `init` (default
        // FALSE) instead, so a fresh no-model install starts
        // regex-only without trying to download the bundle.
        self.aiDetectionEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .aiDetectionEnabled) ?? true
        // Default `.openai` on decode (key absent) so existing installs
        // keep their current backend; new configs come through `init`.
        self.aiDetectionBackend =
            try c.decodeIfPresent(PrivacyAIBackend.self, forKey: .aiDetectionBackend) ?? .openai
        self.providerOverrides =
            try c.decodeIfPresent([String: Bool].self, forKey: .providerOverrides) ?? [:]
        self.skipCodeBlocks =
            try c.decodeIfPresent(Bool.self, forKey: .skipCodeBlocks) ?? true
        // NOTE: a `confidenceThreshold` key may be present in older
        // on-disk files. It's intentionally ignored now (the setting
        // was always a no-op — the kit never exposed a threshold — so
        // it was removed rather than shipped as a dead slider). An
        // unknown key in the JSON decodes fine; we simply don't read
        // it, and `encode` no longer writes it.
        self.alwaysApproveByDefault =
            try c.decodeIfPresent(Bool.self, forKey: .alwaysApproveByDefault) ?? false
        self.requireReviewForNonInteractive =
            try c.decodeIfPresent(Bool.self, forKey: .requireReviewForNonInteractive) ?? true

        // `builtinPatternEnabled` is stored on disk as `[String: Bool]`
        // (category raw values), not `[EntityCategory: Bool]`. Swift's
        // default Codable encoding for an enum-keyed dictionary
        // produces an alternating-key/value array which is hostile to
        // human inspection and would also be a pain to roll forward
        // when a new category lands. We round-trip via raw values and
        // skip any keys that don't decode to a known category.
        var builtin: [EntityCategory: Bool] = [:]
        if let rawMap = try c.decodeIfPresent([String: Bool].self, forKey: .builtinPatternEnabled) {
            for (raw, value) in rawMap {
                if let category = EntityCategory(rawValue: raw) {
                    builtin[category] = value
                }
            }
        }
        // Fill any missing built-in category keys with `true`. This
        // is the migration path: configs written before this field
        // existed decode with an empty map → every built-in stays
        // enabled, matching the pre-config behaviour.
        for category in Self.builtinPatternCategories where builtin[category] == nil {
            builtin[category] = true
        }
        self.builtinPatternEnabled = builtin

        var presets =
            try c.decodeIfPresent([String: Bool].self, forKey: .presetRules) ?? [:]
        var regions =
            try c.decodeIfPresent([String].self, forKey: .homeRegions) ?? []
        self.customRules =
            try c.decodeIfPresent([PrivacyRule].self, forKey: .customRules) ?? []

        // Schema < 2: US SSN was part of the `accountNumber` built-in.
        // Keep it detecting for users who had that built-in on by
        // promoting it to the `us.ssn` preset, unless the file already
        // has an explicit opinion about that preset. `homeRegions` is
        // seeded from the Mac locale so the suggestion banner has a
        // region to offer — presets for it are NOT auto-enabled on an
        // existing install (the UI offers "Enable all" instead).
        if schemaVersion < 2 {
            if builtin[.accountNumber] != false, presets[PrivacyRulePresets.usSSN.id] == nil {
                presets[PrivacyRulePresets.usSSN.id] = true
            }
            if regions.isEmpty, let region = Self.regionCode(from: .current) {
                regions = [region]
            }
        }
        self.presetRules = presets
        self.homeRegions = regions
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Always emit the CURRENT schema, even if `schemaVersion`
        // on this in-memory value still reads the older number a
        // future migration left there — the on-disk file should
        // reflect the shape we're actually writing.
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(aiDetectionEnabled, forKey: .aiDetectionEnabled)
        try c.encode(aiDetectionBackend, forKey: .aiDetectionBackend)
        try c.encode(providerOverrides, forKey: .providerOverrides)
        try c.encode(skipCodeBlocks, forKey: .skipCodeBlocks)
        try c.encode(alwaysApproveByDefault, forKey: .alwaysApproveByDefault)
        try c.encode(requireReviewForNonInteractive, forKey: .requireReviewForNonInteractive)
        // Encode as raw-string-keyed dict so the on-disk JSON is
        // `{"phone": true, …}` rather than the default
        // alternating-array form.
        var rawBuiltin: [String: Bool] = [:]
        for (category, value) in builtinPatternEnabled {
            rawBuiltin[category.rawValue] = value
        }
        try c.encode(rawBuiltin, forKey: .builtinPatternEnabled)
        try c.encode(presetRules, forKey: .presetRules)
        try c.encode(homeRegions, forKey: .homeRegions)
        try c.encode(customRules, forKey: .customRules)
    }

    // MARK: - Per-provider lookup

    /// Whether the filter should run for a given cloud provider id.
    /// `nil` provider id (legacy callers) falls back to enabled.
    public func isEnabled(forProviderId providerId: UUID?) -> Bool {
        guard enabled else { return false }
        guard let providerId else { return true }
        return providerOverrides[providerId.uuidString] ?? true
    }

    public mutating func setProviderEnabled(_ providerId: UUID, enabled: Bool) {
        providerOverrides[providerId.uuidString] = enabled
    }
}

/// Posted on every successful `PrivacyFilterStore.save(_:)`. UI
/// observers refresh from disk to pick up the new policy.
public extension Foundation.Notification.Name {
    static let privacyFilterConfigurationChanged = Foundation.Notification.Name(
        "PrivacyFilterConfigurationChanged"
    )
    /// Posted after `PrivacyFilterPipeline.applyOutbound` resolves
    /// `.approved` with at least one approved entity. The chat view
    /// folds the `redactions` pairs into a window-local accumulator
    /// (`ChatView.sessionRedactions`) so user and assistant bubbles
    /// can inline-highlight matching spans on rebuild. userInfo:
    ///   - `sessionId` (`String`): matches `parameters.sessionId`
    ///   - `approvedCount` (`Int`): number of approved redactions
    ///   - `redactions` (`[[String: String]]`): one entry per
    ///     approved entity with keys `"original"` (the verbatim
    ///     substring the user typed) and `"placeholder"` (the token
    ///     it was rewritten to, e.g. `[PHONE_1]`).
    static let privacyFilterRedactionsApproved = Foundation.Notification.Name(
        "PrivacyFilterRedactionsApproved"
    )
}
