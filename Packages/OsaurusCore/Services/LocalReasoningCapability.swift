//
//  LocalReasoningCapability.swift
//  osaurus
//
//  Inspects a locally-installed model's chat template to determine whether
//  it supports thinking/reasoning — without hardcoding per-family heuristics.
//  Drives the UI reasoning toggle and metadata reporting so new reasoning
//  model families (JANG, MiniMax, Mistral-Small-4, etc.) are picked up
//  automatically as long as they ship a chat template.
//
//  JANG bundles that omit a chat template entirely — DSV4-Flash is the
//  canonical case, it ships `encoding/encoding_dsv4.py` instead of a Jinja
//  template — are detected via a `jang_config.json > chat > reasoning`
//  fallback so their `.reasoning` events don't get coerced to content by
//  the #934 mitigation in `ModelRuntime.streamWithTools`.
//

import Foundation
import Darwin

enum LocalReasoningCapability {
    struct Capability: Sendable, Equatable {
        /// Template references `<think>` or `</think>` tags.
        let supportsThinking: Bool
        /// Template reads an `enable_thinking` kwarg.
        let hasEnableThinkingKwarg: Bool
        /// Template itself injects a literal `<think>` opener into the assistant prompt
        /// tail. This is reported as metadata only; runtime code must not synthesize
        /// or prepend thinking tags to repair model output.
        let templateInjectsThinkTag: Bool
        /// The template's DEFAULT thinking state — what the model does when the
        /// caller passes NO `enable_thinking` kwarg. Drives the UI chip so it
        /// reports the truth for a fresh/untouched model instead of a hardcoded
        /// "off". Two real conventions produce opposite defaults:
        ///   • Ornith / Qwen3: the non-thinking branch is gated on an explicit
        ///     false (`enable_thinking is false`) → absent kwarg ⇒ thinking ON.
        ///   • Gemma-4: the thinking branch is gated on an explicit truthy value
        ///     (`... and enable_thinking`) → absent kwarg ⇒ thinking OFF.
        /// Only meaningful when `isToggleableThinking` is true.
        let defaultThinkingOn: Bool
        /// The serving default the PUBLISHER explicitly stamped into
        /// `generation_config.json > default_chat_template_kwargs >
        /// enable_thinking` — the same key HF transformers honors when the
        /// caller omits the kwarg. `nil` when the bundle carries no such
        /// declaration (template-inferred and jang_config defaults do NOT
        /// populate this). Distinct from `defaultThinkingOn` so policy code
        /// can tell a deliberate bundle contract (Laguna/Raptor) apart from
        /// a heuristic template read.
        let declaredDefaultThinkingOn: Bool?
        /// True when the template both exposes a toggle kwarg and uses
        /// reasoning markers the runtime recognizes.
        var isToggleableThinking: Bool { supportsThinking && hasEnableThinkingKwarg }

        init(
            supportsThinking: Bool,
            hasEnableThinkingKwarg: Bool,
            templateInjectsThinkTag: Bool,
            defaultThinkingOn: Bool,
            declaredDefaultThinkingOn: Bool? = nil
        ) {
            self.supportsThinking = supportsThinking
            self.hasEnableThinkingKwarg = hasEnableThinkingKwarg
            self.templateInjectsThinkTag = templateInjectsThinkTag
            self.defaultThinkingOn = defaultThinkingOn
            self.declaredDefaultThinkingOn = declaredDefaultThinkingOn
        }

        static let none = Capability(
            supportsThinking: false,
            hasEnableThinkingKwarg: false,
            templateInjectsThinkTag: false,
            defaultThinkingOn: false
        )
    }

    private static nonisolated let lock = NSLock()
    private static nonisolated(unsafe) var cache: [String: Capability] = [:]
    private static nonisolated(unsafe) var inFlightBackgroundDetects: Set<String> = []

