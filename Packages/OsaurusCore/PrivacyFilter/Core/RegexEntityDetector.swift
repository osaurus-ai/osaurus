//
//  RegexEntityDetector.swift
//  osaurus / PrivacyFilter
//
//  High-confidence pattern detectors that run alongside the on-device
//  classifier. Exist to catch the well-formed PII the model
//  empirically misses — chiefly bare 10-digit phone numbers without
//  separators, emails in lowercase context, and URLs / credit cards
//  (national IDs such as US SSN live in `PrivacyRulePresets`).
//  Recall is the priority here, not precision: false positives
//  show up in the review sheet and the user can untick them; false
//  negatives leak PII to the upstream provider, which is the whole
//  failure mode this feature exists to prevent.
//
//  Detection is character-range based so results plug into the same
//  `DetectedEntity` shape as the model output. Merging is done in
//  `PrivacyFilterEngine.detect` after the model pass.
//
//  The detector now runs against an `EffectiveRuleSet` snapshot, not
//  a hard-coded catalog: built-in patterns are gated by the user's
//  per-category toggle, opt-in presets show up when enabled, and
//  user-defined custom rules slot in alongside. The set is computed
//  once per pipeline call (see `PrivacyFilterEngine.detect`).
//

import Foundation

/// Stateless regex catalog. Built-in patterns are compiled once and
/// reused; preset + custom rules are lazy-compiled and cached in a
/// process-global cache keyed by `(ruleId, patternSource)` so editing
/// a custom rule invalidates only that entry.
enum RegexEntityDetector {
    /// Discovered PII match before placeholder interning.
    struct Match {
        let category: EntityCategory
        let original: String
        let range: Range<String.Index>
        /// Custom placeholder label (sanitized uppercase letters) from
        /// a custom rule, or `nil` to use the category default prefix.
        let label: String?
        /// `true` when the hit came from a checksum-verified preset
        /// (`PrivacyRulePresets.Tier.validated`). Used only by
        /// `resolveOverlaps` so a Tier-1 match outranks a same-span
        /// anchored / generic one.
        let validated: Bool

        init(
            category: EntityCategory,
            original: String,
            range: Range<String.Index>,
            label: String? = nil,
            validated: Bool = false
        ) {
            self.category = category
            self.original = original
            self.range = range
            self.label = label
            self.validated = validated
        }
    }

    /// Bundle of compiled regex rules to run on a single text. Built
    /// once per pipeline invocation from a `PrivacyFilterConfiguration`
    /// snapshot via `EffectiveRuleSet.build(from:)`.
    struct EffectiveRuleSet {
        /// Built-in `Pattern` entries filtered by
        /// `builtinPatternEnabled` from the config.
        let builtins: [Pattern]
        /// Compiled rules from `PrivacyRulePresets` whose ids are
        /// enabled in `presetRules`. Empty when none enabled.
        let presets: [CompiledRule]
        /// Compiled user-defined rules whose `enabled` flag is true
        /// and whose pattern compiled cleanly through `safeCompile`.
        /// Unparseable patterns are dropped silently — the editor
        /// validates before save, so a bad pattern here means the
        /// pattern was edited in place on disk or the editor's
        /// safeCompile changed shape between releases.
        let customs: [CompiledRule]

        var isEmpty: Bool { builtins.isEmpty && presets.isEmpty && customs.isEmpty }
    }

    /// Compiled preset or custom rule. Identity not needed at match
    /// time — `category` is what callers consume. Sample/name aren't
    /// stored because hits go through the same `Match → DetectedEntity`
    /// path as built-ins and surface via `EntityCategory.displayName`.
    struct CompiledRule: @unchecked Sendable {
        let category: EntityCategory
        let regex: NSRegularExpression
        /// Custom placeholder label from a custom rule, `nil` for
        /// built-ins / presets (which always use the category prefix).
        let label: String?
        /// Semantic post-filter run on the redactable token (the
        /// checksum validator of a preset). `nil` for custom rules —
        /// users get exactly what they wrote — and for presets that
        /// rely on their regex alone.
        let accepts: (@Sendable (String) -> Bool)?
        /// `true` for `PrivacyRulePresets.Tier.validated` presets.
        let validated: Bool
        /// Keyword-anchored presets put the redactable value in capture
        /// group 1 so the keyword itself stays visible to the model.
        /// Custom rules are substituted whole.
        let redactsCaptureGroup: Bool

