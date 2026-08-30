//
//  RedactionToolSupport.swift
//  osaurus
//
//  Shared machinery for the `detect_pii` / `redact_file` folder tools:
//  ad-hoc rule parsing, PII backend resolution, the once-per-session
//  download prompt gate, and the detection runner both tools call.
//
//  Design constraints (see plan):
//  - Ad-hoc `custom_rules` are per-call and EPHEMERAL. They are never
//    written into `PrivacyFilterConfiguration.customRules` — that store
//    drives the user's cloud-outbound scrubbing and agent tool calls
//    must not mutate it.
//  - Uses engine primitives (`PrivacyFilterEngine.detect`) directly,
//    NOT `PrivacyFilterPipeline.applyOutbound`: the outbound pipeline's
//    scrub/unscrub round-trip and session redaction stores are wrong
//    for permanent file redaction.
//  - Degradation lives in the tool RESULT, never the tool list: both
//    tools register unconditionally so the KV prefix hash (which covers
//    canonical tool payloads) stays stable across sessions.
//

import Foundation

// MARK: - Ad-hoc rule parsing

enum RedactionToolSupport {

    /// Cap on agent-supplied `custom_rules` per call.
    static let maxCustomRules = 32

    /// One agent-supplied rule that failed validation; surfaced per-rule
    /// in the tool result so a single bad regex doesn't fail the call.
    struct RejectedRule {
        let name: String
        let reason: String
    }

    struct ParsedRules {
        let rules: [PrivacyRule]
        let rejected: [RejectedRule]
    }

    /// Parse the `custom_rules` argument into ephemeral `PrivacyRule`
    /// values. Each entry: `{name, pattern, placeholder?, category?,
    /// case_sensitive?}`. Invalid patterns are rejected per-rule (compile
    /// check via `RegexEntityDetector.safeCompile` happens later at
    /// compile time; here we validate shape and emptiness).
    static func parseCustomRules(_ value: Any?) -> ParsedRules? {
        guard let value else { return ParsedRules(rules: [], rejected: []) }
        guard let raw = value as? [[String: Any]] else { return nil }
        var rules: [PrivacyRule] = []
        var rejected: [RejectedRule] = []
        for (index, entry) in raw.enumerated() {
            let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "rule_\(index)"
            guard rules.count < maxCustomRules else {
                rejected.append(
                    RejectedRule(name: name, reason: "over the \(maxCustomRules)-rule cap"))
                continue
            }
            guard let pattern = entry["pattern"] as? String, !pattern.isEmpty else {
                rejected.append(RejectedRule(name: name, reason: "missing or empty `pattern`"))
                continue
            }
            let category =
                (entry["category"] as? String).flatMap(EntityCategory.init(rawValue:)) ?? .secret
            let rule = PrivacyRule(
                name: name,
                pattern: pattern,
                category: category,
                enabled: true,
                kind: .regex,
                caseSensitive: (entry["case_sensitive"] as? Bool) ?? true,
                placeholderLabel: entry["placeholder"] as? String
            )
            // Compile check now so the failure is attributable to THIS
            // rule instead of silently dropping matches at detect time.
            switch RegexEntityDetector.safeCompile(pattern, caseSensitive: rule.caseSensitive) {
            case .success:
                rules.append(rule)
            case .failure(let error):
                rejected.append(RejectedRule(name: name, reason: "invalid regex: \(error)"))
            }
        }
        return ParsedRules(rules: rules, rejected: rejected)
    }

    /// Ephemeral ruleset: all built-ins + the parsed ad-hoc rules.
    /// Constructed via a throwaway configuration value; the persisted
    /// store is never read or written.
    static func ruleset(customRules: [PrivacyRule]) -> RegexEntityDetector.EffectiveRuleSet {
        .build(from: PrivacyFilterConfiguration(customRules: customRules))
    }

    // MARK: - Backend resolution

    enum ResolvedBackend {
        case rampart
        case openai
        /// Neither PII model installed (or the user declined the
        /// download): deterministic regex layer only. `note` is the
        /// degradation message the tool result must carry.
        case regexOnly(note: String)
    }

