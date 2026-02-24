//
//  MemoryService.swift
//  osaurus
//
//  Background actor orchestrating all Core Model interactions for the memory system.
//  Routes LLM calls through ModelServiceRouter — never blocks chat.
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

    private var summaryTasks: [String: Task<Void, Never>] = [:]
    private var activeConversation: [String: String] = [:]
    private var conversationSessionDates: [String: String] = [:]

    private init() {}

    // MARK: - Record Conversation Turn

    /// Stores a conversation turn and immediately extracts memories, profile facts, and graph data.
    /// The turn is also persisted as a pending signal for session-based summary generation.
    /// Summaries are generated via debounce or when the user navigates away from the session.
    public func recordConversationTurn(
        userMessage: String,
        assistantMessage: String?,
        agentId: String,
        conversationId: String,
        sessionDate: String? = nil
    ) async {
        do {
            try db.insertPendingSignal(
                PendingSignal(
                    agentId: agentId,
                    conversationId: conversationId,
                    signalType: "conversation",
                    userMessage: userMessage,
                    assistantMessage: assistantMessage
                )
            )
        } catch {
            MemoryLogger.service.error("Failed to store conversation turn: \(error)")
        }

        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }

        let startTime = Date()
        let allExistingEntries: [MemoryEntry]
        do {
            allExistingEntries = try db.loadActiveEntries(agentId: agentId)
        } catch {
            MemoryLogger.service.error("Failed to load existing entries for agent \(agentId): \(error)")
            allExistingEntries = []
        }

        let promptEntries = Array(allExistingEntries.prefix(MemoryConfiguration.extractionPromptEntryLimit))

        let prompt = buildExtractionPrompt(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            existingEntries: promptEntries,
            sessionDate: sessionDate
        )

        do {
            let response = try await callCoreModel(prompt: prompt, systemPrompt: extractionSystemPrompt, config: config)

            let parsed = parseResponse(response)
            let entries = buildMemoryEntries(
                from: parsed.entries,
                agentId: agentId,
                conversationId: conversationId,
                model: config.coreModelIdentifier
            )

            let verifyResult = await verifyAndInsertEntries(
                entries,
                agentId: agentId,
                existingEntries: entries.isEmpty ? [] : allExistingEntries,
                config: config
            )

            insertProfileFacts(
                parsed.profileFacts,
                agentId: agentId,
                conversationId: conversationId,
                model: config.coreModelIdentifier
            )
            insertGraphData(parsed.graph, model: config.coreModelIdentifier)

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            logProcessing(
                agentId: agentId,
                taskType: "turn_extraction",
                model: config.coreModelIdentifier,
                status: "success",
                inputTokens: prompt.count / MemoryConfiguration.charsPerToken,
                outputTokens: response.count / MemoryConfiguration.charsPerToken,
                durationMs: durationMs
            )
            MemoryLogger.service.debug(
                "Turn extraction completed in \(durationMs)ms — \(entries.count) entries (kept: \(verifyResult.kept), skipped: \(verifyResult.skipped), superseded: \(verifyResult.superseded)), \(parsed.profileFacts.count) profile facts"
            )

            do {
                try checkProfileRegeneration(config: config)
            } catch {
                MemoryLogger.service.warning("Profile regeneration check failed: \(error)")
            }
        } catch {
            MemoryLogger.service.error("Turn extraction failed: \(error)")
            logProcessing(
                agentId: agentId,
                taskType: "turn_extraction",
                model: config.coreModelIdentifier,
                status: "error",
                details: error.localizedDescription
            )
        }

        // Track session date for summary generation
        if let sessionDate, !sessionDate.isEmpty {
            conversationSessionDates[conversationId] = sessionDate
        }

        // Session-change detection and summary debounce
        let previousConversation = activeConversation[agentId]
        activeConversation[agentId] = conversationId

        if let prev = previousConversation, prev != conversationId {
            summaryTasks[prev]?.cancel()
            summaryTasks[prev] = nil
            let prevAgent = agentId
            let prevDate = conversationSessionDates[prev]
            Task {
                await self.generateConversationSummary(agentId: prevAgent, conversationId: prev, sessionDate: prevDate)
            }
        }

        summaryTasks[conversationId]?.cancel()
        let debounceSeconds = config.summaryDebounceSeconds
        let capturedDate = conversationSessionDates[conversationId]
        summaryTasks[conversationId] = Task {
            try? await Task.sleep(for: .seconds(debounceSeconds))
            guard !Task.isCancelled else { return }
            await self.generateConversationSummary(
                agentId: agentId,
                conversationId: conversationId,
                sessionDate: capturedDate
            )
        }
    }

    // MARK: - Profile Regeneration

    public func regenerateProfile(config: MemoryConfiguration? = nil) async {
        let cfg: MemoryConfiguration
        if let config {
            cfg = config
        } else {
            cfg = MemoryConfigurationStore.load()
        }
        guard cfg.enabled else { return }

        MemoryLogger.service.debug("Profile regeneration starting, model: \(cfg.coreModelIdentifier)")
        let startTime = Date()

        do {
            let currentProfile = try db.loadUserProfile()
            let allContributions = try db.loadActiveContributions()
            let edits = try db.loadUserEdits()
            let contributions = allContributions.filter { $0.incorporatedIn == nil }
            MemoryLogger.service.info(
                "Profile regen: \(contributions.count) new contributions (\(allContributions.count) total), \(edits.count) edits, current version: \(currentProfile?.version ?? 0)"
            )

            let (systemPrompt, userPrompt) = buildProfileRegenerationPrompt(
                currentProfile: currentProfile,
                contributions: contributions,
                userEdits: edits
            )

            let response = try await callCoreModel(prompt: userPrompt, systemPrompt: systemPrompt, config: cfg)
            let profileText = stripPreamble(response)
            let tokenCount = max(1, profileText.count / MemoryConfiguration.charsPerToken)
            let version = (currentProfile?.version ?? 0) + 1

            let profile = UserProfile(
                content: profileText,
                tokenCount: tokenCount,
                version: version,
                model: cfg.coreModelIdentifier,
                generatedAt: Self.iso8601Formatter.string(from: Date())
            )
            try db.saveUserProfile(profile)
            do { try db.markContributionsIncorporated(version: version) } catch {
                MemoryLogger.service.warning("Failed to mark contributions incorporated: \(error)")
            }

            do {
                try db.insertProfileEvent(
                    ProfileEvent(
                        agentId: "system",
                        eventType: "regeneration",
                        content: "Profile regenerated to v\(version)",
                        model: cfg.coreModelIdentifier
                    )
                )
            } catch {
                MemoryLogger.service.warning("Failed to insert profile regeneration event: \(error)")
            }

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            logProcessing(
                agentId: "system",
                taskType: "profile_regeneration",
                model: cfg.coreModelIdentifier,
                status: "success",
                inputTokens: userPrompt.count / MemoryConfiguration.charsPerToken,
                outputTokens: response.count / MemoryConfiguration.charsPerToken,
                durationMs: durationMs
            )
            MemoryLogger.service.info("Profile regenerated to v\(version) in \(durationMs)ms (\(tokenCount) tokens)")
        } catch {
            MemoryLogger.service.error("Profile regeneration failed: \(error)")
            logProcessing(
                agentId: "system",
                taskType: "profile_regeneration",
                model: cfg.coreModelIdentifier,
                status: "error",
                details: error.localizedDescription
            )
        }
    }

    // MARK: - Startup Recovery

    /// Process orphaned pending signals from a previous session that was killed or crashed
    /// before summaries could be generated. Called once during app initialization.
    public func recoverOrphanedSignals() async {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }

        let conversations: [(agentId: String, conversationId: String)]
        do {
            conversations = try db.pendingConversations()
        } catch {
            MemoryLogger.service.warning("Startup recovery: failed to check pending signals: \(error)")
            return
        }

        guard !conversations.isEmpty else { return }
        MemoryLogger.service.info(
            "Startup recovery: processing \(conversations.count) orphaned conversation(s)"
        )
        for conv in conversations {
            await generateConversationSummary(agentId: conv.agentId, conversationId: conv.conversationId)
        }
        MemoryLogger.service.info("Startup recovery completed")
    }

    // MARK: - Manual Sync

    public func syncNow() async {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else {
            MemoryLogger.service.debug("Sync skipped — memory system is disabled")
            return
        }

        MemoryLogger.service.debug("Manual sync starting...")

        let conversations: [(agentId: String, conversationId: String)]
        do {
            conversations = try db.pendingConversations()
        } catch {
            MemoryLogger.service.error("Sync failed to load pending conversations: \(error)")
            return
        }

        if !conversations.isEmpty {
            MemoryLogger.service.info("Sync: generating summaries for \(conversations.count) conversation(s)")
            for conv in conversations {
                await generateConversationSummary(agentId: conv.agentId, conversationId: conv.conversationId)
            }
        } else {
            MemoryLogger.service.debug("Sync: no pending signals to process")
        }

        let contributionCount: Int
        do {
            contributionCount = try db.contributionCountSinceLastRegeneration()
        } catch {
            MemoryLogger.service.warning("Failed to check contribution count: \(error)")
            contributionCount = 0
        }
        if contributionCount > 0 {
            MemoryLogger.service.info("Sync: regenerating profile (\(contributionCount) unincorporated contributions)")
            await regenerateProfile(config: config)
        }

        MemoryLogger.service.info("Manual sync completed")
    }

    // MARK: - Conversation Summary Generation

    /// Flush a session's summary immediately. Called from the UI when the user navigates away.
    public func flushSession(agentId: String, conversationId: String) {
        summaryTasks[conversationId]?.cancel()
        summaryTasks[conversationId] = Task {
            await self.generateConversationSummary(agentId: agentId, conversationId: conversationId)
        }
    }

    private let summarySystemPrompt = """
        You summarize conversations concisely. \
        Output a 2-4 sentence summary capturing the key topics, decisions, and outcomes. \
        Do NOT add preamble like "Here is" or "Certainly". Output the summary directly.
        """

    private func generateConversationSummary(agentId: String, conversationId: String, sessionDate: String? = nil) async
    {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }

        let startTime = Date()
        let signals: [PendingSignal]
        do {
            signals = try db.loadPendingSignals(conversationId: conversationId)
        } catch {
            MemoryLogger.service.error("Failed to load signals for conversation \(conversationId): \(error)")
            return
        }

        guard !signals.isEmpty else {
            MemoryLogger.service.debug("No pending signals for conversation \(conversationId), skipping summary")
            return
        }

        var prompt = "Conversation turns:\n"
        for signal in signals {
            prompt += "\nUser: \(signal.userMessage)"
            if let assistant = signal.assistantMessage {
                prompt += "\nAssistant: \(assistant)"
            }
        }
        prompt += "\n\nSummarize this conversation in 2-4 sentences."

        do {
            let response = try await callCoreModel(
                prompt: prompt,
                systemPrompt: summarySystemPrompt,
                config: config
            )
            let summaryText = stripPreamble(response)
            guard !summaryText.isEmpty else {
                MemoryLogger.service.warning("Empty summary for conversation \(conversationId)")
                return
            }

            let conversationAt: String
            if let date = sessionDate, !date.isEmpty {
                conversationAt = date
            } else {
                conversationAt = Self.iso8601Formatter.string(from: Date())
            }

            let tokenCount = max(1, summaryText.count / MemoryConfiguration.charsPerToken)
            let summaryObj = ConversationSummary(
                agentId: agentId,
                conversationId: conversationId,
                summary: summaryText,
                tokenCount: tokenCount,
                model: config.coreModelIdentifier,
                conversationAt: conversationAt
            )
            do {
                try db.insertSummaryAndMarkProcessed(summaryObj)
            } catch {
                MemoryLogger.service.error("Failed to insert summary for conversation \(conversationId): \(error)")
            }
            await MemorySearchService.shared.indexSummary(summaryObj)

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            logProcessing(
                agentId: agentId,
                taskType: "conversation_summary",
                model: config.coreModelIdentifier,
                status: "success",
                inputTokens: prompt.count / MemoryConfiguration.charsPerToken,
                outputTokens: response.count / MemoryConfiguration.charsPerToken,
                durationMs: durationMs
            )
            MemoryLogger.service.info(
                "Conversation summary generated for \(conversationId) in \(durationMs)ms (\(tokenCount) tokens)"
            )
        } catch {
            MemoryLogger.service.error("Conversation summary generation failed for \(conversationId): \(error)")
            logProcessing(
                agentId: agentId,
                taskType: "conversation_summary",
                model: config.coreModelIdentifier,
                status: "error",
                details: error.localizedDescription
            )
        }

        summaryTasks[conversationId] = nil
    }

    // MARK: - Core Model Routing

    private let localServices: [ModelService] = [FoundationModelService(), MLXService.shared]

    private static let maxRetries = 3
    private static let baseRetryDelay: UInt64 = 1_000_000_000  // 1 second in nanoseconds
    private static let modelCallTimeout: TimeInterval = 60

    /// Circuit breaker state: tracks consecutive failures to avoid hammering a down service.
    private var consecutiveFailures = 0
    private var circuitOpenUntil: Date?
    private static let circuitBreakerThreshold = 5
    private static let circuitBreakerCooldown: TimeInterval = 60

    private func callCoreModel(prompt: String, systemPrompt: String? = nil, config: MemoryConfiguration) async throws
        -> String
    {
        if let openUntil = circuitOpenUntil, Date() < openUntil {
            throw MemoryServiceError.circuitBreakerOpen
        }

        let model = config.coreModelIdentifier
        let messages: [ChatMessage] =
            if let systemPrompt {
                [ChatMessage(role: "system", content: systemPrompt), ChatMessage(role: "user", content: prompt)]
            } else {
                [ChatMessage(role: "user", content: prompt)]
            }
        let params = GenerationParameters(temperature: 0.3, maxTokens: 2048)

        var lastError: Error?
        for attempt in 0 ..< Self.maxRetries {
            do {
                let result = try await withModelTimeout {
                    try await self.executeModelCall(model: model, messages: messages, params: params)
                }
                consecutiveFailures = 0
                circuitOpenUntil = nil
                return result
            } catch {
                lastError = error
                let isRetryable = !(error is MemoryServiceError) || error as? MemoryServiceError == .modelCallTimedOut
                if !isRetryable || attempt == Self.maxRetries - 1 { break }
                let delay = Self.baseRetryDelay * UInt64(1 << attempt)  // exponential: 1s, 2s, 4s
                MemoryLogger.service.warning(
                    "Core model call failed (attempt \(attempt + 1)/\(Self.maxRetries)), retrying in \(1 << attempt)s: \(error)"
                )
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        consecutiveFailures += 1
        if consecutiveFailures >= Self.circuitBreakerThreshold {
            circuitOpenUntil = Date().addingTimeInterval(Self.circuitBreakerCooldown)
            let cooldown = Int(Self.circuitBreakerCooldown)
            MemoryLogger.service.error(
                "Circuit breaker opened after \(self.consecutiveFailures) consecutive failures — cooling down for \(cooldown)s"
            )
        }

        throw lastError ?? MemoryServiceError.coreModelUnavailable(model)
    }

    private func executeModelCall(model: String, messages: [ChatMessage], params: GenerationParameters) async throws
        -> String
    {
        let remoteServices: [ModelService] = await MainActor.run {
            RemoteProviderManager.shared.connectedServices()
        }

        let route = ModelServiceRouter.resolve(
            requestedModel: model,
            services: localServices,
            remoteServices: remoteServices
        )

        switch route {
        case .service(let service, let effectiveModel):
            let promptLen = messages.last?.content?.count ?? 0
            MemoryLogger.service.debug(
                "Routing to \(service.id) (model: \(effectiveModel), prompt: \(promptLen) chars)"
            )
            return try await service.generateOneShot(
                messages: messages,
                parameters: params,
                requestedModel: model
            )
        case .none:
            let localIds = self.localServices.map(\.id)
            let remoteIds = remoteServices.map(\.id)
            MemoryLogger.service.info(
                "No service found for model '\(model)' — local: \(localIds), remote: \(remoteIds)"
            )
            throw MemoryServiceError.coreModelUnavailable(model)
        }
    }

    private func withModelTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.modelCallTimeout))
                throw MemoryServiceError.modelCallTimedOut
            }
            guard let result = try await group.next() else {
                throw MemoryServiceError.modelCallTimedOut
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Prompt Building

    private let extractionSystemPrompt = """
        You extract structured memories from conversations. \
        Respond ONLY with a valid JSON object. Never ask questions. Never refuse. \
        The JSON must have: "entries" (array of objects with "type", "content", "confidence", "tags", "valid_from"), \
        "profile_facts" (array of strings), \
        "entities" (array of objects with "name" and "type"), \
        "relationships" (array of objects with "source", "relation", "target", "confidence").
        """

    private func buildExtractionPrompt(
        userMessage: String,
        assistantMessage: String?,
        existingEntries: [MemoryEntry],
        sessionDate: String? = nil
    ) -> String {
        var prompt = ""

        if let date = sessionDate, !date.isEmpty {
            prompt += "Conversation date: \(date)\n\n"
        }

        if !existingEntries.isEmpty {
            prompt += "Existing memories (avoid duplicates, note contradictions):\n"
            for entry in existingEntries.prefix(MemoryConfiguration.extractionPromptEntryLimit) {
                prompt += "- [\(entry.type.rawValue)] \(entry.content)\n"
            }
            prompt += "\n"
        }

        prompt += "User message:\n\(userMessage)"

        if let assistant = assistantMessage {
            prompt += "\n\nAssistant response:\n\(assistant)"
        }

        prompt += """

            Extract memories as JSON with:
            - "entries": array, each with \
            "type" (fact/preference/decision/correction/commitment/relationship/skill), \
            "content" (concise statement), \
            "confidence" (0.0-1.0), \
            "tags" (keywords array), \
            "valid_from" (ISO 8601 date like "2023-05-08" if the memory is tied to a specific date, \
            or "" for timeless facts. Use the conversation date to resolve relative references \
            like "yesterday", "last week", "next month" into absolute dates.)
            - "profile_facts": array of strings — global facts about this user for their profile
            - "entities": array, each with "name" (string), "type" (person/company/place/project/tool/concept/event)
            - "relationships": array, each with "source" (entity name), \
            "relation" (verb like works_on/lives_in/uses/knows/manages/created_by/part_of), \
            "target" (entity name), "confidence" (0.0-1.0)
            """

        return prompt
    }

    private func buildProfileRegenerationPrompt(
        currentProfile: UserProfile?,
        contributions: [ProfileEvent],
        userEdits: [UserEdit]
    ) -> (system: String, user: String) {
        let system = """
            You summarize known facts about a user into a short profile. \
            Rules: Use ONLY the facts provided. Do NOT invent or assume anything not listed. \
            Do NOT use placeholders like [age] or [location]. \
            Do NOT add preamble like "Here is" or "Certainly". \
            Output the profile text directly, nothing else.
            """

        var facts: [String] = []

        for edit in userEdits {
            facts.append(edit.content)
        }
        for c in contributions {
            facts.append(c.content)
        }

        var user = ""
        if let profile = currentProfile {
            user += "Current profile:\n\(profile.content)\n\n"
        }

        user += "Known facts:\n"
        for fact in facts {
            user += "- \(fact)\n"
        }
        user += "\nCombine these facts into a brief profile. Only state what is listed above."

        return (system, user)
    }

    // MARK: - Response Parsing

    struct ExtractionParseResult {
        struct EntryData: Decodable {
            let type: String
            let content: String
            let confidence: Double?
            let tags: [String]?
            let valid_from: String?
        }

        var entries: [EntryData] = []
        var profileFacts: [String] = []
        var graph: GraphExtractionResult = GraphExtractionResult()
    }

    struct RawExtractionJSON: Decodable {
        let entries: [ExtractionParseResult.EntryData]?
        let profile_facts: [String]?
        let entities: [GraphExtractionResult.EntityData]?
        let relationships: [GraphExtractionResult.RelationshipData]?
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

        MemoryLogger.service.error("Could not extract JSON from response: \(trimmed.prefix(200))...")
        return nil
    }

    nonisolated func parseResponse(_ response: String) -> ExtractionParseResult {
        guard let data = extractJSON(from: response) else {
            MemoryLogger.service.info("parseResponse: no JSON found in response")
            return ExtractionParseResult()
        }

        if let raw = try? JSONDecoder().decode(RawExtractionJSON.self, from: data) {
            return ExtractionParseResult(
                entries: raw.entries ?? [],
                profileFacts: raw.profile_facts ?? [],
                graph: GraphExtractionResult(
                    entities: raw.entities ?? [],
                    relationships: raw.relationships ?? []
                )
            )
        }

        return parseResponseLenient(data)
    }

    /// Fallback parser that extracts as much as possible from malformed LLM JSON
    /// (e.g. confidence as string, tags as a single string, etc.).
    nonisolated func parseResponseLenient(_ data: Data) -> ExtractionParseResult {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            MemoryLogger.service.error(
                "JSON not a dictionary: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "nil")"
            )
            return ExtractionParseResult()
        }

        var result = ExtractionParseResult()

        if let rawEntries = dict["entries"] as? [[String: Any]] {
            result.entries = rawEntries.compactMap { obj in
                guard let type = obj["type"] as? String,
                    let content = obj["content"] as? String
                else { return nil }
                let confidence: Double? =
                    (obj["confidence"] as? Double)
                    ?? (obj["confidence"] as? String).flatMap(Double.init)
                let tags: [String]?
                if let arr = obj["tags"] as? [String] {
                    tags = arr
                } else if let single = obj["tags"] as? String {
                    tags = [single]
                } else {
                    tags = nil
                }
                let validFrom = obj["valid_from"] as? String
                return ExtractionParseResult.EntryData(
                    type: type,
                    content: content,
                    confidence: confidence,
                    tags: tags,
                    valid_from: validFrom
                )
            }
        }

        if let facts = dict["profile_facts"] as? [String] {
            result.profileFacts = facts
        }

        if let rawEntities = dict["entities"] as? [[String: Any]] {
            result.graph.entities = rawEntities.compactMap { obj in
                guard let name = obj["name"] as? String,
                    let type = obj["type"] as? String
                else { return nil }
                return GraphExtractionResult.EntityData(name: name, type: type)
            }
        }

        if let rawRels = dict["relationships"] as? [[String: Any]] {
            result.graph.relationships = rawRels.compactMap { obj in
                guard let source = obj["source"] as? String,
                    let relation = obj["relation"] as? String,
                    let target = obj["target"] as? String
                else { return nil }
                let confidence =
                    (obj["confidence"] as? Double)
                    ?? (obj["confidence"] as? String).flatMap(Double.init)
                return GraphExtractionResult.RelationshipData(
                    source: source,
                    relation: relation,
                    target: target,
                    confidence: confidence
                )
            }
        }

        MemoryLogger.service.info(
            "Lenient parse recovered \(result.entries.count) entries, \(result.profileFacts.count) facts, \(result.graph.entities.count) entities"
        )
        return result
    }

    private func buildMemoryEntries(
        from parsed: [ExtractionParseResult.EntryData],
        agentId: String,
        conversationId: String,
        model: String
    ) -> [MemoryEntry] {
        let entries = parsed.compactMap { entry -> MemoryEntry? in
            guard let entryType = MemoryEntryType(rawValue: entry.type) else { return nil }
            let tagsJSON: String?
            if let tags = entry.tags, !tags.isEmpty {
                tagsJSON = (try? JSONEncoder().encode(tags)).flatMap { String(data: $0, encoding: .utf8) }
            } else {
                tagsJSON = nil
            }
            return MemoryEntry(
                agentId: agentId,
                type: entryType,
                content: entry.content,
                confidence: entry.confidence ?? 0.8,
                model: model,
                sourceConversationId: conversationId,
                tagsJSON: tagsJSON,
                validFrom: entry.valid_from ?? ""
            )
        }

        MemoryLogger.service.info("Parsed \(entries.count) entries from JSON")
        return entries
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

    // MARK: - Entry & Contribution Helpers

    /// Insert parsed entries, checking each for contradictions against existing entries.
    /// Returns the number of contradictions resolved.
    private func insertEntries(
        _ entries: [MemoryEntry],
        existing: [MemoryEntry],
        existingTokens: [Set<String>]
    ) async -> Int {
        var contradictions = 0
        for entry in entries {
            let entryTokens = TextSimilarity.tokenize(entry.content)
            if let contradiction = findContradiction(
                entry: entry,
                entryTokens: entryTokens,
                existing: existing,
                existingTokens: existingTokens
            ) {
                do {
                    try db.supersedeAndInsert(
                        oldEntryId: contradiction.id,
                        newEntry: entry,
                        reason: "Contradicted by newer information"
                    )
                    await MemorySearchService.shared.removeDocument(id: contradiction.id)
                    await MemorySearchService.shared.indexMemoryEntry(entry)
                    contradictions += 1
                    MemoryLogger.service.debug("Stored entry: [\(entry.type.rawValue)] \(entry.content.prefix(80))")
                } catch {
                    MemoryLogger.service.error("Failed to supersede entry: \(error)")
                }
            } else {
                do {
                    try db.insertMemoryEntry(entry)
                    await MemorySearchService.shared.indexMemoryEntry(entry)
                    MemoryLogger.service.debug("Stored entry: [\(entry.type.rawValue)] \(entry.content.prefix(80))")
                } catch {
                    MemoryLogger.service.error("Failed to insert entry: \(error)")
                }
            }
        }
        return contradictions
    }

    /// Insert profile facts, skipping duplicates. Returns number of facts stored.
    @discardableResult
    private func insertProfileFacts(_ facts: [String], agentId: String, conversationId: String? = nil, model: String)
        -> Int
    {
        guard !facts.isEmpty else { return 0 }
        let existingContributions: [ProfileEvent]
        do {
            existingContributions = try db.loadActiveContributions()
        } catch {
            MemoryLogger.service.warning("Failed to load active contributions for dedup: \(error)")
            existingContributions = []
        }

        var stored = 0
        for fact in facts {
            let isDuplicate = existingContributions.contains {
                TextSimilarity.jaccard($0.content, fact) > MemoryConfiguration.profileFactDedupThreshold
            }
            if isDuplicate {
                MemoryLogger.service.debug("Skipping duplicate profile fact: \(fact.prefix(80))")
                continue
            }
            do {
                try db.insertProfileEvent(
                    ProfileEvent(
                        agentId: agentId,
                        conversationId: conversationId,
                        eventType: "contribution",
                        content: fact,
                        model: model
                    )
                )
                stored += 1
                MemoryLogger.service.debug("Stored profile fact: \(fact.prefix(80))")
            } catch {
                MemoryLogger.service.error("Failed to insert profile fact: \(error)")
            }
        }
        return stored
    }

    private func insertGraphData(_ graphData: GraphExtractionResult, model: String) {
        var resolved: [String: GraphEntity] = [:]

        for entityData in graphData.entities {
            do {
                let entity = try db.resolveEntity(name: entityData.name, type: entityData.type, model: model)
                resolved[entityData.name.lowercased()] = entity
            } catch {
                MemoryLogger.service.error("Failed to resolve entity '\(entityData.name)': \(error)")
            }
        }

        for relData in graphData.relationships {
            do {
                let source =
                    try resolved[relData.source.lowercased()]
                    ?? db.resolveEntity(name: relData.source, type: "unknown", model: model)
                let target =
                    try resolved[relData.target.lowercased()]
                    ?? db.resolveEntity(name: relData.target, type: "unknown", model: model)
                try db.insertRelationship(
                    sourceId: source.id,
                    targetId: target.id,
                    relation: relData.relation,
                    confidence: relData.confidence ?? 0.8,
                    model: model
                )
            } catch {
                MemoryLogger.service.error("Failed to insert relationship: \(error)")
            }
        }
    }

    private static let contradictableTypes: Set<MemoryEntryType> = [.fact, .correction, .commitment]

    nonisolated func findContradiction(
        entry: MemoryEntry,
        entryTokens: Set<String>,
        existing: [MemoryEntry],
        existingTokens: [Set<String>]
    ) -> MemoryEntry? {
        for (i, e) in existing.enumerated() {
            let typesCompatible =
                (e.type == entry.type)
                || (Self.contradictableTypes.contains(e.type) && Self.contradictableTypes.contains(entry.type))
            guard typesCompatible else { continue }
            let sim = TextSimilarity.jaccardTokenized(entryTokens, existingTokens[i])
            if sim > MemoryConfiguration.contradictionJaccardThreshold && entry.content != e.content {
                return e
            }
        }
        return nil
    }

    // MARK: - Entry Verification Pipeline

    /// Three-layer verification pipeline (all deterministic, no LLM calls).
    /// Layer 1: Jaccard > dedupThreshold, same type -> SKIP (word-overlap duplicates)
    /// Layer 2: Jaccard 0.3–dedupThreshold, compatible types -> SUPERSEDE (contradictions)
    /// Layer 3: Vector similarity > semanticDedupThreshold:
    ///   - High Jaccard with match -> SKIP (semantic duplicate)
    ///   - Low Jaccard + contradictable types -> SUPERSEDE (semantic contradiction)
    ///   - Otherwise -> KEEP
    /// Everything else -> KEEP
    ///
    /// Falls back to insertEntries (Layer 2 only) if verification is disabled.
    private func verifyAndInsertEntries(
        _ candidates: [MemoryEntry],
        agentId: String,
        existingEntries: [MemoryEntry],
        config: MemoryConfiguration
    ) async -> (kept: Int, skipped: Int, superseded: Int) {
        let existingTokens = existingEntries.map { TextSimilarity.tokenize($0.content) }

        guard config.verificationEnabled else {
            let contradictions = await insertEntries(
                candidates,
                existing: existingEntries,
                existingTokens: existingTokens
            )
            return (kept: candidates.count, skipped: 0, superseded: contradictions)
        }

        let dedupThreshold = config.verificationJaccardDedupThreshold
        let semanticDedupThreshold = config.verificationSemanticDedupThreshold

        var kept = 0
        var skipped = 0
        var superseded = 0

        for candidate in candidates {
            let candidateTokens = TextSimilarity.tokenize(candidate.content)

            // Layer 1: Near-duplicate dedup (word overlap)
            let isDuplicate = existingEntries.enumerated().contains { (i, e) in
                e.type == candidate.type
                    && TextSimilarity.jaccardTokenized(existingTokens[i], candidateTokens) > dedupThreshold
            }
            if isDuplicate {
                logVerification(candidate, decision: "skip_duplicate", layer: 1, agentId: agentId)
                skipped += 1
                continue
            }

            // Layer 2: Contradiction supersede
            if let contradiction = findContradiction(
                entry: candidate,
                entryTokens: candidateTokens,
                existing: existingEntries,
                existingTokens: existingTokens
            ) {
                do {
                    try db.supersedeAndInsert(
                        oldEntryId: contradiction.id,
                        newEntry: candidate,
                        reason: "Contradicted by newer information"
                    )
                    await MemorySearchService.shared.removeDocument(id: contradiction.id)
                    await MemorySearchService.shared.indexMemoryEntry(candidate)
                    MemoryLogger.service.debug(
                        "Stored entry (supersede): [\(candidate.type.rawValue)] \(candidate.content.prefix(80))"
                    )
                } catch {
                    MemoryLogger.service.error("Failed to supersede entry: \(error)")
                }
                logVerification(candidate, decision: "supersede", layer: 2, agentId: agentId)
                superseded += 1
                continue
            }

            // Layer 3: Semantic similarity — distinguish duplicates from contradictions
            let similar = await MemorySearchService.shared.searchMemoryEntriesWithScores(
                query: candidate.content,
                agentId: agentId,
                topK: 1
            )

            if let topMatch = similar.first, topMatch.score >= semanticDedupThreshold {
                let jaccardWithMatch = TextSimilarity.jaccard(candidate.content, topMatch.entry.content)
                let isContradictable =
                    Self.contradictableTypes.contains(candidate.type)
                    && Self.contradictableTypes.contains(topMatch.entry.type)

                if jaccardWithMatch >= dedupThreshold {
                    logVerification(candidate, decision: "skip_semantic_dup", layer: 3, agentId: agentId)
                    skipped += 1
                } else if isContradictable && candidate.content != topMatch.entry.content {
                    do {
                        try db.supersedeAndInsert(
                            oldEntryId: topMatch.entry.id,
                            newEntry: candidate,
                            reason: "Semantically contradicted by newer information"
                        )
                        await MemorySearchService.shared.removeDocument(id: topMatch.entry.id)
                        await MemorySearchService.shared.indexMemoryEntry(candidate)
                        MemoryLogger.service.debug(
                            "Stored entry (semantic_supersede): [\(candidate.type.rawValue)] \(candidate.content.prefix(80))"
                        )
                    } catch {
                        MemoryLogger.service.error("Failed to supersede entry: \(error)")
                    }
                    logVerification(candidate, decision: "supersede_semantic", layer: 3, agentId: agentId)
                    superseded += 1
                } else {
                    await persistEntry(candidate, tag: "novel")
                    logVerification(candidate, decision: "keep_novel", layer: 0, agentId: agentId)
                    kept += 1
                }
            } else {
                await persistEntry(candidate, tag: "novel")
                logVerification(candidate, decision: "keep_novel", layer: 0, agentId: agentId)
                kept += 1
            }
        }

        if config.maxEntriesPerAgent > 0 {
            do {
                let archived = try db.archiveExcessEntries(agentId: agentId, maxEntries: config.maxEntriesPerAgent)
                if archived > 0 {
                    MemoryLogger.service.info("Archived \(archived) excess entries for agent \(agentId)")
                }
            } catch {
                MemoryLogger.service.warning("Failed to archive excess entries: \(error)")
            }
        }

        return (kept: kept, skipped: skipped, superseded: superseded)
    }

    private func persistEntry(_ entry: MemoryEntry, tag: String) async {
        do {
            try db.insertMemoryEntry(entry)
            await MemorySearchService.shared.indexMemoryEntry(entry)
            MemoryLogger.service.debug("Stored entry (\(tag)): [\(entry.type.rawValue)] \(entry.content.prefix(80))")
        } catch {
            MemoryLogger.service.error("Failed to insert entry: \(error)")
        }
    }

    private func logVerification(
        _ entry: MemoryEntry,
        decision: String,
        layer: Int,
        agentId: String
    ) {
        do {
            try db.insertMemoryEvent(
                entryId: entry.id,
                eventType: "verification",
                agentId: agentId,
                model: nil,
                reason: "layer_\(layer):\(decision)"
            )
        } catch {
            MemoryLogger.service.warning("Failed to log verification event: \(error)")
        }
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
            MemoryLogger.service.warning("Failed to write processing log (\(taskType)/\(status)): \(error)")
        }
    }

    // MARK: - Profile Threshold Check

    private func checkProfileRegeneration(config: MemoryConfiguration) throws {
        let count = try db.contributionCountSinceLastRegeneration()
        let hasProfile: Bool
        do { hasProfile = try db.loadUserProfile() != nil } catch {
            MemoryLogger.service.warning("Failed to check user profile: \(error)")
            hasProfile = false
        }
        let threshold = hasProfile ? config.profileRegenerateThreshold : 1

        if count >= threshold {
            MemoryLogger.service.info(
                "Profile regeneration triggered (\(count) contributions since last regen, threshold: \(threshold), existing profile: \(hasProfile))"
            )
            let cfg = config
            Task { await self.regenerateProfile(config: cfg) }
        }
    }
}

// MARK: - Errors

enum MemoryServiceError: Error, LocalizedError, Equatable {
    case coreModelUnavailable(String)
    case circuitBreakerOpen
    case modelCallTimedOut

    var errorDescription: String? {
        switch self {
        case .coreModelUnavailable(let model):
            return "Core model '\(model)' is not available for memory processing"
        case .circuitBreakerOpen:
            return "Memory service temporarily unavailable (too many recent failures)"
        case .modelCallTimedOut:
            return "Model call timed out"
        }
    }
}
