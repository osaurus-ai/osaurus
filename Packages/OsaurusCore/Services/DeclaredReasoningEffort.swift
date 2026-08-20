//
//  DeclaredReasoningEffort.swift
//  osaurus
//
//  Bundle-declared reasoning-effort contract for local models.
//
//  Qwen3.8 introduced a `reasoning_effort` CHAT-TEMPLATE kwarg whose value set
//  is closed: the template `raise_exception`s on anything outside
//  low/medium/xhigh. Forwarding the app's generic effort ladder verbatim
//  (`high`, `max`) therefore hard-fails the prompt render. The JANG converter
//  stamps the accepted set into `jang_config.json` so serving layers can
//  constrain pickers and snap requests without hardcoding per-release lists:
//
//      "reasoning": {
//        "supported_reasoning_efforts": ["low", "medium", "xhigh"],   // ascending
//        "default_reasoning_effort":    "xhigh",
//        "reasoning_effort_transport":  "chat_template_kwarg",
//        "preserve_thinking_supported": true,
//        "preserve_thinking_default":   true,
//        "preserve_thinking_transport": "chat_template_kwarg"
//      }
//
//  The block lives at the jang_config top level on new stamps and under
//  `chat.reasoning` on earlier converter output (DSV4-Flash); both nestings
//  are accepted here so a stamper-side placement choice can never silently
//  disable the constraint.
//
//  Absence semantics are deliberate and directional: a reasoning block WITHOUT
//  `supported_reasoning_efforts` means the model has NO effort control (Qwen3.6
//  stamps stay keyless because that template ignores the kwarg entirely) — not
//  "unconstrained, send anything". Verified 2026-08-14: no other local bundle's
//  template reads `reasoning_effort`, so omitting the kwarg for keyless stamped
//  bundles is render-identical everywhere it applies.
//
//  Raw HF bundles carry no jang_config, so a template-derived fallback parses
//  the accepted set straight out of the template's own closed-set guard
//  (`… reasoning_effort … not in ('xhigh', 'medium', 'low')`) — the exact
//  construct that makes the constraint necessary in the first place.
//

import Foundation

enum DeclaredReasoningEffort {
    /// What the bundle says about the `reasoning_effort` kwarg.
    enum Control: Equatable, Sendable {
        /// Closed accepted set (bundle order, stamped ascending) plus the
        /// publisher default the template resolves when the kwarg is absent.
        case levels([String], defaultLevel: String?)
        /// The model has no effort tiers: never send the kwarg. Also the
        /// honest downgrade when a declared transport is one this app does
        /// not know how to deliver.
        case noEffortControl
    }

    /// Declared support for the `preserve_thinking` chat-template kwarg
    /// (Qwen3.8: keeps historical `<think>` blocks in the prompt; default
    /// true). Presence of this value means the kwarg may be sent.
    struct PreserveThinking: Equatable, Sendable {
        /// The template's resolved default when the kwarg is absent, when the
        /// stamp declares it. Display/policy metadata — never synthesized
        /// into a render context.
        let defaultOn: Bool?
    }

    struct Declaration: Equatable, Sendable {
        let control: Control?
        let preserveThinking: PreserveThinking?
    }

    // MARK: - Cached per-model resolution

    private static nonisolated let lock = NSLock()
    private static nonisolated(unsafe) var cache: [String: Declaration?] = [:]

    /// Test seam: when set, resolution consults this instead of disk so unit
    /// tests can exercise adapter/registry behavior without installing model
    /// bundles. Mirrors `ExternalModelLocator.testRootsOverride`'s role.
    static nonisolated(unsafe) var testDeclarationOverride: (@Sendable (String) -> Declaration?)?

    static func declaration(forModelId modelId: String) -> Declaration? {
        if let override = testDeclarationOverride {
            return override(modelId)
        }
        let key = modelId.lowercased()
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let resolved = resolve(modelId: modelId)

        // Same cold-cache rule as `LocalReasoningCapability`: a main-thread
        // lookup during the launch scan can miss purely because the
        // local-models cache is still warming. Never memoize that
        // provisional nil — the next lookup gets the real answer.
        if resolved == nil, !ModelManager.isLocalModelsCacheWarm {
            return nil
        }

        lock.lock()
        cache[key] = resolved
        lock.unlock()
        return resolved
    }

    static func control(forModelId modelId: String) -> Control? {
        declaration(forModelId: modelId)?.control
    }

    static func preserveThinking(forModelId modelId: String) -> PreserveThinking? {
        declaration(forModelId: modelId)?.preserveThinking
    }

    /// Call when models are added/removed so the next lookup re-reads stamps.
    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func resolve(modelId: String) -> Declaration? {
        guard let dir = LocalReasoningCapability.localDirectory(forModelId: modelId) else {
            return nil
        }
        if let data = LocalReasoningCapability.readSmallConfigFile(
            dir.appendingPathComponent("jang_config.json")),
            let declared = parseJangDeclaration(data: data)
        {
            return declared
        }
        if let template = LocalReasoningCapability.readChatTemplate(at: dir) {
            return templateDerivedDeclaration(template: template)
        }
        return nil
    }

    // MARK: - jang_config parse (pure, testable)