        init(
            category: EntityCategory,
            regex: NSRegularExpression,
            label: String?,
            accepts: (@Sendable (String) -> Bool)? = nil,
            validated: Bool = false,
            redactsCaptureGroup: Bool = false
        ) {
            self.category = category
            self.regex = regex
            self.label = label
            self.accepts = accepts
            self.validated = validated
            self.redactsCaptureGroup = redactsCaptureGroup
        }
    }

    /// Run every active pattern over `text` and return non-overlapping
    /// matches, prefering longer / more-specific spans on overlap.
    /// Always returns `[]` for an empty rule set so callers can use
    /// this for the post-scrub invariant without conditionals.
    static func detect(in text: String, ruleset: EffectiveRuleSet) -> [Match] {
        guard !ruleset.isEmpty, !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var raw: [Match] = []

        for pattern in ruleset.builtins {
            pattern.regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
                guard let result, result.numberOfRanges > 0 else { return }
                let nsr = result.range
                guard nsr.location != NSNotFound, nsr.length > 0 else { return }
                guard let stringRange = Range(nsr, in: text) else { return }
                let captured = String(text[stringRange])
                // Apply category-specific post-filters that the regex
                // alone can't express (Luhn for cards, digit-count
                // check for phones, etc.).
                guard pattern.accepts(captured) else { return }
                raw.append(
                    Match(
                        category: pattern.category,
                        original: captured,
                        range: stringRange
                    )
                )
            }
        }

        // Presets carry an optional checksum validator (`accepts`) and
        // may redact only capture group 1 (keyword-anchored forms).
        // Custom rules get neither: users get exactly what they wrote.
        let extra = ruleset.presets + ruleset.customs
        for rule in extra {
            rule.regex.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
                guard let result, result.numberOfRanges > 0 else { return }
                var nsr = result.range
                if rule.redactsCaptureGroup, result.numberOfRanges > 1 {
                    let group = result.range(at: 1)
                    if group.location != NSNotFound, group.length > 0 {
                        nsr = group
                    }
                }
                guard nsr.location != NSNotFound, nsr.length > 0 else { return }
                guard let stringRange = Range(nsr, in: text) else { return }
                let captured = String(text[stringRange])
                if let accepts = rule.accepts, !accepts(captured) { return }
                raw.append(
                    Match(
                        category: rule.category,
                        original: captured,
                        range: stringRange,
                        label: rule.label,
                        validated: rule.validated
                    )
                )
            }
        }

        return resolveOverlaps(raw)
    }

    /// Convenience for callers that want every built-in active and no
    /// presets/customs (tests and the rare codepath that doesn't
    /// thread a config snapshot through).
    static func detect(in text: String) -> [Match] {
        detect(in: text, ruleset: EffectiveRuleSet.allBuiltins())
    }

    /// Sort matches start-ascending and drop later spans that overlap
    /// an already-kept one. Ties broken by preferring the longer span,
    /// then a checksum-validated preset hit over an unvalidated one
    /// (so a generic Tier-3 pattern never shadows a verified national
    /// ID on the same span), then the more-specific category (credit
    /// card > phone, since they can share digit patterns). Keeps the
    /// pass linear after sort.
    private static func resolveOverlaps(_ matches: [Match]) -> [Match] {
        let priority: [EntityCategory: Int] = [
            .email: 5,
            .url: 4,
            .accountNumber: 3,  // national IDs / credit card
            .phone: 2,
            .address: 1,
            .person: 1,
            .date: 1,
            .secret: 1,
        ]
        /// `true` when `a` should win a same-start tie against `b`.
        func outranks(_ a: Match, _ b: Match) -> Bool {
            let aLen = a.original.count
            let bLen = b.original.count
            if aLen != bLen { return aLen > bLen }
            if a.validated != b.validated { return a.validated }
            return (priority[a.category] ?? 0) > (priority[b.category] ?? 0)
        }
        let sorted = matches.sorted { a, b in
            if a.range.lowerBound != b.range.lowerBound {
                return a.range.lowerBound < b.range.lowerBound
            }
            return outranks(a, b)
        }
        var kept: [Match] = []
        for match in sorted {
            if let last = kept.last, last.range.overlaps(match.range) {
                if outranks(match, last) {
                    kept.removeLast()
                    kept.append(match)
                }
                continue
            }
            kept.append(match)
        }
        return kept
    }
}

