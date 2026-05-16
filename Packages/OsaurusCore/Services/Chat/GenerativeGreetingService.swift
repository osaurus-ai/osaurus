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
    private static let maxTokens = 320
    private static let timeout: TimeInterval = 6
    /// Bumped from 0.8 → 0.85 to give the playful default voice a bit
    /// more variety across consecutive empty states. JSON parses still
    /// hold at this level (verified in dev with Foundation + a 7B MLX
    /// model); raise further with caution.
    private static let temperature: Double = 0.85
    private static let expectedActionCount = 4
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
        let globalPersona = await MainActor.run {
            AppConfiguration.shared.chatConfig.greetingPersona
        }
        let personaInstruction =
            Self.resolvedPersona(agent: agent, global: globalPersona)
            ?? Self.defaultPersonaInstruction
        let context = buildContext(
            agent: agent,
            locale: locale,
            now: now,
            memoryHints: memoryHints,
            personaInstruction: personaInstruction
        )
        let systemPrompt = Self.buildSystemPrompt(context: context)
        let userPrompt = Self.userTriggerPrompt

        let raw = try await CoreModelService.shared.generate(
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            temperature: Self.temperature,
            maxTokens: Self.maxTokens,
            timeout: Self.timeout,
            fallbackModel: fallbackModel,
            modelOptions: ["reasoningEffort": .string("no_think")]
        )

        return try Self.parse(raw)
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

    private static let userTriggerPrompt = "Generate now. Reply with JSON only."

    private static func buildSystemPrompt(context: Context) -> String {
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
        // strict JSON contract so the contract still terminates the
        // prompt — placement matters for models that pay extra attention
        // to the last paragraph. The wording is deliberately blunt about
        // "never repeat verbatim" because chatty models love to leak
        // stored facts into the greeting line.
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

        return """
            You are the greeter for an AI assistant's empty state. Produce ONE specific greeting \
            and FOUR fresh quick-action shortcuts the user might want to try right now. \
            \(agentBlock)\(purposeBlock)
            Local time is \(context.localTimeString) (\(context.timeOfDay)). User locale: \
            \(context.localeIdentifier). Write in the user's locale language. No emoji.

            \(context.personaInstruction)\(memoryBlock)

            Output STRICT JSON only — no Markdown, no prose, no code fences — matching exactly:
            {
              "greeting": "<at most 6 words, no trailing punctuation>",
              "subtitle": "<at most 12 words, ends with a period or question mark>",
              "actions": [
                {"icon": "<one icon name>", "text": "<1-2 words, concrete, max 14 characters>", \
            "prompt": "<a partial prompt the user can finish, at most 12 words, ends with a space>"},
                ... exactly 4 entries ...
              ]
            }

            Action rules (strictly enforced):
            - Each "text" must be 1 or 2 words and read like a button label — never a sentence. \
            Hard 14-character ceiling; longer labels will be truncated.
            - Each "prompt" must reference a specific noun, person, project, or domain inferred \
            from the agent's purpose (and, when available, the user knowledge above) — never a \
            generic "something" or "an idea".
            - The four actions must span four different verbs and four different domains; do not \
            repeat verbs across actions.
            - "icon" MUST be one of: \(iconList).
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

    static func parse(_ raw: String) throws -> GenerativeGreeting {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GenerativeGreetingError.emptyResponse }
        guard let jsonString = extractJSONObject(from: trimmed) else {
            logger.warning("greeting: could not locate JSON object in response")
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
            .prefix(expectedActionCount)
            .map(sanitize(action:))
            .filter { !$0.text.isEmpty && !$0.prompt.isEmpty }

        guard actions.count == expectedActionCount else {
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
        let prompt = cap(action.prompt.trimmingCharacters(in: .whitespacesAndNewlines), words: 12)
        return AgentQuickAction(icon: icon, text: text, prompt: prompt)
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
