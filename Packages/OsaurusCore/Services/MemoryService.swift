//
//  MemoryService.swift
//  osaurus
//
//  Background actor orchestrating all Core Model interactions for the memory system.
//  Routes LLM calls through ModelServiceRouter — never blocks chat.
//

import Foundation

public actor MemoryService {
    public static let shared = MemoryService()

    private let db = MemoryDatabase.shared

    private init() {}

    // MARK: - Path 1: Immediate Signal Processing

    public func processImmediateSignals(
        signals: [SignalType],
        userMessage: String,
        assistantMessage: String?,
        agentId: String,
        conversationId: String
    ) async {
        let config = await MainActor.run { MemoryConfigurationStore.load() }
        guard config.enabled else { return }

        let signalNames = signals.map(\.rawValue).joined(separator: ", ")
        print("[Memory] Immediate extraction starting — signals: [\(signalNames)], agent: \(agentId), model: \(config.coreModelIdentifier)")

        let startTime = Date()

        for signal in signals {
            do {
                try db.insertPendingSignal(PendingSignal(
                    agentId: agentId,
                    conversationId: conversationId,
                    signalType: signal.rawValue,
                    userMessage: userMessage,
                    assistantMessage: assistantMessage
                ))
            } catch {
                print("[Memory] Failed to insert pending signal: \(error)")
            }
        }

        let existingEntries = (try? db.loadActiveEntries(agentId: agentId)) ?? []

        let prompt = buildExtractionPrompt(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            signals: signals,
            agentId: agentId,
            existingEntries: existingEntries
        )

        do {
            let response = try await callCoreModel(prompt: prompt, systemPrompt: extractionSystemPrompt, config: config)
            print("[Memory] Core model responded (\(response.count) chars)")

            let entries = parseExtractionResponse(response, agentId: agentId, conversationId: conversationId, model: config.coreModelIdentifier)
            var contradictions = 0
            for entry in entries {
                if let contradiction = findContradiction(entry: entry, existing: existingEntries) {
                    do {
                        try db.supersede(entryId: contradiction.id, by: entry.id, reason: "Contradicted by newer information")
                        await MemorySearchService.shared.removeDocument(id: contradiction.id)
                        contradictions += 1
                    } catch {
                        print("[Memory] Failed to supersede entry: \(error)")
                    }
                }
                do {
                    try db.insertMemoryEntry(entry)
                    await MemorySearchService.shared.indexMemoryEntry(entry)
                    print("[Memory] Stored entry: [\(entry.type.rawValue)] \"\(entry.content.prefix(80))\"")
                } catch {
                    print("[Memory] Failed to insert entry: \(error)")
                }
            }

            let profileFacts = parseProfileContributions(response)
            for fact in profileFacts {
                if isDuplicateContribution(fact) {
                    print("[Memory] Skipping duplicate profile fact: \"\(fact.prefix(80))\"")
                    continue
                }
                do {
                    try db.insertProfileEvent(ProfileEvent(
                        agentId: agentId,
                        conversationId: conversationId,
                        eventType: "contribution",
                        content: fact,
                        model: config.coreModelIdentifier
                    ))
                    print("[Memory] Stored profile fact: \"\(fact.prefix(80))\"")
                } catch {
                    print("[Memory] Failed to insert profile fact: \(error)")
                }
            }

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            try? db.insertProcessingLog(
                agentId: agentId, taskType: "immediate_extraction",
                model: config.coreModelIdentifier, status: "success",
                inputTokens: prompt.count / 4, outputTokens: response.count / 4,
                durationMs: durationMs
            )
            print("[Memory] Immediate extraction completed in \(durationMs)ms — \(entries.count) entries (\(contradictions) contradictions), \(profileFacts.count) profile facts")

            do { try db.markSignalsProcessed(agentId: agentId) }
            catch { print("[Memory] Failed to mark signals processed: \(error)") }

            try? await checkProfileRegeneration(config: config)
        } catch {
            print("[Memory] Immediate extraction failed: \(error)")
            try? db.insertProcessingLog(
                agentId: agentId, taskType: "immediate_extraction",
                model: config.coreModelIdentifier, status: "error",
                details: error.localizedDescription
            )
        }
    }

    // MARK: - Path 2: Post-Activity Processing

    public func processPostActivity(agentId: String) async {
        let config = await MainActor.run { MemoryConfigurationStore.load() }
        guard config.enabled else { return }

        print("[Memory] Post-activity processing starting for agent: \(agentId), model: \(config.coreModelIdentifier)")
        let startTime = Date()

        do {
            try db.markAgentProcessing(agentId: agentId, status: "processing")

            let pendingSignals = try db.loadPendingSignals(agentId: agentId)
            let existingEntries = try db.loadActiveEntries(agentId: agentId)
            print("[Memory] Post-activity: \(pendingSignals.count) pending signals, \(existingEntries.count) existing entries")

            guard !pendingSignals.isEmpty else {
                print("[Memory] Post-activity: no pending signals, skipping")
                try? db.markAgentProcessing(agentId: agentId, status: "idle")
                return
            }

            let prompt = buildPostActivityPrompt(
                pendingSignals: pendingSignals,
                existingEntries: existingEntries,
                agentId: agentId
            )

            let response = try await callCoreModel(prompt: prompt, systemPrompt: extractionSystemPrompt, config: config)
            print("[Memory] Post-activity: core model responded (\(response.count) chars)")

            let extracted = parseExtractionResponse(response, agentId: agentId, conversationId: pendingSignals.first?.conversationId ?? "", model: config.coreModelIdentifier)
            var contradictions = 0
            for entry in extracted {
                if let contradiction = findContradiction(entry: entry, existing: existingEntries) {
                    do {
                        try db.supersede(entryId: contradiction.id, by: entry.id, reason: "Contradicted by newer information")
                        await MemorySearchService.shared.removeDocument(id: contradiction.id)
                        contradictions += 1
                    } catch {
                        print("[Memory] Failed to supersede entry: \(error)")
                    }
                }
                do {
                    try db.insertMemoryEntry(entry)
                    await MemorySearchService.shared.indexMemoryEntry(entry)
                } catch {
                    print("[Memory] Failed to insert entry during post-activity: \(error)")
                }
            }

            let profileFacts = parseProfileContributions(response)
            for fact in profileFacts {
                if isDuplicateContribution(fact) {
                    print("[Memory] Skipping duplicate profile fact: \"\(fact.prefix(80))\"")
                    continue
                }
                do {
                    try db.insertProfileEvent(ProfileEvent(
                        agentId: agentId,
                        eventType: "contribution",
                        content: fact,
                        model: config.coreModelIdentifier
                    ))
                } catch {
                    print("[Memory] Failed to insert profile fact during post-activity: \(error)")
                }
            }

            let hasSummary = parseSummary(response) != nil
            if let summary = parseSummary(response) {
                let tokenCount = max(1, summary.count / 4)
                let conversationId = pendingSignals.first?.conversationId ?? agentId
                let summaryObj = ConversationSummary(
                    agentId: agentId,
                    conversationId: conversationId,
                    summary: summary,
                    tokenCount: tokenCount,
                    model: config.coreModelIdentifier,
                    conversationAt: ISO8601DateFormatter().string(from: Date())
                )
                try? db.insertSummary(summaryObj)
                await MemorySearchService.shared.indexSummary(summaryObj)
            }

            do { try db.markSignalsProcessed(agentId: agentId) }
            catch { print("[Memory] Failed to mark signals processed: \(error)") }
            try? db.markAgentProcessing(agentId: agentId, status: "idle")

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            try? db.insertProcessingLog(
                agentId: agentId, taskType: "post_activity",
                model: config.coreModelIdentifier, status: "success",
                inputTokens: prompt.count / 4, outputTokens: response.count / 4,
                durationMs: durationMs
            )
            print("[Memory] Post-activity completed in \(durationMs)ms — \(extracted.count) entries (\(contradictions) contradictions), \(profileFacts.count) profile facts, summary: \(hasSummary)")

            try? await checkProfileRegeneration(config: config)
        } catch {
            print("[Memory] Post-activity processing failed for \(agentId): \(error)")
            try? db.markAgentProcessing(agentId: agentId, status: "idle")
            try? db.insertProcessingLog(
                agentId: agentId, taskType: "post_activity",
                model: config.coreModelIdentifier, status: "error",
                details: error.localizedDescription
            )
        }
    }

    // MARK: - Profile Regeneration

    public func regenerateProfile(config: MemoryConfiguration? = nil) async {
        let cfg: MemoryConfiguration
        if let config {
            cfg = config
        } else {
            cfg = await MainActor.run { MemoryConfigurationStore.load() }
        }
        guard cfg.enabled else { return }

        print("[Memory] Profile regeneration starting, model: \(cfg.coreModelIdentifier)")
        let startTime = Date()

        do {
            let currentProfile = try db.loadUserProfile()
            let allContributions = try db.loadActiveContributions()
            let edits = try db.loadUserEdits()
            let contributions = allContributions.filter { $0.incorporatedIn == nil }
            print("[Memory] Profile regen: \(contributions.count) new contributions (\(allContributions.count) total), \(edits.count) edits, current version: \(currentProfile?.version ?? 0)")

            let (systemPrompt, userPrompt) = buildProfileRegenerationPrompt(
                currentProfile: currentProfile,
                contributions: contributions,
                userEdits: edits,
                maxTokens: cfg.profileMaxTokens
            )

            let response = try await callCoreModel(prompt: userPrompt, systemPrompt: systemPrompt, config: cfg)
            let profileText = stripPreamble(response)
            let tokenCount = max(1, profileText.count / 4)
            let version = (currentProfile?.version ?? 0) + 1

            let profile = UserProfile(
                content: profileText,
                tokenCount: tokenCount,
                version: version,
                model: cfg.coreModelIdentifier,
                generatedAt: ISO8601DateFormatter().string(from: Date())
            )
            try db.saveUserProfile(profile)
            try? db.markContributionsIncorporated(version: version)

            try? db.insertProfileEvent(ProfileEvent(
                agentId: "system",
                eventType: "regeneration",
                content: "Profile regenerated to v\(version)",
                model: cfg.coreModelIdentifier
            ))

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            try? db.insertProcessingLog(
                agentId: "system", taskType: "profile_regeneration",
                model: cfg.coreModelIdentifier, status: "success",
                inputTokens: userPrompt.count / 4, outputTokens: response.count / 4,
                durationMs: durationMs
            )
            print("[Memory] Profile regenerated to v\(version) in \(durationMs)ms (\(tokenCount) tokens)")
        } catch {
            print("[Memory] Profile regeneration failed: \(error)")
            try? db.insertProcessingLog(
                agentId: "system", taskType: "profile_regeneration",
                model: cfg.coreModelIdentifier, status: "error",
                details: error.localizedDescription
            )
        }
    }

    // MARK: - Manual Sync

    public func syncNow() async {
        let config = await MainActor.run { MemoryConfigurationStore.load() }
        guard config.enabled else {
            print("[Memory] Sync skipped — memory system is disabled")
            return
        }

        print("[Memory] Manual sync starting...")

        let agentIds: [String]
        do {
            agentIds = try db.agentsWithPendingSignals()
        } catch {
            print("[Memory] Sync failed to load pending agents: \(error)")
            return
        }

        if !agentIds.isEmpty {
            print("[Memory] Sync: processing \(agentIds.count) agent(s): \(agentIds)")
            for agentId in agentIds {
                await processPostActivity(agentId: agentId)
            }
        } else {
            print("[Memory] Sync: no pending signals to process")
        }

        let contributionCount = (try? db.contributionCountSinceLastRegeneration()) ?? 0
        if contributionCount > 0 {
            print("[Memory] Sync: regenerating profile (\(contributionCount) unincorporated contributions)")
            await regenerateProfile(config: config)
        }

        print("[Memory] Manual sync completed")
    }

    // MARK: - Core Model Routing

    private let localServices: [ModelService] = [FoundationModelService(), MLXService.shared]

    private func callCoreModel(prompt: String, systemPrompt: String? = nil, config: MemoryConfiguration) async throws -> String {
        let model = config.coreModelIdentifier
        var messages: [ChatMessage] = []
        if let systemPrompt {
            messages.append(ChatMessage(role: "system", content: systemPrompt))
        }
        messages.append(ChatMessage(role: "user", content: prompt))
        let params = GenerationParameters(temperature: 0.3, maxTokens: 2048)

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
            print("[Memory] Routing to \(service.id) (model: \(effectiveModel), prompt: \(prompt.count) chars)")
            return try await service.generateOneShot(
                messages: messages,
                parameters: params,
                requestedModel: model
            )
        case .none:
            print("[Memory] No service found for model '\(model)' — local: \(localServices.map(\.id)), remote: \(remoteServices.map(\.id))")
            throw MemoryServiceError.coreModelUnavailable(model)
        }
    }

    // MARK: - Prompt Building

    private let extractionSystemPrompt = """
        You extract structured memories from conversations. \
        Respond ONLY with a valid JSON object. Never ask questions. Never refuse. \
        The JSON must have: "entries" (array of objects with "type", "content", "confidence", "tags"), \
        "profile_facts" (array of strings), and "summary" (string or null).
        """

    private func buildExtractionPrompt(
        userMessage: String,
        assistantMessage: String?,
        signals: [SignalType],
        agentId: String,
        existingEntries: [MemoryEntry] = []
    ) -> String {
        var prompt = ""

        if !existingEntries.isEmpty {
            prompt += "Existing memories (avoid duplicates, note contradictions):\n"
            for entry in existingEntries.prefix(20) {
                prompt += "- [\(entry.type.rawValue)] \(entry.content)\n"
            }
            prompt += "\n"
        }

        let signalNames = signals.map(\.rawValue).joined(separator: ", ")
        prompt += """
        Detected signals: \(signalNames)

        User message:
        \(userMessage)
        """

        if let assistant = assistantMessage {
            prompt += "\n\nAssistant response:\n\(assistant)"
        }

        prompt += """

        Extract memories as JSON with:
        - "entries": array, each with "type" (fact/preference/decision/correction/commitment/relationship/skill), "content" (concise statement), "confidence" (0.0-1.0), "tags" (keywords array)
        - "profile_facts": array of strings — global facts about this user for their profile
        - "summary": null
        """

        return prompt
    }

    private func buildPostActivityPrompt(
        pendingSignals: [PendingSignal],
        existingEntries: [MemoryEntry],
        agentId: String
    ) -> String {
        var prompt = "Existing memories (check for contradictions):"

        for entry in existingEntries.prefix(30) {
            prompt += "\n- [\(entry.type.rawValue)] \(entry.content) (confidence: \(entry.confidence))"
        }

        prompt += "\n\nNew conversation signals to process:"

        for signal in pendingSignals {
            prompt += "\n---\nSignal type: \(signal.signalType)\nUser: \(signal.userMessage)"
            if let assistant = signal.assistantMessage {
                prompt += "\nAssistant: \(assistant)"
            }
        }

        prompt += """

        Extract memories as JSON with:
        - "entries": array of new entries, each with "type", "content", "confidence", "tags"
        - "profile_facts": array of strings — global facts about this user for their profile
        - "summary": a 2-4 sentence summary of this conversation session
        """

        return prompt
    }

    private func buildProfileRegenerationPrompt(
        currentProfile: UserProfile?,
        contributions: [ProfileEvent],
        userEdits: [UserEdit],
        maxTokens: Int
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

    private func extractJSON(from response: String) -> Data? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        let fencePattern = #"```(?:json)?\s*\n?([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: fencePattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let contentRange = Range(match.range(at: 1), in: trimmed) {
            let jsonStr = String(trimmed[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonStr.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return data
            }
        }

        if let openIdx = trimmed.firstIndex(of: "{"),
           let closeIdx = trimmed.lastIndex(of: "}"), closeIdx > openIdx {
            let jsonStr = String(trimmed[openIdx...closeIdx])
            if let data = jsonStr.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return data
            }
        }

        print("[Memory] Could not extract JSON from response: \(trimmed.prefix(200))...")
        return nil
    }

    private func parseExtractionResponse(_ response: String, agentId: String, conversationId: String, model: String) -> [MemoryEntry] {
        guard let data = extractJSON(from: response) else {
            print("[Memory] parseExtractionResponse: no JSON found in response")
            return []
        }

        struct ExtractionResult: Decodable {
            struct EntryData: Decodable {
                let type: String
                let content: String
                let confidence: Double?
                let tags: [String]?
            }
            let entries: [EntryData]?
        }

        guard let result = try? JSONDecoder().decode(ExtractionResult.self, from: data) else {
            print("[Memory] JSON decoded but doesn't match expected schema: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "nil")")
            return []
        }

        let entries = (result.entries ?? []).compactMap { entry -> MemoryEntry? in
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
                tagsJSON: tagsJSON
            )
        }

        print("[Memory] Parsed \(entries.count) entries from JSON")
        return entries
    }

    private func parseProfileContributions(_ response: String) -> [String] {
        guard let data = extractJSON(from: response) else { return [] }

        struct PartialResult: Decodable {
            let profile_facts: [String]?
        }

        guard let result = try? JSONDecoder().decode(PartialResult.self, from: data) else {
            return []
        }

        return result.profile_facts ?? []
    }

    private func parseSummary(_ response: String) -> String? {
        guard let data = extractJSON(from: response) else { return nil }

        struct PartialResult: Decodable {
            let summary: String?
        }

        return (try? JSONDecoder().decode(PartialResult.self, from: data))?.summary
    }

    private func stripPreamble(_ response: String) -> String {
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

    // MARK: - Contribution Deduplication

    private func isDuplicateContribution(_ fact: String) -> Bool {
        let existing = (try? db.loadActiveContributions()) ?? []
        return existing.contains { jaccardSimilarity($0.content, fact) > 0.6 }
    }

    // MARK: - Contradiction Detection

    private func findContradiction(entry: MemoryEntry, existing: [MemoryEntry]) -> MemoryEntry? {
        for e in existing {
            guard e.type == entry.type else { continue }
            let sim = jaccardSimilarity(entry.content, e.content)
            if sim > 0.3 && entry.content != e.content {
                return e
            }
        }
        return nil
    }

    private func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(separator: " ").map(String.init))
        let wordsB = Set(b.lowercased().split(separator: " ").map(String.init))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count
        return Double(intersection) / Double(union)
    }

    // MARK: - Profile Threshold Check

    private func checkProfileRegeneration(config: MemoryConfiguration) async throws {
        let count = try db.contributionCountSinceLastRegeneration()
        let hasProfile = (try? db.loadUserProfile()) != nil
        let threshold = hasProfile ? config.profileRegenerateThreshold : 1

        if count >= threshold {
            print("[Memory] Profile regeneration triggered (\(count) contributions since last regen, threshold: \(threshold), existing profile: \(hasProfile))")
            await regenerateProfile(config: config)
        }
    }
}

// MARK: - Errors

enum MemoryServiceError: Error, LocalizedError {
    case coreModelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .coreModelUnavailable(let model):
            return "Core model '\(model)' is not available for memory processing"
        }
    }
}