    /// Nil when the config carries no reasoning block at all (then the
    /// template fallback gets its turn). A present block always yields a
    /// declaration — see the absence semantics in the header.
    static func parseJangDeclaration(data: Data) -> Declaration? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let reasoning =
            (root["reasoning"] as? [String: Any])
            ?? ((root["chat"] as? [String: Any])?["reasoning"] as? [String: Any])
        guard let reasoning else { return nil }
        return Declaration(
            control: parseControl(reasoning),
            preserveThinking: parsePreserveThinking(reasoning)
        )
    }

    /// A declared transport we don't recognize means we cannot deliver the
    /// value — treat the control as absent rather than sending a kwarg the
    /// bundle says travels some other way. An absent transport key keeps the
    /// kwarg convention (the only transport local render supports).
    private static func transportIsChatTemplateKwarg(
        _ reasoning: [String: Any], key: String
    ) -> Bool {
        guard let raw = reasoning[key] as? String else { return true }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == "chat_template_kwarg"
    }

    private static func parseControl(_ reasoning: [String: Any]) -> Control? {
        guard let raw = reasoning["supported_reasoning_efforts"] as? [String] else {
            return .noEffortControl
        }
        let levels = raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !levels.isEmpty,
            transportIsChatTemplateKwarg(reasoning, key: "reasoning_effort_transport")
        else {
            return .noEffortControl
        }
        let defaultLevel = (reasoning["default_reasoning_effort"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return .levels(levels, defaultLevel: defaultLevel)
    }

    private static func parsePreserveThinking(_ reasoning: [String: Any]) -> PreserveThinking? {
        guard reasoning["preserve_thinking_supported"] as? Bool == true,
            transportIsChatTemplateKwarg(reasoning, key: "preserve_thinking_transport")
        else {
            return nil
        }
        return PreserveThinking(defaultOn: reasoning["preserve_thinking_default"] as? Bool)
    }

    // MARK: - Template-derived fallback (pure, testable)

    /// Parse the accepted effort set out of a template's own closed-set
    /// guard. Qwen3.8's shape:
    ///
    ///     {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
    ///     {%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
    ///         {{- raise_exception('Unexpected reasoning effort …') }}
    ///
    /// Levels are returned in ascending ladder order (the tuple order in the
    /// raise guard is presentation-arbitrary). Nil when the template never
    /// reads `reasoning_effort` or has no closed-set guard — legacy verbatim
    /// forwarding stays in effect for those.
    static func templateDerivedDeclaration(template: String) -> Declaration? {
        guard template.contains("reasoning_effort") else { return nil }
        let ns = template as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard
            let setRegex = try? NSRegularExpression(
                pattern: #"reasoning_effort[^\n]{0,160}?not\s+in\s*\(([^)]*)\)"#),
            let match = setRegex.firstMatch(in: template, range: full),
            match.numberOfRanges > 1
        else { return nil }
        let tuple = ns.substring(with: match.range(at: 1))
        let tupleNS = tuple as NSString
        guard let quoted = try? NSRegularExpression(pattern: #"['"]([^'"]+)['"]"#) else {
            return nil
        }
        var levels = quoted.matches(
            in: tuple, range: NSRange(location: 0, length: tupleNS.length)
        ).map { tupleNS.substring(with: $0.range(at: 1)).lowercased() }
        guard !levels.isEmpty else { return nil }
        levels.sort { (ladderRank($0) ?? Int.max) < (ladderRank($1) ?? Int.max) }

        var defaultLevel: String? = nil
        if let defaultRegex = try? NSRegularExpression(
            pattern: #"reasoning_effort\s*\|\s*default\(\s*['"]([A-Za-z_]+)['"]"#),
            let dm = defaultRegex.firstMatch(in: template, range: full),
            dm.numberOfRanges > 1
        {
            defaultLevel = ns.substring(with: dm.range(at: 1)).lowercased()
        }
        return Declaration(
            control: .levels(levels, defaultLevel: defaultLevel),
            preserveThinking: template.contains("preserve_thinking")
                ? PreserveThinking(defaultOn: nil) : nil
        )
    }

    // MARK: - Snapping

    /// Canonical ascending effort ladder across every convention the app
    /// meets (OpenAI o-series/GPT-5.x, Codex `ultra`, local families).
    private static let ladder = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    private static func ladderRank(_ level: String) -> Int? {
        ladder.firstIndex(of: level)
    }

    /// Snap a requested effort onto a declared level set: exact matches pass
    /// through; known ladder values move to the nearest declared level with
    /// ties resolved UPWARD (a user who asked for `high` on a
    /// low/medium/xhigh model wanted more than medium). Unknown strings
    /// return nil — the caller forwards them verbatim so the template's own
    /// `raise_exception` (which names the valid set) surfaces instead of a
    /// silent coerce, matching the DSV4 policy of never rewriting an
    /// explicit invalid choice into a different valid one.
    static func snapped(
        _ requested: String, ontoLevels levels: [String], defaultLevel: String?
    ) -> String? {
        var canonical = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if canonical == "highest" { canonical = "xhigh" }
        if levels.contains(canonical) { return canonical }
        guard let want = ladderRank(canonical) else { return nil }
        let ranked = levels.compactMap { level in
            ladderRank(level).map { (level: level, rank: $0) }
        }
        guard
            let best = ranked.min(by: { a, b in
                let da = abs(a.rank - want)
                let db = abs(b.rank - want)
                return da != db ? da < db : a.rank > b.rank
            })
        else {
            return defaultLevel
        }
        return best.level
    }

    // MARK: - UI bridge

    /// Bundle-declared levels as the same capability shape the remote
    /// catalogs use, so the picker/segment/normalization pipeline needs no
    /// second code path. An Off segment (`none`, a direct-rail id the
    /// dispatch layer already maps to `enable_thinking=false`) is prepended
    /// because these templates also support disabling thinking entirely.
    static func capabilities(forModelId modelId: String) -> ModelReasoningCapabilities? {
        guard case .levels(let levels, let defaultLevel)? = control(forModelId: modelId) else {
            return nil
        }
        var ids = levels
        if !ids.contains("none") { ids.insert("none", at: 0) }
        return ModelReasoningCapabilities(
            levels: ids.map { ModelReasoningCapabilities.Level(id: $0) },
            defaultLevelId: defaultLevel
        )
    }
}