// MARK: - EffectiveRuleSet builder

extension RegexEntityDetector.EffectiveRuleSet {
    /// Build a rule set from a config snapshot. Filters built-ins by
    /// `builtinPatternEnabled`, compiles enabled presets, and compiles
    /// enabled custom rules. Unparseable / unsafe patterns are
    /// silently dropped — see `RegexEntityDetector.safeCompile`.
    static func build(from config: PrivacyFilterConfiguration) -> Self {
        let builtins = RegexEntityDetector.Pattern.all.filter { pattern in
            config.isBuiltinPatternEnabled(pattern.category)
        }

        var presets: [RegexEntityDetector.CompiledRule] = []
        for preset in PrivacyRulePresets.all where config.isPresetEnabled(preset.id) {
            if let compiled = RegexEntityDetector.compiledPreset(preset) {
                presets.append(compiled)
            }
        }

        var customs: [RegexEntityDetector.CompiledRule] = []
        for rule in config.customRules where rule.enabled {
            if let compiled = RegexEntityDetector.compiledCustom(rule) {
                customs.append(compiled)
            }
        }

        return Self(builtins: builtins, presets: presets, customs: customs)
    }

    /// All built-ins, no presets/customs. Used by the legacy
    /// `detect(in:)` overload and by tests that want default behavior.
    static func allBuiltins() -> Self {
        Self(
            builtins: RegexEntityDetector.Pattern.all,
            presets: [],
            customs: []
        )
    }

    /// Built-ins plus the presets a fresh install would enable for
    /// `locale` (`PrivacyFilterConfiguration.freshInstall`). This is
    /// the floor for codepaths that scrub without a user config —
    /// screenshot frames and tool output — so moving US SSN out of the
    /// built-ins did not silently drop it there.
    static func defaultSafetyNet(locale: Locale = .current) -> Self {
        build(from: .freshInstall(locale: locale))
    }
}

// MARK: - Pattern catalog (built-ins)

extension RegexEntityDetector {
    /// One regex + category + optional post-filter. Lazy-compiled
    /// because some patterns are non-trivial and we only need to pay
    /// the cost on first detection. `Sendable` so the static `all`
    /// catalog can be referenced from any actor.
    struct Pattern: @unchecked Sendable {
        let category: EntityCategory
        let regex: NSRegularExpression
        /// Returns `true` if the captured string passes the
        /// pattern's semantic check (e.g. Luhn for credit cards).
        let accepts: @Sendable (String) -> Bool