    static func capability(forModelId modelId: String) -> Capability {
        let key = modelId.lowercased()
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // A cold miss detects from on-disk config files (chat template,
        // generation config) — an open(2) that stalls for seconds under disk
        // pressure. The main thread reaches this from view-body recomputes
        // (the model chip's reasoning suffix), so it never pays that read:
        // detect on a background queue, memoize, and post
        // `.localModelsChanged` so observing UI recomputes with the real
        // answer. `.none` in the interim only softens presentation; dispatch
        // paths (ChatEngine, the batch adapter) run off-main and keep the
        // synchronous, authoritative resolution.
        if Thread.isMainThread {
            scheduleBackgroundDetect(key: key, modelId: modelId)
            return .none
        }

        let detected = detect(modelId: modelId)

        // A main-thread lookup during the launch scan can miss purely
        // because the local-models cache is still cold (see
        // `localDirectory(forModelId:)`). Don't memoize that provisional
        // miss — the next lookup after the scan lands gets the real answer.
        if detected == .none, !ModelManager.isLocalModelsCacheWarm {
            return detected
        }

        lock.lock()
        cache[key] = detected
        lock.unlock()
        return detected
    }

    /// Authoritative dispatch-time resolution that never performs model
    /// discovery or bundle I/O on the main thread. UI lookups deliberately
    /// return a provisional `.none` on a cold cache; a request carrying an
    /// already-persisted explicit Thinking choice must wait for the real
    /// answer before freezing its per-turn controls.
    static func resolveForDispatch(modelId: String) async -> Capability {
        await ModelManager.awaitLocalModelsCacheReadyForDispatch()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: capability(forModelId: modelId))
            }
        }
    }

    /// Resolve a main-thread cold miss off-main. Deduped per key so a burst
    /// of body recomputes triggers one disk read, not one per frame. The
    /// provisional-miss rule from `capability(forModelId:)` applies here too:
    /// a `.none` computed before the local-models scan finishes is not
    /// memoized (and not announced), so the next lookup retries.
    private static func scheduleBackgroundDetect(key: String, modelId: String) {
        lock.lock()
        let alreadyRunning = !inFlightBackgroundDetects.insert(key).inserted
        lock.unlock()
        if alreadyRunning { return }

        DispatchQueue.global(qos: .utility).async {
            let detected = detect(modelId: modelId)
            let provisionalMiss = detected == .none && !ModelManager.isLocalModelsCacheWarm
            lock.lock()
            if !provisionalMiss {
                cache[key] = detected
            }
            inFlightBackgroundDetects.remove(key)
            lock.unlock()
            // Only a real capability changes what the UI showed for the
            // interim `.none`; skip the notification churn otherwise.
            if !provisionalMiss, detected != .none {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .localModelsChanged, object: nil)
                }
            }
        }
    }

    /// Call when models are added/removed so the next lookup re-reads templates.
    /// Also drops the declared effort-contract cache — both read the same
    /// bundles and every current call site wants them refreshed together.
    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
        DeclaredReasoningEffort.invalidate()
    }

    // MARK: - Detection

    private static func detect(modelId: String) -> Capability {
        guard let dir = localDirectory(forModelId: modelId) else {
            return .none
        }
        return detect(at: dir)
    }

    /// Directory-based detection for callers that already hold the resolved
    /// bundle directory (e.g. `ModelInfo.load(from:)` serving /api/show, where
    /// the id→directory resolution above would re-run discovery and, for
    /// external bundles, depend on ModelManager cache warmth). Reads disk;
    /// keep off the main thread.
    static func detect(at dir: URL) -> Capability {
        let declaredCapability = readDeclaredReasoningCapability(at: dir)
        if let template = readChatTemplate(at: dir) {
            let analyzed = merge(
                templateCapability: analyze(template: template),
                declaredCapability: declaredCapability
            )
            let declared = generationConfigDeclaredThinkingOn(at: dir)
            if let metadataDefault = declared ?? readTemplateDefaultThinkingOn(at: dir) {
                return Capability(
                    supportsThinking: analyzed.supportsThinking,
                    hasEnableThinkingKwarg: analyzed.hasEnableThinkingKwarg,
                    templateInjectsThinkTag: analyzed.templateInjectsThinkTag,
                    defaultThinkingOn: metadataDefault,
                    declaredDefaultThinkingOn: declared
                )
            }
            return analyzed
        }
        // Fallback for JANG bundles that ship no chat template (DSV4-Flash
        // ships `encoding/encoding_dsv4.py` instead; the JANG converter
        // stamps `has_tokenizer_chat_template: false` plus an authoritative
        // `chat.reasoning.supported` flag into `jang_config.json`). Without
        // this fallback, `detect()` returned `.none` for DSV4 → `supportsThinking
        // = false` → PR #934's `streamWithTools` coercion merged the model's
        // `.reasoning` deltas into content, wiping out the thinking split.
        if let cap = readJangConfigReasoning(at: dir) {
            return cap
        }
        // Some native families expose a structured reasoning parser and a
        // non-boolean control (Muse Glimmer's `reasoning_strength` is the
        // concrete example). Their bundle contract is authoritative even
        // though the template contains neither `<think>` nor
        // `enable_thinking`. Do not invent a toggle or a default here: only
        // surface the channel the publisher declared.
        if let declaredCapability {
            return declaredCapability
        }
        return .none
    }

    /// Merge template mechanics with an explicit bundle declaration. The
    /// template remains the sole owner of boolean-toggle semantics; metadata
    /// can add the existence of a structured reasoning channel, but cannot
    /// manufacture `enable_thinking`, tag injection, or a serving default.
    static func merge(
        templateCapability: Capability,
        declaredCapability: Capability?
    ) -> Capability {
        guard let declaredCapability else { return templateCapability }
        return Capability(
            supportsThinking: templateCapability.supportsThinking
                || declaredCapability.supportsThinking,
            hasEnableThinkingKwarg: templateCapability.hasEnableThinkingKwarg,
            templateInjectsThinkTag: templateCapability.templateInjectsThinkTag,
            defaultThinkingOn: templateCapability.defaultThinkingOn,
            declaredDefaultThinkingOn: templateCapability.declaredDefaultThinkingOn
        )
    }

    /// Pure, testable template analysis.
    static func analyze(template: String) -> Capability {
        let lower = template.lowercased()
        // Detect two distinct thinking-template conventions:
        //
        // 1. `<think>` / `</think>` — envelope tag pair used by Qwen 3,
        //    Qwen 3.5, DeepSeek-R1, GLM-4.x, MiniMax, Nemotron, etc.
        //    Reasoning content is wrapped BETWEEN the tags; vmlx's
        //    `think_xml` parser peels them off into `.reasoning` events.
        //
        // 2. `<|think|>` — a MODE MARKER (not an envelope) used only by
        //    Gemma-4. Its presence in the template's `enable_thinking`
        //    branch signals "thinking mode is active" — the model then
        //    emits actual CoT content wrapped in
        //    `<|channel>thought\n…<channel|>` envelopes, which vmlx's
        //    `harmony` parser catches. `<|think|>` has no closing pipe
        //    form; checking for it here is purely a capability flag
        //    ("this template supports thinking") to drive the UI toggle
        //    and `AutoThinkingProfile` matching, NOT a parser hint.
        //
        // Before this case existed, `supportsThinking` was `false` for
        // Gemma-4 because `<think>` never matched and
        // `hasEnableThinkingKwarg: true` alone didn't flip the flag.
        let hasOpen = lower.contains("<think>") || lower.contains("<|think|>")
        let hasClose = lower.contains("</think>")
        let hasKwarg = lower.contains("enable_thinking")
        let injects =
            template.range(
                of: #"\{\{-?\s*['\"]<\|?think\|?>"#,
                options: .regularExpression
            ) != nil
        return Capability(
            supportsThinking: hasOpen || hasClose,
            hasEnableThinkingKwarg: hasKwarg,
            templateInjectsThinkTag: injects,
            defaultThinkingOn: detectDefaultThinkingOn(lower)
        )
    }

    /// Resolve the template's default thinking state (thinking when the
    /// `enable_thinking` kwarg is absent). Pure and testable. See
    /// `Capability.defaultThinkingOn` for the two conventions this recognizes.
    static func detectDefaultThinkingOn(_ lower: String) -> Bool {
        // An explicit Jinja `default(...)` filter is authoritative.
        if lower.range(
            of: #"enable_thinking\s*\|\s*default\(\s*true\s*\)"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if lower.range(
            of: #"enable_thinking\s*\|\s*default\(\s*false\s*\)"#,
            options: .regularExpression
        ) != nil {
            return false
        }
        // Ternary default idiom (Nemotron-H):
        //   `enable_thinking = enable_thinking if enable_thinking is defined else True`
        // The `else <bool>` clause IS the default when the kwarg is absent.
        if let match = lower.range(
            of: #"enable_thinking\s+is\s+defined\s+else\s+(true|false)"#,
            options: .regularExpression
        ) {
            return lower[match].contains("true")
        }
        // Normalisation block (Bailing V3 / Raptor / Ling 3): the template
        // branches on `enable_thinking is defined` and the SAME-DEPTH
        // `else` / `elif` branch is what runs when the kwarg is absent, e.g.
        //
        //     {%- if enable_thinking is defined %}
        //       {%- if enable_thinking %}{%- set thinking_option = 'on' %}
        //       {%- else %}{%- set thinking_option = 'off' %}{%- endif %}
        //     {%- elif thinking_option is not defined %}
        //       {%- set thinking_option = 'on' %}
        //     {%- endif %}
        //
        // Neither the `default(...)` filter nor the negative-gate idioms
        // below match this shape, so it used to fall through to "OFF" and
        // the Thinking chip lied for a default-on bundle. Read the fallback
        // branch and classify what it sets.
        if let fallback = undefinedKwargFallbackBranch(lower),
            let verdict = fallbackBranchTurnsThinkingOn(fallback)
        {
            return verdict
        }
        // Negative gate: the OFF path requires `enable_thinking` to be explicitly
        // false, so an absent kwarg falls through to thinking-ON (Ornith, Qwen3).
        if lower.contains("enable_thinking is false")
            || lower.contains("enable_thinking == false")
            || lower.contains("not enable_thinking")
        {
            return true
        }
        // Otherwise the template only turns thinking ON when `enable_thinking` is
        // explicitly truthy (Gemma-4), so an absent kwarg means thinking-OFF.
        return false
    }

    /// The text of the branch a `{% if enable_thinking is defined %}` block
    /// runs when the kwarg is ABSENT: the first `else` / `elif` tag at the
    /// block's own nesting depth, up to the next same-depth tag. Nil when the
    /// template has no such block or the block has no fallback branch (Qwen3
    /// only ever asks `is defined` to guard a read, never to normalise).
    /// Pure and testable; exposed for the unit tests.
    static func undefinedKwargFallbackBranch(_ lower: String) -> String? {
        guard
            let tagRegex = try? NSRegularExpression(
                pattern: #"\{%-?\s*(.*?)\s*-?%\}"#,
                options: [.dotMatchesLineSeparators]
            )
        else { return nil }
        let ns = lower as NSString
        let tags = tagRegex.matches(in: lower, range: NSRange(location: 0, length: ns.length))
        guard !tags.isEmpty else { return nil }

        func body(_ match: NSTextCheckingResult) -> String {
            ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func isOpener(_ body: String) -> Bool {
            body == "if enable_thinking is defined"
                || body == "if (enable_thinking is defined)"
        }

        guard let start = tags.firstIndex(where: { isOpener(body($0)) }) else { return nil }
        func branch(from branchStart: Int, to end: Int) -> String {
            ns.substring(with: NSRange(location: branchStart, length: end - branchStart))
        }
        var depth = 0
        var branchStart: Int?
        for match in tags[(start + 1)...] {
            let text = body(match)
            let keyword = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            switch keyword {
            case "if":
                depth += 1
            case "endif":
                if depth == 0 {
                    return branchStart.map { branch(from: $0, to: match.range.location) }
                }
                depth -= 1
            case "else", "elif":
                guard depth == 0 else { continue }
                if let branchStart {
                    return branch(from: branchStart, to: match.range.location)
                }
                branchStart = match.range.location + match.range.length
            default:
                continue
            }
        }
        return nil
    }

    /// Classify what a normalisation fallback branch does: an assignment of
    /// a thinking-ish variable to an ON value (`'on'`, `true`, `'think'`...)
    /// or a bare `<think>` opener means thinking-ON; an OFF value or a
    /// closed `<think></think>` prefill means thinking-OFF. Nil when the
    /// branch does neither, so the older heuristics keep their turn.
    static func fallbackBranchTurnsThinkingOn(_ branch: String) -> Bool? {
        let assignment =
            #"set\s+[a-z0-9_]*(think|reason)[a-z0-9_]*\s*=\s*(true|false|['"]([a-z_]+)['"])"#
        if let regex = try? NSRegularExpression(pattern: assignment),
            let match = regex.firstMatch(
                in: branch, range: NSRange(location: 0, length: (branch as NSString).length)
            )
        {
            let ns = branch as NSString
            let value: String
            if match.range(at: 3).location != NSNotFound {
                value = ns.substring(with: match.range(at: 3))
            } else {
                value = ns.substring(with: match.range(at: 2))
            }
            switch value {
            case "true", "on", "think", "thinking", "reason", "reasoning", "enabled", "high", "max":
                return true
            case "false", "off", "no_think", "nothink", "chat", "direct", "none", "disabled":
                return false
            default:
                return nil
            }
        }
        if branch.contains("</think>") { return false }
        if branch.contains("<think>") { return true }
        return nil
    }

    /// Internal (not private): `DeclaredReasoningEffort` resolves bundles
    /// through the same lookup so the two caches can never disagree about
    /// which directory a model id maps to.
    static func localDirectory(forModelId modelId: String) -> URL? {
        // Delegate to the single source of truth: `findInstalledModel` already
        // accepts both the short repo name (picker/display form) and the full
        // `ORG/REPO` id, case-insensitive. Re-implementing the match here was
        // silently returning nil whenever the caller passed a form neither of
        // our candidate heuristics covered.
        //
        // On the main thread use the cache-only lookup: this is reached from
        // SwiftUI body evaluation (FloatingInputCard's reasoning suffix), and
        // the blocking variant parks on the cold-cache scan condition for up
        // to ~10s at launch. Off-main (server/generation paths) keep the
        // blocking lookup so capability detection stays authoritative.
        // Under tests everything runs on the main thread and suites expect
        // the blocking lookup's synchronous answer, so the shortcut is
        // production-only.
        let cacheOnly = Thread.isMainThread && !RuntimeEnvironment.isUnderTests
        let found =
            cacheOnly
            ? ModelManager.findInstalledMLXModelFromCache(named: modelId)
            : ModelManager.findInstalledMLXModel(named: modelId)
        // Externally registered bundles can be path-resolved from their
        // persisted manifest before the external catalog's heavier MLXModel
        // memo finishes rebuilding. This keeps dispatch-time capability
        // validation authoritative for HF/LM Studio/custom-folder models too.
        return found?.localDirectory ?? ExternalModelLocator.path(forId: modelId)
    }

    /// Read `jang_config.json > chat > reasoning` and surface it as a
    /// `Capability`. Returns nil when the file is missing, malformed, or
    /// doesn't carry the `chat.reasoning` sub-object — the caller should
    /// then return `.none`. Exposed (`static`, not `private`) so unit tests
    /// can exercise fixtures without writing to disk.
    ///
    /// Schema this recognises (a subset of the DSV4-Flash converter's
    /// output; newer JANG bundles are free to add more fields and we'll
    /// ignore them forward-compatibly):
    ///
    ///     {
    ///       "chat": {
    ///         "reasoning": {
    ///           "supported": true,
    ///           "modes": ["chat", "thinking"],
    ///           "default_mode": "chat",
    ///           "thinking_start": "<think>",
    ///           "thinking_end": "</think>"
    ///         }
    ///       }
    ///     }
    ///
    /// Note: we do NOT set `hasEnableThinkingKwarg: true` here — that flag
    /// is template-driven (does the Jinja template branch on
    /// `enable_thinking | default(...)`). DSV4's chat-encoder module
    /// reads a `thinking_mode` argument directly, so the kwarg flag
    /// stays false; callers plumb thinking-on/off through
    /// `modelOptions["disableThinking"]` as usual and vmlx's
    /// `additionalContext` passes it to whatever renderer the model uses.
    static func readJangConfigReasoning(at dir: URL) -> Capability? {
        let url = dir.appendingPathComponent("jang_config.json")
        guard let data = readSmallConfigFile(url) else {
            return nil
        }
        return analyzeJangConfig(data: data)
    }

    /// Pure, testable JSON parse for `jang_config.json`'s
    /// `chat.reasoning` sub-object. Separated from `readJangConfigReasoning`
    /// so unit tests can feed in fixtures without a filesystem.
    static func analyzeJangConfig(data: Data) -> Capability? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let reasoning = jangReasoningBlock(root),
            let supported = reasoning["supported"] as? Bool,
            supported
        else {
            return nil
        }
        return Capability(
            supportsThinking: true,
            hasEnableThinkingKwarg: false,
            templateInjectsThinkTag: false,
            defaultThinkingOn: jangReasoningDefaultThinkingOn(reasoning) ?? false
        )
    }

    /// Read the publisher's generic reasoning-channel declaration from the
    /// model bundle. This is deliberately narrower than family detection:
    /// `supports_thinking: true` is the contract; parser names and model ids
    /// are not guessed. Both config.json and jang_config.json are accepted
    /// because current publishers stamp the same `capabilities` object into
    /// either or both files.
    static func readDeclaredReasoningCapability(at dir: URL) -> Capability? {
        for filename in ["config.json", "jang_config.json"] {
            guard let data = readSmallConfigFile(dir.appendingPathComponent(filename)) else {
                continue
            }
            if let capability = analyzeDeclaredCapabilities(data: data) {
                return capability
            }
        }
        return nil
    }

    /// Pure parser for `capabilities.supports_thinking`. A false or missing
    /// declaration returns nil so template / legacy JANG detection keeps its
    /// existing behavior.
    static func analyzeDeclaredCapabilities(data: Data) -> Capability? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let capabilities = root["capabilities"] as? [String: Any],
            capabilities["supports_thinking"] as? Bool == true
        else { return nil }
        return Capability(
            supportsThinking: true,
            hasEnableThinkingKwarg: false,
            templateInjectsThinkTag: false,
            defaultThinkingOn: false
        )
    }

    /// The publisher's explicit serving-default declaration. Kept separate
    /// from the jang_config fallback below because this one is a deliberate
    /// wire contract (HF transformers applies the same key when the caller
    /// omits `enable_thinking`) and `AgentReasoningPolicy` honors it even on
    /// agent/tool surfaces, while jang_config defaults remain
    /// presentation-level metadata.
    private static func generationConfigDeclaredThinkingOn(at dir: URL) -> Bool? {
        guard
            let data = readSmallConfigFile(dir.appendingPathComponent("generation_config.json")),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let defaults = root["default_chat_template_kwargs"] as? [String: Any],
            let enableThinking = defaults["enable_thinking"] as? Bool
        else { return nil }
        return enableThinking
    }

    /// Bundle metadata can override the Jinja fallback for omitted kwargs. Laguna
    /// S 2.1 is the concrete case: its sidecar template says
    /// `enable_thinking | default(false)`, but generation_config and
    /// jang_config both stamp the serving default as thinking-on. The UI should
    /// present that effective default, and request construction should still
    /// send nothing until the user/API makes an explicit choice.
    private static func readTemplateDefaultThinkingOn(at dir: URL) -> Bool? {
        let jangURL = dir.appendingPathComponent("jang_config.json")
        guard let data = readSmallConfigFile(jangURL) else { return nil }
        return jangConfigDefaultThinkingOn(data: data)
    }

    /// Pure, testable read of the jang_config serving default. Accepts both
    /// the legacy `chat.reasoning` sub-object (DSV4-Flash) and the newer
    /// TOP-LEVEL `reasoning` block (Raptor / Ling 3 converters stamp
    /// `"reasoning": {"default": "on", ...}` beside `chat`, the same block
    /// `DeclaredReasoningEffort` already reads). Nil when neither carries a
    /// recognised default key.
    static func jangConfigDefaultThinkingOn(data: Data) -> Bool? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let reasoning = jangReasoningBlock(root)
        else {
            return nil
        }
        return jangReasoningDefaultThinkingOn(reasoning)
    }

    /// The bundle's reasoning declaration: top-level `reasoning` first, then
    /// the legacy `chat.reasoning` location. Mirrors
    /// `DeclaredReasoningEffort.parseJangDeclaration` so the two readers can
    /// never disagree about which block a bundle declares.
    private static func jangReasoningBlock(_ root: [String: Any]) -> [String: Any]? {
        (root["reasoning"] as? [String: Any])
            ?? ((root["chat"] as? [String: Any])?["reasoning"] as? [String: Any])
    }

    private static func jangReasoningDefaultThinkingOn(_ reasoning: [String: Any]) -> Bool? {
        if let enabled = reasoning["default_enabled"] as? Bool {
            return enabled
        }
        // Top-level block convention: `"default": "on" | "off"` (a bool is
        // accepted too, so a converter that stamps `true` is not misread).
        if let enabled = reasoning["default"] as? Bool {
            return enabled
        }
        if let mode = (reasoning["default"] as? String) ?? (reasoning["default_mode"] as? String) {
            switch mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "on", "enabled", "true", "think", "thinking", "reason", "reasoning", "high", "max":
                return true
            case "off", "disabled", "false", "chat", "direct", "none", "no_think", "nothink":
                return false
            default:
                break
            }
        }
        return nil
    }

    static func readChatTemplate(at dir: URL) -> String? {
        let jinja = dir.appendingPathComponent("chat_template.jinja")
        if let data = readSmallConfigFile(jinja),
            let s = String(data: data, encoding: .utf8)
        {
            return s
        }
        if let sidecar = readChatTemplateSidecar(at: dir),
            isVisionChatTemplate(sidecar),
            !tokenizerConfigTemplateContainsVisionMarker(at: dir)
        {
            return sidecar
        }
        let tokenizerCfg = dir.appendingPathComponent("tokenizer_config.json")
        if let data = readSmallConfigFile(tokenizerCfg),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let tmpl = obj["chat_template"] as? String { return tmpl }
            // HF sometimes ships an array form: [{"name": "default", "template": "..."}]
            if let arr = obj["chat_template"] as? [[String: Any]],
                let first = arr.first,
                let tmpl = first["template"] as? String
            {
                return tmpl
            }
        }
        return nil
    }

    private static func readChatTemplateSidecar(at dir: URL) -> String? {
        let url = dir.appendingPathComponent("chat_template.json")
        guard let data = readSmallConfigFile(url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let template = obj["chat_template"] as? String
        else {
            return nil
        }
        return template
    }

    private static func tokenizerConfigTemplateContainsVisionMarker(at dir: URL) -> Bool {
        guard let template = readTokenizerConfigTemplate(at: dir) else {
            return false
        }
        return isVisionChatTemplate(template)
    }

    private static func readTokenizerConfigTemplate(at dir: URL) -> String? {
        let tokenizerCfg = dir.appendingPathComponent("tokenizer_config.json")
        guard let data = readSmallConfigFile(tokenizerCfg),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let tmpl = obj["chat_template"] as? String { return tmpl }
        if let arr = obj["chat_template"] as? [[String: Any]],
            let first = arr.first,
            let tmpl = first["template"] as? String
        {
            return tmpl
        }
        return nil
    }

    /// Internal (not private): shared with `DeclaredReasoningEffort` for the
    /// same non-blocking bounded-read discipline on sidecar configs.
    static func readSmallConfigFile(_ url: URL, maxBytes: Int = 1_048_576) -> Data? {
        let path = url.path
        return path.withCString { rawPath in
            let fd = Darwin.open(rawPath, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { Darwin.close(fd) }

            var statBuffer = stat()
            guard Darwin.fstat(fd, &statBuffer) == 0,
                (statBuffer.st_mode & S_IFMT) == S_IFREG,
                statBuffer.st_size >= 0,
                statBuffer.st_size <= maxBytes
            else {
                return nil
            }

            var data = Data(count: Int(statBuffer.st_size))
            let count = data.count
            guard count > 0 else { return Data() }
            let readCount = data.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, count)
            }
            guard readCount == count else { return nil }
            return data
        }
    }

    private static func isVisionChatTemplate(_ template: String) -> Bool {
        template.contains("<|vision_start|>")
            || template.contains("<|image_pad|>")
            || template.contains("<|video_pad|>")
            || template.contains("<|image|>")
            || template.contains("<image>")
    }
}
