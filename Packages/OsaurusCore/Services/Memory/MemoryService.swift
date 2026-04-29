//
//  MemoryService.swift
//  osaurus
//
//  v2 write pipeline: deferred, debounced, single-call distillation.
//
//  Public entry points:
//    - bufferTurn(...)           — no LLM; just persists a pending signal and
//                                  re-arms the per-conversation debounce
//    - flushSession(...)         — forces immediate distillation for a session
//                                  (used by chat nav-away and HTTP `flush=true`)
//    - syncNow()                 — distills every pending conversation
//    - recoverOrphanedSignals()  — startup hook; same as syncNow with a guard
//
//  Distillation is one LLM call per session, not per turn. The prompt is
//  schema-constrained: episode digest + entities + identity delta + pinned
//  candidates, all in a single response.
//

import Foundation
import os

public actor MemoryService {
    public static let shared = MemoryService()

    private let db = MemoryDatabase.shared

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }

    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var activeConversation: [String: String] = [:]
    private var conversationSessionDates: [String: String] = [:]

    private init() {}

    // MARK: - Buffer Turn (no LLM)

    /// Buffer a conversation turn for later distillation. This is the hot
    /// path for every chat turn — no LLM call, no extraction, no scoring.
    /// The debounce timer is (re)armed; if no new turn arrives within
    /// `summaryDebounceSeconds`, the session is distilled. Switching to a
    /// different conversation flushes the previous session immediately.
    public func bufferTurn(
        userMessage: String,
        assistantMessage: String?,
        agentId: String,
        conversationId: String,
        sessionDate: String? = nil
    ) async {
        guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }

        do {
            try db.insertPendingSignal(
                PendingSignal(
                    agentId: agentId,
                    conversationId: conversationId,
                    userMessage: userMessage,
                    assistantMessage: assistantMessage
                )
            )
        } catch {
            MemoryLogger.service.error("Failed to buffer turn: \(error)")
            return
        }

        if let sessionDate, !sessionDate.isEmpty {
            conversationSessionDates[conversationId] = sessionDate
        }

        // Session change → flush the previous conversation.
        let previous = activeConversation[agentId]
        activeConversation[agentId] = conversationId
        if let prev = previous, prev != conversationId {
            debounceTasks[prev]?.cancel()
            debounceTasks[prev] = nil
            let prevDate = conversationSessionDates[prev]
            Task { await self.distillSession(agentId: agentId, conversationId: prev, sessionDate: prevDate) }
        }

        guard config.extractionMode == .sessionEnd else { return }

        // Re-arm debounce for this session.
        debounceTasks[conversationId]?.cancel()
        let debounceSeconds = config.summaryDebounceSeconds
        let capturedDate = conversationSessionDates[conversationId]
        debounceTasks[conversationId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(debounceSeconds))
            guard !Task.isCancelled else { return }
            await self?.distillSession(
                agentId: agentId,
                conversationId: conversationId,
                sessionDate: capturedDate
            )
        }
    }

    /// Force immediate distillation for a session. Called from the chat UI
    /// when the user navigates away.
    public func flushSession(agentId: String, conversationId: String) {
        debounceTasks[conversationId]?.cancel()
        debounceTasks[conversationId] = Task { [weak self] in
            await self?.distillSession(agentId: agentId, conversationId: conversationId)
        }
    }

    /// Distill every pending conversation and run identity regeneration if needed.
    public func syncNow() async {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }
        guard await hasCoreModel() else {
            // .info (not .debug) so support can see this in Console
            // without enabling debug logs. Background consolidation
            // has no per-turn chat model to fall back to, so it stays
            // opt-in via Settings → Core Model.
            MemoryLogger.service.info(
                "syncNow: no core model configured; memory consolidation skipped (configure one in Settings → Core Model)"
            )
            return
        }

        let conversations: [(agentId: String, conversationId: String)]
        do { conversations = try db.pendingConversations() } catch {
            MemoryLogger.service.error("syncNow: failed to load pending conversations: \(error)")
            return
        }

        for conv in conversations {
            await distillSession(agentId: conv.agentId, conversationId: conv.conversationId)
        }
    }

    /// Startup hook: drain anything that didn't get distilled before the
    /// previous launch was killed. Skips when cold-loading the core model
    /// would peg the GPU on app open (see `canDistillCheaply`).
    public func recoverOrphanedSignals() async {
        guard await canDistillCheaply() else {
            MemoryLogger.service.info(
                "recoverOrphanedSignals: deferring — core model not resident, avoiding cold load on launch"
            )
            return
        }
        await syncNow()
    }

    /// Foundation/remote: always cheap. Local MLX: cheap iff already
    /// cached or small (<= `coldLoadParamBudgetBillions`). Unknown
    /// param count is treated as large
    private func canDistillCheaply() async -> Bool {
        guard let modelId = await MainActor.run(body: { ChatConfigurationStore.load().coreModelIdentifier }) else {
            return false
        }
        guard
            let local = ModelManager.discoverLocalModels()
                .first(where: {
                    $0.id.caseInsensitiveCompare(modelId) == .orderedSame
                        || $0.name.caseInsensitiveCompare(modelId) == .orderedSame
                })
        else { return true }

        if await ModelRuntime.shared.isResident(name: local.name) { return true }
        if let params = local.parameterCountBillions, params <= Self.coldLoadParamBudgetBillions {
            return true
        }
        return false
    }

    private static let coldLoadParamBudgetBillions: Double = 2.0

    // MARK: - Distillation (one LLM call per session)

    private func distillSession(
        agentId: String,
        conversationId: String,
        sessionDate: String? = nil
    ) async {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }
        guard await hasCoreModel() else {
            MemoryLogger.service.info(
                "distill: no core model configured; signals stay pending (configure one in Settings → Core Model)"
            )
            return
        }

        let coreModelId = await coreModelIdentifier()
        let startTime = Date()

        let signals: [PendingSignal]
        do { signals = try db.loadPendingSignals(conversationId: conversationId) } catch {
            MemoryLogger.service.error("distill: failed to load signals for \(conversationId): \(error)")
            return
        }
        guard !signals.isEmpty else { return }

        // Cheap pre-LLM gate: combined char count must clear novelty floor.
        let combinedChars = signals.reduce(0) {
            $0 + $1.userMessage.count + ($1.assistantMessage?.count ?? 0)
        }
        guard combinedChars >= MemoryConfiguration.distillNoveltyMinChars else {
            try? db.markSignalsProcessed(conversationId: conversationId)
            MemoryLogger.service.debug(
                "distill: skipping low-novelty session \(conversationId) (\(combinedChars) chars)"
            )
            debounceTasks[conversationId] = nil
            return
        }

        let identity = (try? db.loadIdentity()) ?? Identity()
        let recentEpisodes =
            (try? db.loadEpisodes(agentId: agentId, days: 90, limit: MemoryConfiguration.distillContextEpisodeCount))
            ?? []

        let resolvedDate: String = {
            if let sessionDate, !sessionDate.isEmpty { return sessionDate }
            return Self.iso8601Now()
        }()

        let prompt = buildDistillPrompt(
            signals: signals,
            identity: identity,
            recentEpisodes: recentEpisodes,
            sessionDate: resolvedDate
        )

        do {
            let response = try await CoreModelService.shared.generate(
                prompt: prompt,
                systemPrompt: distillSystemPrompt
            )
            let parsed = parseDistillResponse(response)
            guard let episode = parsed.episode else {
                MemoryLogger.service.warning("distill: no episode produced for \(conversationId)")
                logProcessing(
                    agentId: agentId,
                    taskType: "distill",
                    model: coreModelId,
                    status: "empty",
                    durationMs: Int(Date().timeIntervalSince(startTime) * 1000)
                )
                return
            }

            let summaryText = stripPreamble(episode.summary)
            guard !summaryText.isEmpty else {
                MemoryLogger.service.warning("distill: empty summary for \(conversationId)")
                return
            }

            let tokenCount = max(1, summaryText.count / MemoryConfiguration.charsPerToken)
            let entitiesCSV = parsed.entities.joined(separator: ", ")
            let topicsCSV = episode.topics.joined(separator: ", ")
            let decisions = episode.decisions.joined(separator: "\n")
            let actionItems = episode.actionItems.joined(separator: "\n")
            let salience = max(0, min(1, episode.salience ?? 0.5))

            let ep = Episode(
                agentId: agentId,
                conversationId: conversationId,
                summary: summaryText,
                topicsCSV: topicsCSV,
                entitiesCSV: entitiesCSV,
                decisions: decisions,
                actionItems: actionItems,
                salience: salience,
                tokenCount: tokenCount,
                model: coreModelId,
                conversationAt: resolvedDate
            )

            let episodeId: Int
            do {
                episodeId = try db.insertEpisodeAndMarkProcessed(ep)
            } catch {
                MemoryLogger.service.error("distill: failed to insert episode for \(conversationId): \(error)")
                return
            }

            // Index the episode for search.
            var stored = ep
            stored.id = episodeId
            await MemorySearchService.shared.indexEpisode(stored)

            // Promote pinned candidates that are explicit, novel, and not already represented.
            let storedPinned = await persistPinnedCandidates(
                parsed.pinnedCandidates,
                agentId: agentId,
                episodeId: episodeId
            )

            // Apply identity delta: the distillation may declare new
            // identity-grade facts. We append them to overrides only when the
            // model marked them as identity-relevant.
            if !parsed.identityFacts.isEmpty {
                applyIdentityDelta(
                    facts: parsed.identityFacts,
                    currentIdentity: identity,
                    model: coreModelId
                )
            }

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            logProcessing(
                agentId: agentId,
                taskType: "distill",
                model: coreModelId,
                status: "success",
                inputTokens: prompt.count / MemoryConfiguration.charsPerToken,
                outputTokens: response.count / MemoryConfiguration.charsPerToken,
                durationMs: durationMs
            )
            MemoryLogger.service.info(
                "distill: \(conversationId) → episode #\(episodeId), \(storedPinned) pinned, \(parsed.identityFacts.count) identity facts (\(durationMs)ms)"
            )

            await MemoryContextAssembler.shared.invalidateCache(agentId: agentId)
        } catch {
            MemoryLogger.service.error("distill: failed for \(conversationId): \(error)")
            logProcessing(
                agentId: agentId,
                taskType: "distill",
                model: coreModelId,
                status: "error",
                details: error.localizedDescription
            )
        }

        debounceTasks[conversationId] = nil
    }

    // MARK: - Pinned Candidates

    /// Persist pinned candidates that pass the dedup check. Uses Jaccard
    /// against existing pinned facts (cheap, deterministic) — the
    /// consolidator handles deeper merging later.
    private func persistPinnedCandidates(
        _ candidates: [DistillResult.PinnedCandidate],
        agentId: String,
        episodeId: Int
    ) async -> Int {
        guard !candidates.isEmpty else { return 0 }

        let existing = (try? db.loadPinnedFacts(agentId: agentId, limit: 200)) ?? []
        let existingTokens = existing.map { TextSimilarity.tokenize($0.content) }

        var stored = 0
        for candidate in candidates {
            let trimmed = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 5 else { continue }

            let candTokens = TextSimilarity.tokenize(trimmed)
            let isDuplicate = existing.enumerated().contains { (i, _) in
                TextSimilarity.jaccardTokenized(existingTokens[i], candTokens) > 0.6
            }
            if isDuplicate {
                MemoryLogger.service.debug("pinned: skip dup '\(trimmed.prefix(60))'")
                continue
            }

            let salience = max(0, min(1, candidate.salience ?? 0.6))
            let fact = PinnedFact(
                agentId: agentId,
                content: trimmed,
                salience: salience,
                sourceCount: 1,
                sourceEpisodeId: episodeId,
                tagsCSV: candidate.tags.isEmpty ? nil : candidate.tags.joined(separator: ", ")
            )
            do {
                try db.insertPinnedFact(fact)
                await MemorySearchService.shared.indexPinnedFact(fact)
                stored += 1
            } catch {
                MemoryLogger.service.error("pinned: insert failed: \(error)")
            }
        }
        return stored
    }

    // MARK: - Identity Delta

    private func applyIdentityDelta(
        facts: [String],
        currentIdentity: Identity,
        model: String
    ) {
        let existing = Set(currentIdentity.overrides.map { $0.lowercased() })
        var updated = currentIdentity
        var added = 0
        for raw in facts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !existing.contains(trimmed.lowercased()) else { continue }
            updated.overrides.append(trimmed)
            added += 1
        }
        guard added > 0 else { return }
        updated.model = model
        updated.generatedAt = Self.iso8601Now()
        do { try db.saveIdentity(updated) } catch {
            MemoryLogger.service.error("identity: save failed: \(error)")
        }
        MemoryLogger.service.info("identity: appended \(added) new fact(s)")
    }

    // MARK: - Core Model Identifier

    private func coreModelIdentifier() async -> String {
        await MainActor.run { ChatConfigurationStore.load().coreModelIdentifier ?? "none" }
    }

    private func hasCoreModel() async -> Bool {
        await MainActor.run { ChatConfigurationStore.load().coreModelIdentifier != nil }
    }

    // MARK: - Prompt Building

    private let distillSystemPrompt = """
        You distill a chat session into a structured digest. \
        Respond ONLY with a valid JSON object (no preamble, no code fences, no commentary). \
        The JSON must have these top-level keys: \
        "episode" (object with "summary" string, "topics" string array, "decisions" string array, \
        "action_items" string array, "salience" number 0-1), \
        "entities" (string array of person/project/place/tool names mentioned), \
        "pinned_candidates" (array of {"content": string, "salience": number 0-1, "tags": string array} for \
        facts worth remembering long-term: explicit user identity facts, strong preferences, decisions the \
        user clearly committed to. Be conservative — most sessions yield 0-2 candidates.), \
        "identity_facts" (string array of facts that should appear in the user's identity profile, e.g. \
        "User's name is X" or "User works at Y". Empty when nothing identity-relevant came up.). \
        Salience scoring: 0.9+ = critical identity/decision, 0.6-0.8 = clear preference, \
        0.3-0.5 = casual mention, <0.3 = transient chitchat. \
        Do NOT invent facts. Use only what the conversation actually contains.
        """

    private func buildDistillPrompt(
        signals: [PendingSignal],
        identity: Identity,
        recentEpisodes: [Episode],
        sessionDate: String
    ) -> String {
        var prompt = "Conversation date: \(sessionDate)\n\n"

        if !identity.content.isEmpty {
            prompt += "What we already know about the user:\n\(identity.content)\n\n"
        }

        if !recentEpisodes.isEmpty {
            prompt += "Recent past sessions (for cross-session continuity):\n"
            for ep in recentEpisodes {
                prompt += "- [\(ep.conversationAt.prefix(10))] \(ep.summary.prefix(160))\n"
            }
            prompt += "\n"
        }

        prompt += "Conversation turns:\n"
        for signal in signals {
            prompt += "\nUser: \(signal.userMessage)"
            if let asst = signal.assistantMessage {
                prompt += "\nAssistant: \(asst)"
            }
        }

        prompt += "\n\nDistill this session into the JSON digest."
        return prompt
    }

    // MARK: - Response Parsing

    struct DistillResult {
        struct EpisodeData {
            var summary: String
            var topics: [String]
            var decisions: [String]
            var actionItems: [String]
            var salience: Double?
        }
        struct PinnedCandidate {
            var content: String
            var salience: Double?
            var tags: [String]
        }

        var episode: EpisodeData?
        var entities: [String] = []
        var pinnedCandidates: [PinnedCandidate] = []
        var identityFacts: [String] = []
    }

    nonisolated func extractJSON(from response: String) -> Data? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return data
        }

        let fencePattern = #"```(?:json)?\s*\n?([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: fencePattern),
            let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let contentRange = Range(match.range(at: 1), in: trimmed)
        {
            let jsonStr = String(trimmed[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonStr.data(using: .utf8),
                (try? JSONSerialization.jsonObject(with: data)) != nil
            {
                return data
            }
        }

        if let openIdx = trimmed.firstIndex(of: "{"),
            let closeIdx = trimmed.lastIndex(of: "}"), closeIdx > openIdx
        {
            let jsonStr = String(trimmed[openIdx ... closeIdx])
            if let data = jsonStr.data(using: .utf8),
                (try? JSONSerialization.jsonObject(with: data)) != nil
            {
                return data
            }
        }

        return nil
    }

    nonisolated func parseDistillResponse(_ response: String) -> DistillResult {
        guard let data = extractJSON(from: response),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            MemoryLogger.service.error(
                "distill parse: no JSON in response: \(response.prefix(200))"
            )
            return DistillResult()
        }

        var result = DistillResult()

        if let epDict = dict["episode"] as? [String: Any] {
            let summary = (epDict["summary"] as? String) ?? ""
            let topics = (epDict["topics"] as? [String]) ?? []
            let decisions = (epDict["decisions"] as? [String]) ?? []
            let actions = (epDict["action_items"] as? [String]) ?? []
            let salience: Double? =
                (epDict["salience"] as? Double)
                ?? (epDict["salience"] as? String).flatMap(Double.init)
            if !summary.isEmpty {
                result.episode = DistillResult.EpisodeData(
                    summary: summary,
                    topics: topics,
                    decisions: decisions,
                    actionItems: actions,
                    salience: salience
                )
            }
        }

        if let entities = dict["entities"] as? [String] {
            result.entities = entities.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        if let pinned = dict["pinned_candidates"] as? [[String: Any]] {
            result.pinnedCandidates = pinned.compactMap { obj in
                guard let content = obj["content"] as? String, !content.isEmpty else { return nil }
                let salience: Double? =
                    (obj["salience"] as? Double)
                    ?? (obj["salience"] as? String).flatMap(Double.init)
                let tags: [String]
                if let arr = obj["tags"] as? [String] {
                    tags = arr
                } else if let single = obj["tags"] as? String {
                    tags = [single]
                } else {
                    tags = []
                }
                return DistillResult.PinnedCandidate(
                    content: content,
                    salience: salience,
                    tags: tags
                )
            }
        }

        if let facts = dict["identity_facts"] as? [String] {
            result.identityFacts = facts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        return result
    }

    nonisolated func stripPreamble(_ response: String) -> String {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)

        let preamblePatterns = [
            #"^(?:certainly|sure|of course|here(?:'s| is| are))[!.,:]?\s*"#,
            #"^here is (?:a |the )?(?:profile|description|summary)[^:]*:\s*"#,
        ]
        for pattern in preamblePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range) {
                    let matchEnd = Range(match.range, in: text)!.upperBound
                    text = String(text[matchEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return text
    }

    // MARK: - Processing Log Helper

    private func logProcessing(
        agentId: String,
        taskType: String,
        model: String,
        status: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        durationMs: Int = 0,
        details: String? = nil
    ) {
        do {
            try db.insertProcessingLog(
                agentId: agentId,
                taskType: taskType,
                model: model,
                status: status,
                details: details,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                durationMs: durationMs
            )
        } catch {
            MemoryLogger.service.warning("Failed to write processing log: \(error)")
        }
    }
}