        static let all: [Pattern] = [
            // Email — RFC-flavored, deliberately liberal in the local
            // part since real-world addresses are messy.
            Pattern(
                category: .email,
                regex: compileBuiltin(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
                accepts: { _ in true }
            ),
            // URL with explicit scheme. Stops at whitespace and the
            // common right-side closing punctuation so trailing
            // commas / periods / parentheses don't get sucked in.
            Pattern(
                category: .url,
                regex: compileBuiltin(#"\bhttps?://[^\s<>\"\)\],]+"#),
                accepts: { _ in true }
            ),
            // Credit card — 13-19 digit runs, optionally space/dash
            // separated. Filtered by Luhn so we don't flag random
            // numeric IDs as cards. National ID numbers (US SSN
            // included) live in `PrivacyRulePresets`, not here.
            Pattern(
                category: .accountNumber,
                regex: compileBuiltin(#"\b(?:\d[\s\-]?){12,18}\d\b"#),
                accepts: { captured in
                    let digitCount = PrivacyChecksums.digits(captured).count
                    guard (13 ... 19).contains(digitCount) else { return false }
                    return PrivacyChecksums.luhn(captured)
                }
            ),
            // Phone (NANP) — anchored to (3-digit area) (3-digit
            // prefix) (4-digit line) with optional country code and
            // optional separators. Covers:
            //   +1 (123) 456-7890
            //   +1-123-456-7890
            //   123-456-7890
            //   123.456.7890
            //   (123) 456-7890
            //   123 456 7890
            //   +11234567890
            //   1234567890   ← the bare-digit case the model misses
            Pattern(
                category: .phone,
                regex: compileBuiltin(
                    #"(?:\+?\d{1,3}[\-.\s]?)?\(?\b\d{3}\)?[\-.\s]?\d{3}[\-.\s]?\d{4}\b"#
                ),
                accepts: { captured in
                    // 10–12 digits: rejects SSN-shaped 9-digit strings
                    // (XXX-XX-XXXX, now the `us.ssn` preset) and
                    // over-long runs that belong to the card pattern.
                    let digitCount = captured.filter { $0.isNumber }.count
                    return (10 ... 12).contains(digitCount)
                }
            ),
            // Phone (international, E.164 / `00` dial prefix) —
            //   +44 7911 123456
            //   +33 6 12 34 56 78
            //   +49 (0)30 901820
            //   0049 30 901820
            //   +91-98765-43210
            // Requires a `+` not glued to a word (so `C+1234567890`
            // doesn't fire) or a `00` international prefix, then
            // 8–15 digits total per ITU E.164.
            Pattern(
                category: .phone,
                regex: compileBuiltin(
                    #"(?:(?<!\w)\+|\b00)\d{1,3}[\s.\-]?(?:\(0\)[\s.\-]?)?(?:\d[\s.\-]?){6,13}\d\b"#
                ),
                accepts: { captured in
                    let digitCount = captured.filter { $0.isNumber }.count
                    return (8 ... 15).contains(digitCount)
                }
            ),
            // Phone (national trunk prefix) — a leading `0` followed
            // by 8–11 more digits with optional separators:
            //   07911 123456      (GB)
            //   06 12 34 56 78    (FR)
            //   030 901820        (DE)
            //   0151 23456789     (DE mobile, 12 digits)
            //   0412 345 678      (AU)
            //   03-1234-5678      (JP)
            //   081 234 5678      (ZA / NG)
            // `0.` is rejected so decimals like `0.123456789` don't
            // register as phones.
            Pattern(
                category: .phone,
                regex: compileBuiltin(#"\b0(?:[\s.\-]?\d){8,11}\b"#),
                accepts: { captured in
                    if captured.hasPrefix("0.") { return false }
                    let digitCount = captured.filter { $0.isNumber }.count
                    return (9 ... 12).contains(digitCount)
                }
            ),
        ]

        private static func compileBuiltin(_ pattern: String) -> NSRegularExpression {
            // Patterns are static, hand-written, and tested — force-try
            // is appropriate here. A bad pattern would be a programmer
            // error caught immediately on first use.
            // swiftlint:disable:next force_try
            return try! NSRegularExpression(pattern: pattern, options: [])
        }
    }

}

// MARK: - Safe compilation + cache

extension RegexEntityDetector {
    /// Hard cap on the length of a user-supplied pattern source. Long
    /// patterns are usually a typo or a pasted blob; the regex engine
    /// will happily compile them but the runtime can explode on
    /// pathological inputs. 512 chars is well above any realistic
    /// hand-written pattern.
    static let maxPatternLength = 512

    /// Reason why `safeCompile` rejected a pattern. The editor surfaces
    /// these as localized error messages next to the pattern field.
    enum CompileError: Error, Equatable, Sendable {
        case empty
        case tooLong(Int)
        case invalid(String)
        /// Pattern matched the empty string against a non-empty probe.
        /// We refuse these because they cause infinite-zero-width loops
        /// inside `enumerateMatches`.
        case matchesEmpty
    }

    /// Compile a user pattern with safety checks:
    ///  - reject empty source
    ///  - reject sources over `maxPatternLength`
    ///  - reject patterns that fail to compile
    ///  - reject patterns that match the empty string on a probe
    ///    (catastrophic-loop guard)
    /// Returns the compiled regex on success.
    static func safeCompile(
        _ source: String,
        caseSensitive: Bool = true
    ) -> Result<NSRegularExpression, CompileError> {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed.count > maxPatternLength {
            return .failure(.tooLong(trimmed.count))
        }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: trimmed, options: options)
        } catch {
            return .failure(.invalid(error.localizedDescription))
        }
        // Probe: every well-formed PII pattern should require at least
        // one character to match. If the regex fires on the empty
        // string it has a structural problem (e.g. all-optional
        // alternation) and would loop on real input.
        let probe = "a"
        let probeRange = NSRange(location: 0, length: (probe as NSString).length)
        if let match = regex.firstMatch(in: probe, options: [], range: probeRange),
            match.range.length == 0
        {
            return .failure(.matchesEmpty)
        }
        // Second probe: empty string itself. If the regex matches the
        // empty string directly we also reject.
        let emptyProbeRange = NSRange(location: 0, length: 0)
        if let match = regex.firstMatch(in: "", options: [], range: emptyProbeRange),
            match.range.length == 0
        {
            return .failure(.matchesEmpty)
        }
        return .success(regex)
    }

    /// Lock-protected cache of compiled preset + custom rules. Keyed
    /// by `(ruleId, pattern)` so editing a rule invalidates only that
    /// entry. Bounded implicitly by the user's rule count, which is
    /// small in practice.
    private static let compileCacheLock = NSLock()
    nonisolated(unsafe) private static var compileCache: [CacheKey: NSRegularExpression] = [:]

    private struct CacheKey: Hashable {
        let id: String
        let pattern: String
        let caseSensitive: Bool
    }

    /// Compile (or fetch from cache) a preset.
    fileprivate static func compiledPreset(_ preset: PrivacyRulePresets.Preset)
        -> CompiledRule?
    {
        guard let regex = cachedCompile(id: "preset:" + preset.id, pattern: preset.pattern) else {
            return nil
        }
        return CompiledRule(
            category: preset.category,
            regex: regex,
            label: nil,
            accepts: preset.validator,
            validated: preset.tier == .validated,
            redactsCaptureGroup: regex.numberOfCaptureGroups > 0
        )
    }

    /// Compile (or fetch from cache) a user-defined custom rule. The
    /// effective pattern resolves the builder when `kind == .builder`;
    /// the case-sensitivity flag flows into the compile options (and
    /// the cache key) so toggling case re-compiles.
    fileprivate static func compiledCustom(_ rule: PrivacyRule) -> CompiledRule? {
        guard let pattern = rule.effectivePattern else { return nil }
        guard
            let regex = cachedCompile(
                id: "custom:" + rule.id.uuidString,
                pattern: pattern,
                caseSensitive: rule.caseSensitive
            )
        else {
            return nil
        }
        return CompiledRule(
            category: rule.category,
            regex: regex,
            label: rule.effectivePlaceholderLabel
        )
    }

    private static func cachedCompile(
        id: String,
        pattern: String,
        caseSensitive: Bool = true
    ) -> NSRegularExpression? {
        let key = CacheKey(id: id, pattern: pattern, caseSensitive: caseSensitive)
        compileCacheLock.lock()
        let cached = compileCache[key]
        compileCacheLock.unlock()
        if let cached { return cached }

        switch safeCompile(pattern, caseSensitive: caseSensitive) {
        case .success(let regex):
            compileCacheLock.lock()
            compileCache[key] = regex
            compileCacheLock.unlock()
            return regex
        case .failure:
            return nil
        }
    }
}