    /// Pick the strongest available detection backend. Rampart (~37MB)
    /// wins over the multi-GB OpenAI bundle when both are installed
    /// since span quality is comparable for the redaction categories.
    /// Async because `PrivacyFilterEngine` is main-actor-isolated; the
    /// `isLoaded` peek is the only state read.
    static func resolveBackend() async -> ResolvedBackend {
        if RampartModelManager.bundleExists() {
            return .rampart
        }
        if await MainActor.run(body: { PrivacyFilterEngine.shared.isLoaded }) {
            return .openai
        }
        return .regexOnly(
            note:
                "Name/address detection unavailable: no PII model installed. "
                + "Emails, phones, and pattern-based categories were still detected via regex. "
                + "Compensate for undetected names with `file_edit` if needed."
        )
    }

    // MARK: - Detection runner

    struct DetectionOutcome {
        let entities: [DetectedEntity]
        /// "rampart" | "openai" | "regex-only"
        let backend: String
        /// Degradation note when running regex-only; nil at full strength.
        let degradation: String?
    }

    /// Run detection over `text` with the strongest available backend,
    /// falling back to regex-only (never throwing for a missing model —
    /// a stranded agent loop is worse than a degraded result).
    static func detect(
        in text: String,
        customRules: [PrivacyRule]
    ) async -> DetectionOutcome {
        let map = RedactionMap(conversationID: UUID())
        let rules = ruleset(customRules: customRules)
        let resolved = await PIIModelDownloadGate.shared.resolveBackendPromptingIfNeeded()
        switch resolved {
        case .rampart:
            if let entities = try? await PrivacyFilterEngine.shared.detect(
                in: text, map: map, skipCodeBlocks: false, ruleset: rules,
                useModel: true, backend: .rampart)
            {
                return DetectionOutcome(entities: entities, backend: "rampart", degradation: nil)
            }
        case .openai:
            if let entities = try? await PrivacyFilterEngine.shared.detect(
                in: text, map: map, skipCodeBlocks: false, ruleset: rules,
                useModel: true, backend: .openai)
            {
                return DetectionOutcome(entities: entities, backend: "openai", degradation: nil)
            }
        case .regexOnly:
            break
        }
        // Regex-only path (resolved that way, or the model pass threw).
        let note: String
        if case .regexOnly(let resolvedNote) = resolved {
            note = resolvedNote
        } else {
            note = "PII model detection failed; results are regex-only for this call."
        }
        let entities =
            (try? await PrivacyFilterEngine.shared.detect(
                in: text, map: map, skipCodeBlocks: false, ruleset: rules,
                useModel: false)) ?? []
        return DetectionOutcome(entities: entities, backend: "regex-only", degradation: note)
    }
}

// MARK: - Download prompt gate

/// Once-per-session gate for the "install the PII model?" prompt.
///
/// The default (headless channels, subagents, tests, no registered
/// presenter) is to skip the prompt and degrade to regex-only — the
/// prompt is an enhancement for interactive chat surfaces, which
/// register a presenter that shows the download modal (reusing the
/// `ToolPermissionPromptService` suspend/resume pattern), drives
/// `RampartModelManager.startDownload()`, and resolves once the bundle
/// exists or the user declines.
public actor PIIModelDownloadGate {
    public static let shared = PIIModelDownloadGate()

    /// UI seam: returns true when the model is installed and ready
    /// after the interaction, false on decline/failure. Nil = headless.
    public typealias Presenter = @Sendable () async -> Bool

    private var presenter: Presenter?
    /// True once the user has declined (or the download failed) this
    /// session: a declined download must not re-modal on every call.
    private var declinedThisSession = false

    public func registerPresenter(_ presenter: @escaping Presenter) {
        self.presenter = presenter
    }

    public func unregisterPresenter() {
        presenter = nil
    }

    /// Test/reset seam.
    public func resetSession() {
        declinedThisSession = false
    }

    func resolveBackendPromptingIfNeeded() async -> RedactionToolSupport.ResolvedBackend {
        let resolved = await RedactionToolSupport.resolveBackend()
        guard case .regexOnly = resolved else { return resolved }
        guard let presenter, !declinedThisSession else { return resolved }
        let installed = await presenter()
        if installed {
            return await RedactionToolSupport.resolveBackend()
        }
        declinedThisSession = true
        return .regexOnly(
            note:
                "Name/address detection unavailable: PII model download was declined or failed. "
                + "Emails, phones, and pattern-based categories were still detected via regex.")
    }
}
