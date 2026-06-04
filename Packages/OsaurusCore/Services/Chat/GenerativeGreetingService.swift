//
//  GenerativeGreetingService.swift
//  osaurus
//
//  Generates a single delightful greeting + four bespoke quick actions for
//  the chat empty state. Routes through `CoreModelService` so the user's
//  configured Core Model (Foundation / MLX / remote) drives the call,
//  with the active chat model as a fallback per issue #823. All failures
//  are silent — the caller treats `nil` as "use the static defaults".
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "core_model")

public enum GenerativeGreetingError: Error, LocalizedError, Equatable {
    case emptyResponse
    case malformedJSON
    case missingFields

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Greeting generation returned no text"
        case .malformedJSON:
            return "Greeting generation returned invalid JSON"
        case .missingFields:
            return "Greeting generation returned an incomplete payload"
        }
    }
}

public actor GenerativeGreetingService {
    public static let shared = GenerativeGreetingService()

    /// Curated SF Symbol allowlist passed to the model. Keeping this short
    /// keeps the JSON valid (smaller search space) and prevents the UI from
    /// hitting `Image(systemName:)` with a name that doesn't render. Any
    /// icon outside this list is silently rewritten to `sparkles`.
    private static let iconAllowlist: [String] = [
        "lightbulb",
        "doc.text",
        "chevron.left.forwardslash.chevron.right",
        "pencil.line",
        "sparkles",
        "paintbrush",
        "magnifyingglass",
        "calendar",
        "message",
        "book",
        "paperplane",
        "leaf",
        "mountain.2",
        "music.note",
        "bolt",
        "wand.and.stars",
        "globe",
        "folder",
        "list.bullet",
        "sun.max",
        "moon.stars",
        "questionmark.bubble",
    ]

    /// Hard cap for the system-prompt summary. The model only needs the
    /// agent's flavor, not the full prompt — keeping this tight saves
    /// tokens and leaves more headroom for delight.
    private static let maxSystemPromptChars = 280
    /// Hard cap on the assembled memory-hint block we inject into the
    /// system prompt. Keeps the prompt bounded so the 6s timeout still
    /// holds and we don't blow out small Core Models' context windows.
    private static let maxMemoryHintsChars = 600
    /// Per-line clip applied to identity overrides and pinned-fact bullets
    /// before we hard-cap the joined block. Episodes use a tighter clip
    /// (`maxEpisodeBulletChars`) since their summaries are denser.
    private static let maxFactBulletChars = 140
    private static let maxEpisodeBulletChars = 120
    /// 280-char clip for the auto-derived identity narrative — matches
    /// the plan and avoids dragging the whole multi-paragraph document
    /// into a delight-only prompt.
    private static let maxIdentityContentChars = 280
    private static let timeout: TimeInterval = 6
    /// Bumped from 0.8 → 0.85 to give the playful default voice a bit
    /// more variety across consecutive empty states. The tagged-line
    /// contract parses just as reliably as JSON at this level
    /// (verified in dev with Foundation + a 7B MLX model); raise
    /// further with caution.
    private static let temperature: Double = 0.85

    /// Size-class-aware token budget for the empty-state generation.
    /// Tiny models (Apple Foundation) can't afford a 320-token cap
    /// without crowding out the rest of the context; we drop the
    /// budget along with the action count so the model has a real
    /// chance of finishing the contract within the 6s timeout.
    static func maxTokens(for sizeClass: ContextSizeClass) -> Int {
        switch sizeClass {
        case .tiny: return 180
        case .small: return 260
        case .normal: return 320
        }
    }

    /// Number of quick actions to request from the model. Tiny models
    /// struggle to keep four parallel verbs straight on a single
    /// completion; two action lines is the sweet spot. Other sizes
    /// keep the full grid of four.
    static func expectedActionCount(for sizeClass: ContextSizeClass) -> Int {
        switch sizeClass {
        case .tiny: return 2
        case .small, .normal: return 4
        }
    }

    /// Resolve which model will actually serve the generation so the
    /// prompt and parser stay in sync. Reads the configured Core Model
    /// first (matches `CoreModelService.generate`'s routing), falling
    /// back to the caller's hint, then `nil`.
    static func sizeClass(coreModelIdentifier: String?, fallbackModel: String?) -> ContextSizeClass {
        let resolved = coreModelIdentifier ?? fallbackModel
        return ContextSizeResolver.resolve(modelId: resolved).sizeClass
    }
    /// How long a freshly-built memory-hint block stays valid for an
    /// agent. A refill burst (target=3) makes 3 generations in a few
    /// seconds; without the cache we'd hit SQLite 9 times for data
    /// that effectively never changes within that window. 30s is
    /// short enough that fact / episode edits propagate within one
    /// pool tick of latency, long enough to absorb a full refill.
    private static let memoryHintsTTL: TimeInterval = 30

    /// Per-agent cache of the last computed hint block. Keyed by
    /// agent id; entries expire after `memoryHintsTTL`. Survives
    /// `actor` reentrancy because reads/writes are serialized
    /// through the actor's mailbox.
    private struct CachedHints {
        let hints: String?
        let expires: Date
    }
    private var hintsCache: [UUID: CachedHints] = [:]

    /// Built-in playful default for the greeting voice. Used whenever
    /// neither the per-agent override nor the global persona is set.
    /// Tone goal: surprising verbs, light wordplay, no fortune-cookie
    /// energy. The "avoid 'Welcome'/'Hello'/'Hey there'" rule pushes
    /// the model off its safest opener choices, which is where the
    /// generic-feeling greetings come from.
    ///
    /// Surfaced publicly so the Settings UI can show the actual default
    /// in its Personality field placeholder — users get to see what
    /// runs when they leave the field empty, and can copy-paste the
    /// text into the field as a starting point.
    public static let defaultPersonaInstruction = """
        Voice: an upbeat, witty co-pilot. Surprising verbs, light wordplay, \
        and the occasional gentle in-joke about the user's domain. Avoid \
        corny mascot energy, fortune-cookie wisdom, and the openers \
        "Welcome", "Hello", and "Hey there". Each greeting should feel \
        like it was written for THIS user at THIS time of day, not lifted \
        from a template. Two consecutive generations must not share the \
        same opening word or the same set of verbs.
        """

    private init() {}

    /// Generate a freshly produced greeting + 4 quick actions for `agent`.
    /// Pass `fallbackModel: ChatSession.selectedModel` so the call works
    /// even when the user hasn't configured an explicit Core Model.
    public func generate(
        agent: Agent,
        fallbackModel: String?,
        locale: Locale = .current,
        now: Date = Date()
    ) async throws -> GenerativeGreeting {
        // Memory hints come from SQLite (`MemoryDatabase`) and the
        // global/per-agent toggle on `AgentManager`. We assemble them
        // before building the prompt so the prompt path stays purely
        // synchronous + deterministic for testing.
        let memoryHints = await buildMemoryHints(for: agent)
        // Read the global persona once on the main actor — same hop
        // pattern as `effectiveMemoryDisabled`. Per-agent override wins
        // when present.
        let (globalPersona, coreModelIdentifier) = await MainActor.run {
            (
                AppConfiguration.shared.chatConfig.greetingPersona,
                AppConfiguration.shared.chatConfig.coreModelIdentifier
            )
        }
        let personaInstruction =
            Self.resolvedPersona(agent: agent, global: globalPersona)
            ?? Self.defaultPersonaInstruction
        // Resolve the size class once so the prompt builder and the
        // parser agree on the expected action count. We deliberately
        // skew "tiny" prompts toward positive examples and 2 actions —
        // negative rules + 4 actions overflow Foundation's 4K window
        // and trigger the JSON-broken-1-in-3 pattern this revamp is
        // designed to eliminate.
        let sizeClass = Self.sizeClass(
            coreModelIdentifier: coreModelIdentifier,
            fallbackModel: fallbackModel
        )
        let expectedActions = Self.expectedActionCount(for: sizeClass)
        let context = buildContext(
            agent: agent,
            locale: locale,
            now: now,
            memoryHints: memoryHints,
            personaInstruction: personaInstruction
        )
        let systemPrompt = Self.buildSystemPrompt(
            context: context,
            sizeClass: sizeClass,
            expectedActions: expectedActions
        )
        let userPrompt = Self.userTriggerPrompt(for: sizeClass)

        // Two-attempt cap: first call at the configured temperature,
        // then exactly one retry at a slightly cooler sampler when the
        // quality gate (boring opener, short action list) trips. The
        // ceiling keeps worst-case wall clock under 2× `timeout` so a
        // single greedy model can't stall the pool refill loop.
        let attempt: @Sendable (Double) async throws -> String = { temperature in
            try await CoreModelService.shared.generate(
                prompt: userPrompt,
                systemPrompt: systemPrompt,
                temperature: temperature,
                maxTokens: Self.maxTokens(for: sizeClass),
                timeout: Self.timeout,
                fallbackModel: fallbackModel
            )
        }

        let firstRaw = try await attempt(Self.temperature)
        if let first = try? Self.parse(firstRaw, expectedActions: expectedActions),
            !Self.shouldRetryForQuality(first, expectedActions: expectedActions)
        {
            return first
        }

        // Retry at a cooler temperature. A clean but slightly boring
        // retry is still preferred over throwing back to the static
        // fallback. A malformed/corrupted retry is not: returning it
        // would surface model-contract garbage in the empty state.
        let retryRaw = try await attempt(max(0.3, Self.temperature - 0.1))
        let retry = try Self.parse(retryRaw, expectedActions: expectedActions)
        if Self.shouldRetryForQuality(retry, expectedActions: expectedActions) {
            throw GenerativeGreetingError.missingFields
        }
        return retry
    }

    /// Quality gate that decides whether to spend a second model call
    /// on the same prompt. Trips when the greeting opens with one of
    /// the model's "safest" lazy choices (`Welcome` / `Hello` / `Hey
    /// there`), or when the action count came back short — the latter
    /// usually means the model hit max-tokens partway through. Case-
    /// insensitive, whitespace-tolerant.
    static func shouldRetryForQuality(
        _ greeting: GenerativeGreeting,
        expectedActions: Int
    ) -> Bool {
        if greeting.actions.count < expectedActions { return true }
        let fields =
            [greeting.greeting, greeting.subtitle]
            + greeting.actions.flatMap { [$0.text, $0.prompt] }
        if fields.contains(where: containsCorruptedGreetingText) { return true }
        let opener = greeting.greeting
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let bannedOpeners = ["welcome", "hello", "hey there"]
        for banned in bannedOpeners {
            if opener == banned || opener.hasPrefix(banned + " ") {
                return true
            }
        }
        return false
    }

    private static func containsCorruptedGreetingText(_ text: String) -> Bool {
        if text.contains("<") || text.contains(">") || text.contains("{") || text.contains("}") {
            return true
        }
        if text.contains("__") || text.contains("000") {
            return true
        }
        if text.range(
            of: #"(?i)\bor0|\b0_|_provider|_tool|anthopm|anthropicm|\bI'\s+[a-z]"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return false
    }

    // MARK: - Context

    private struct Context {
        let agentDisplayName: String
        let agentDescription: String
        let systemPromptSummary: String
        let timeOfDay: String
        let localTimeString: String
        let localeIdentifier: String
        /// Pre-formatted memory bullets to weave into the greeting. `nil`
        /// when memory is disabled or there's nothing meaningful to share.
        let memoryHints: String?
        /// Resolved voice instruction — either user-authored (per-agent
        /// override > global persona) or the built-in playful default.
        /// Always non-empty.
        let personaInstruction: String
    }

    /// Per-agent override > global persona > nil. Whitespace-only
    /// strings are treated as nil so a cleared field falls through to
    /// the next layer.
    static func resolvedPersona(agent: Agent, global: String) -> String? {
        let agentTrim =
            (agent.settings.greetingPersona ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !agentTrim.isEmpty { return agentTrim }
        let globalTrim = global.trimmingCharacters(in: .whitespacesAndNewlines)
        return globalTrim.isEmpty ? nil : globalTrim
    }

    private func buildContext(
        agent: Agent,
        locale: Locale,
        now: Date,
        memoryHints: String?,
        personaInstruction: String
    ) -> Context {
        let summary = Self.summarizeSystemPrompt(agent.systemPrompt)
        let hour = Calendar.current.component(.hour, from: now)
        let timeOfDay: String
        switch hour {
        case 5 ..< 12: timeOfDay = "morning"
        case 12 ..< 17: timeOfDay = "afternoon"
        case 17 ..< 22: timeOfDay = "evening"
        default: timeOfDay = "night"
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        return Context(
            agentDisplayName: agent.displayName,
            agentDescription: agent.displayDescription,
            systemPromptSummary: summary,
            timeOfDay: timeOfDay,
            localTimeString: formatter.string(from: now),
            localeIdentifier: locale.identifier,
            memoryHints: memoryHints,
            personaInstruction: personaInstruction
        )
    }

    // MARK: - Memory hints

    /// Build a compact memory-hint block that lets the model flavor the
    /// greeting without exposing raw stored facts. Returns `nil` when
    /// memory is disabled, the database can't be opened, or there's
    /// nothing meaningful stored for this agent — in those cases the
    /// caller skips the hint block entirely so we don't inject empty
    /// section headers into the system prompt.
    ///
    /// Cached for `memoryHintsTTL` seconds per agent so a back-to-back
    /// refill burst doesn't replay 9 SQLite reads against effectively
    /// unchanging data.
    private func buildMemoryHints(for agent: Agent) async -> String? {
        if let cached = hintsCache[agent.id], cached.expires > Date() {
            return cached.hints
        }
        let fresh = await computeMemoryHints(for: agent)
        hintsCache[agent.id] = CachedHints(
            hints: fresh,
            expires: Date().addingTimeInterval(Self.memoryHintsTTL)
        )
        return fresh
    }

    /// Uncached worker that actually hits SQLite. Split out so
    /// `buildMemoryHints` can be a pure cache-or-refresh wrapper.
    private func computeMemoryHints(for agent: Agent) async -> String? {
        // Honor both global and per-agent memory toggles. `AgentManager`
        // is `@MainActor`-isolated, so we must hop to the main actor to
        // read the effective state.
        let memoryDisabled = await MainActor.run {
            AgentManager.shared.effectiveMemoryDisabled(for: agent.id)
        }
        if memoryDisabled { return nil }

        let db = MemoryDatabase.shared
        guard db.isOpen else { return nil }

        let agentId = agent.id.uuidString

        var sections: [String] = []

        if let identity = try? db.loadIdentity() {
            var identityBullets: [String] = []
            // Identity overrides are user-authored "always-on" facts —
            // surface up to 5 verbatim. They're already short.
            for override in identity.overrides.prefix(5) {
                let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                identityBullets.append("- " + Self.clip(trimmed, to: Self.maxFactBulletChars))
            }
            // Auto-derived identity narrative — first ~280 chars only;
            // the full document tends to be far too long for a delight
            // prompt and would crowd out the agent's purpose.
            let content = identity.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                identityBullets.append(
                    "- " + Self.clip(content, to: Self.maxIdentityContentChars)
                )
            }
            if !identityBullets.isEmpty {
                sections.append(
                    "About the user:\n" + identityBullets.joined(separator: "\n")
                )
            }
        }

        if let facts = try? db.loadPinnedFacts(
            agentId: agentId,
            limit: 3,
            minSalience: 0.3
        ), !facts.isEmpty {
            let bullets = facts.map { fact -> String in
                let text = fact.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return "- " + Self.clip(text, to: Self.maxFactBulletChars)
            }
            sections.append("Salient facts:\n" + bullets.joined(separator: "\n"))
        }

        if let episodes = try? db.loadEpisodes(
            agentId: agentId,
            days: 30,
            limit: 2
        ), !episodes.isEmpty {
            let bullets = episodes.map { episode -> String in
                let text = episode.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return "- " + Self.clip(text, to: Self.maxEpisodeBulletChars)
            }
            sections.append("Recent threads:\n" + bullets.joined(separator: "\n"))
        }

        guard !sections.isEmpty else { return nil }
        let joined = sections.joined(separator: "\n\n")
        return Self.clip(joined, to: Self.maxMemoryHintsChars)
    }

    /// Truncate a string at a character budget, appending an ellipsis
    /// when content is dropped so the model knows there was more.
    private static func clip(_ text: String, to limit: Int) -> String {
        if text.count <= limit { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "…"
    }

    private static func summarizeSystemPrompt(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.count <= maxSystemPromptChars { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxSystemPromptChars)
        return String(trimmed[..<endIndex]) + "…"
    }

    // MARK: - Prompt construction

    /// User-turn trigger. Wording mirrors the system prompt's
    /// contract so the model doesn't slip back into JSON when given a
    /// tagged-line spec (or vice-versa). Sized-class-aware because
    /// tiny models follow the "exactly these lines" cue better than a
    /// generic "Generate now".
    private static func userTriggerPrompt(for sizeClass: ContextSizeClass) -> String {
        switch sizeClass {
        case .tiny:
            return "Generate now. Reply with exactly the four labeled lines, nothing else."
        case .small, .normal:
            return "Generate now. Reply with the labeled lines only, no prose."
        }
    }

    private static func buildSystemPrompt(
        context: Context,
        sizeClass: ContextSizeClass,
        expectedActions: Int
    ) -> String {
        let iconList = iconAllowlist.joined(separator: ", ")
        let agentBlock: String = {
            if context.agentDescription.isEmpty {
                return "The active agent is \"\(context.agentDisplayName)\"."
            }
            return
                "The active agent is \"\(context.agentDisplayName)\" — \(context.agentDescription)."
        }()
        let purposeBlock: String =
            context.systemPromptSummary.isEmpty
            ? ""
            : "\nIts purpose: \(context.systemPromptSummary)"

        // Memory block goes between the framing instructions and the
        // strict tagged-line contract so the contract still terminates
        // the prompt — placement matters for models that pay extra
        // attention to the last paragraph. The wording is deliberately
        // blunt about "never repeat verbatim" because chatty models
        // love to leak stored facts into the greeting line.
        let memoryBlock: String = {
            guard let hints = context.memoryHints,
                !hints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return "" }
            return """


                What you quietly know about the user (use ONLY to make the greeting and \
                actions feel personally tuned — never repeat these facts verbatim, never \
                say "I remember…", never list them; weave them indirectly through topic \
                choice, verbs, and nouns):
                \(hints)
                """
        }()

        // Tiny models follow positive few-shot far better than negative
        // rules. Replace the long "avoid Welcome/Hello/Hey there"
        // paragraph with a single concrete example. Larger models can
        // still afford the persona's full wording.
        let voiceBlock: String = {
            switch sizeClass {
            case .tiny:
                return """
                    Voice: friendly, specific, never opens with Welcome, Hello, or Hey there. \
                    Example output for evening, calm voice:
                    GREETING: Soho Delight
                    SUBTITLE: Map your next move with a quick win.
                    ACTION1: sparkles|Boost|Give me one bold idea for\u{0020}
                    ACTION2: calendar|Plan Ahead|Sketch tomorrow's top three priorities for\u{0020}
                    """
            case .small, .normal:
                return context.personaInstruction
            }
        }()

        let actionLines: String = (1 ... expectedActions)
            .map { "ACTION\($0): icon|label|prompt words" }
            .joined(separator: "\n")

        let contractBlock = """
            Output exactly these labeled lines, in this order, no extra text, no Markdown, no JSON, no code fences:
            GREETING: short greeting without trailing punctuation
            SUBTITLE: short sentence ending with a period or question mark
            \(actionLines)

            Field rules (strictly enforced):
            - Each ACTION line is three pipe-delimited fields. The pipe `|` is the only delimiter; \
            it must never appear inside any field.
            - icon MUST be one of: \(iconList).
            - label is a 1- or 2-word button label, max 14 characters. Concrete nouns or verbs, \
            not sentences.
            - prompt words are what the user clicks to start typing; they must end \
            with a single trailing space and reference a specific noun, person, project, or domain \
            inferred from the agent's purpose (and, when available, the user knowledge above) — \
            never a generic "something" or "an idea".
            - All \(expectedActions) actions must use different verbs and different domains. No \
            duplicates.
            """

        return """
            You are the greeter for an AI assistant's empty state. Produce ONE specific greeting, \
            ONE subtitle, and \(expectedActions) quick-action shortcuts the user might want to try \
            right now. \(agentBlock)\(purposeBlock)
            Local time is \(context.localTimeString) (\(context.timeOfDay)). User locale: \
            \(context.localeIdentifier). Write in the user's locale language. No emoji.

            \(voiceBlock)\(memoryBlock)

            \(contractBlock)
            """
    }

    // MARK: - Parsing

    private struct DTO: Decodable {
        struct Action: Decodable {
            let icon: String
            let text: String
            let prompt: String
        }
        let greeting: String
        let subtitle: String
        let actions: [Action]
    }

    /// Fallback action count used when callers don't thread an
    /// explicit value through. Matches the `.normal` size class so
    /// pre-size-class tests keep their expectations.
    private static let defaultExpectedActionCount = 4

    /// Pre-built character set for stripping line terminators while
    /// preserving meaningful trailing whitespace on action payloads.
    /// Hoisted so `parseTaggedLines`' tight loop doesn't re-allocate
    /// it on every iteration.
    private static let lineTerminatorCharacterSet = CharacterSet(charactersIn: "\r\n")

    /// Parse a raw model response into a `GenerativeGreeting`. Tries
    /// the tagged-line format first (the new contract issued by
    /// `buildSystemPrompt`); falls back to the legacy JSON format so
    /// older Foundation completions that haven't picked up the new
    /// prompt still parse on the first generation after upgrade. A
    /// total parse failure throws `malformedJSON` so the caller can
    /// trip its quality-gate retry.
    static func parse(_ raw: String, expectedActions: Int = defaultExpectedActionCount) throws -> GenerativeGreeting {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GenerativeGreetingError.emptyResponse }

        // Commit early to whichever format the model emitted so the
        // error we throw matches the actual failure shape. If the
        // response carries any tagged-line markers we surface the
        // line-parser's `missingFields` rather than letting the JSON
        // path overwrite it with a confusing `malformedJSON`.
        if hasTaggedLineMarkers(trimmed) {
            return try parseTaggedLines(trimmed, expectedActions: expectedActions)
        }

        // Back-compat path: legacy JSON contract. Some Foundation
        // completions still mid-flight at upgrade time will emit the
        // old shape; a few MLX builds prefer JSON regardless of prompt.
        return try parseLegacyJSON(trimmed, expectedActions: expectedActions)
    }

    /// Cheap discriminator that lets `parse` commit to the right
    /// format before doing the heavier work. Matches the prompt's
    /// label tokens at line start, case-insensitive, ignoring leading
    /// whitespace so a slightly indented response still counts.
    private static func hasTaggedLineMarkers(_ raw: String) -> Bool {
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("greeting:") || line.hasPrefix("subtitle:")
                || line.hasPrefix("action")
            {
                return true
            }
        }
        return false
    }

    /// Tagged-line format produced by the new `buildSystemPrompt`.
    /// Strict about the four label tokens (`GREETING`, `SUBTITLE`,
    /// `ACTION1…N`) so a JSON payload won't accidentally pass through
    /// the regex.
    private static func parseTaggedLines(
        _ raw: String,
        expectedActions: Int
    ) throws -> GenerativeGreeting {
        var greeting: String?
        var subtitle: String?
        var actions: [(Int, AgentQuickAction)] = []

        // Strip leading whitespace + trailing newline/CR only —
        // preserving a trailing space is part of the ACTION contract,
        // and trimming both ends here would silently delete it
        // before the payload parser ever sees it.
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = trimLeading(rawLine)
                .trimmingCharacters(in: Self.lineTerminatorCharacterSet)
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            if let value = stripPrefix(line, label: "GREETING") {
                greeting = value
            } else if let value = stripPrefix(line, label: "SUBTITLE") {
                subtitle = value
            } else if let (index, value) = stripActionPrefix(line),
                let action = parseActionPayload(value)
            {
                actions.append((index, action))
            }
        }

        guard let g = greeting, !g.isEmpty,
            let s = subtitle, !s.isEmpty,
            !actions.isEmpty
        else {
            throw GenerativeGreetingError.missingFields
        }

        // Sort by the action index so a model that emits ACTION2/ACTION1
        // out of order still produces a deterministic grid. De-dupe by
        // index, preferring the first occurrence.
        var seen: Set<Int> = []
        let ordered =
            actions
            .sorted { $0.0 < $1.0 }
            .filter { seen.insert($0.0).inserted }
            .map { $0.1 }
            .prefix(expectedActions)

        guard ordered.count == expectedActions else {
            throw GenerativeGreetingError.missingFields
        }

        return GenerativeGreeting(
            greeting: cap(g, words: 8),
            subtitle: cap(s, words: 16),
            actions: Array(ordered)
        )
    }

    /// Match a `LABEL:` prefix (case-insensitive) and return the
    /// trimmed value. Returns `nil` when the prefix doesn't match so
    /// the caller can try the next label. The label values (greeting,
    /// subtitle) are themselves trimmed because trailing whitespace
    /// has no semantic meaning there.
    private static func stripPrefix(_ line: String, label: String) -> String? {
        let candidate = "\(label):"
        guard line.lowercased().hasPrefix(candidate.lowercased()) else { return nil }
        let value = line.dropFirst(candidate.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    /// Match `ACTION<index>:` and return (index, payload). Index is
    /// 1-based to match the prompt; values outside `1...99` are
    /// rejected to keep the parser well-bounded. The payload is
    /// returned with leading whitespace stripped but trailing
    /// whitespace preserved so the action's prompt-suffix space
    /// survives to `parseActionPayload`.
    private static func stripActionPrefix(_ line: String) -> (Int, String)? {
        let lower = line.lowercased()
        guard lower.hasPrefix("action") else { return nil }
        let afterPrefix = line.dropFirst("action".count)
        // Read digits until the colon.
        var digits = ""
        var remainder = afterPrefix
        while let first = remainder.first, first.isNumber {
            digits.append(first)
            remainder = remainder.dropFirst()
        }
        guard !digits.isEmpty, let index = Int(digits), (1 ... 99).contains(index),
            remainder.first == ":"
        else { return nil }
        let value = trimLeading(String(remainder.dropFirst()))
        return (index, value)
    }

    /// Split an action payload on `|` into (icon, label, prompt) and
    /// run it through the same sanitiser the JSON path uses so length
    /// caps and icon allowlisting stay in one place. Trailing space
    /// on the prompt is preserved when the model honored it — the
    /// `cap` step never strips internal whitespace.
    private static func parseActionPayload(_ payload: String) -> AgentQuickAction? {
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let icon = parts[0].trimmingCharacters(in: .whitespaces)
        let text = parts[1].trimmingCharacters(in: .whitespaces)
        // Prompt may legitimately end with a single trailing space; only
        // trim leading whitespace + newlines, never trailing spaces.
        let prompt = trimLeading(parts[2])
        guard iconAllowlist.contains(icon), !text.isEmpty, !prompt.isEmpty else { return nil }
        return sanitize(action: DTO.Action(icon: icon, text: text, prompt: prompt))
    }

    /// Drop leading whitespace + newlines but preserve any trailing
    /// space. Used for action prompts where the prompt's trailing
    /// space is part of the contract.
    private static func trimLeading(_ s: String) -> String {
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isWhitespace || s[idx].isNewline {
            idx = s.index(after: idx)
        }
        return String(s[idx...])
    }

    /// Legacy JSON parse path. Kept verbatim from the pre-revamp
    /// implementation so a Foundation completion still mid-flight at
    /// upgrade time has a graceful fallback. Same error contract as
    /// before.
    private static func parseLegacyJSON(
        _ trimmed: String,
        expectedActions: Int
    ) throws -> GenerativeGreeting {
        guard let jsonString = extractJSONObject(from: trimmed) else {
            logger.warning("greeting: neither tagged lines nor JSON found in response")
            throw GenerativeGreetingError.malformedJSON
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw GenerativeGreetingError.malformedJSON
        }

        let dto: DTO
        do {
            dto = try JSONDecoder().decode(DTO.self, from: data)
        } catch {
            logger.warning("greeting: JSON decode failed: \(error.localizedDescription)")
            throw GenerativeGreetingError.malformedJSON
        }

        let greeting = dto.greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = dto.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !greeting.isEmpty, !subtitle.isEmpty, !dto.actions.isEmpty else {
            throw GenerativeGreetingError.missingFields
        }

        let actions = dto.actions
            .prefix(expectedActions)
            .map(sanitize(action:))
            .filter { !$0.text.isEmpty && !$0.prompt.isEmpty }

        guard actions.count == expectedActions else {
            throw GenerativeGreetingError.missingFields
        }

        return GenerativeGreeting(
            greeting: cap(greeting, words: 8),
            subtitle: cap(subtitle, words: 16),
            actions: actions
        )
    }

    /// Hard ceiling on action-button labels in the empty state.
    /// `QuickActionButton` reserves ~120pt of label width and uses size-13
    /// medium font; keep this aligned with the prompt's 14-character
    /// promise so the button shrink-to-fit only kicks in for outliers.
    private static let actionTextCharCap = 14

    private static func sanitize(action: DTO.Action) -> AgentQuickAction {
        let icon = iconAllowlist.contains(action.icon) ? action.icon : "sparkles"
        let trimmedText = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Word cap first (drops trailing words wholesale), then character
        // cap — preferring to drop the second word over splitting a token
        // mid-letter, which would render as "Productivit".
        let text = clampActionText(cap(trimmedText, words: 2), to: actionTextCharCap)
        let prompt = sanitizePrompt(action.prompt)
        return AgentQuickAction(icon: icon, text: text, prompt: prompt)
    }

    /// Trim around an action's prompt while preserving a trailing
    /// space when the model provided one. The chat input field puts
    /// the caret immediately after the prompt, so dropping a trailing
    /// space here breaks the "click to start typing" affordance the
    /// quick-action contract promises.
    private static func sanitizePrompt(_ raw: String) -> String {
        let hadTrailingSpace = raw.last == " "
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = cap(trimmed, words: 12)
        guard hadTrailingSpace, !capped.isEmpty, capped.last != " " else { return capped }
        return capped + " "
    }

    /// Truncate to a soft word budget, preserving the start of the string.
    /// Defensive against models that ignore length hints.
    private static func cap(_ text: String, words: Int) -> String {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > words else { return text }
        return parts.prefix(words).joined(separator: " ")
    }

    /// Token-aware character cap. If a 2-word label overshoots, drop the
    /// trailing word rather than slicing mid-token (so "Strategy Review"
    /// → "Strategy" instead of "Strategy Revi"). When even the first
    /// token is too long, fall back to a hard slice — at that point the
    /// button's `minimumScaleFactor` will take over visually anyway.
    private static func clampActionText(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count > 1 {
            let head = String(parts.first!)
            if head.count <= limit { return head }
            return String(head.prefix(limit))
        }
        return String(text.prefix(limit))
    }

    /// Extract the first balanced top-level JSON object substring from
    /// `raw`. Tolerates code fences ("```json ... ```") and chatty
    /// preambles that some models still emit despite a JSON-only request.
    private static func extractJSONObject(from raw: String) -> String? {
        guard let firstBrace = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var end: String.Index?

        for idx in raw.indices[firstBrace...] {
            let ch = raw[idx]
            if escape {
                escape = false
                continue
            }
            if ch == "\\" {
                escape = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    end = raw.index(after: idx)
                    break
                }
            }
        }

        guard let end else { return nil }
        return String(raw[firstBrace ..< end])
    }
}
