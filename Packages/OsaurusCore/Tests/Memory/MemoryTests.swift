//
//  MemoryTests.swift
//  osaurus
//
//  Unit tests for the v2 memory subsystem: text similarity, configuration
//  validation, model invariants, database CRUD, and relevance-gate /
//  planner / consolidator behavior.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Text similarity

struct TextSimilarityTests {

    @Test func identicalStringsReturnOne() {
        let score = TextSimilarity.jaccard("hello world", "hello world")
        #expect(score == 1.0)
    }

    @Test func completelyDifferentStringsReturnZero() {
        let score = TextSimilarity.jaccard("hello world", "foo bar baz")
        #expect(score == 0.0)
    }

    @Test func partialOverlap() {
        let score = TextSimilarity.jaccard("the quick brown fox", "the slow brown dog")
        #expect(abs(score - 2.0 / 6.0) < 0.001)
    }

    @Test func caseInsensitive() {
        let score = TextSimilarity.jaccard("Hello World", "hello world")
        #expect(score == 1.0)
    }

    @Test func emptyStringsReturnZero() {
        let score = TextSimilarity.jaccard("", "")
        #expect(score == 0.0)
    }
}

// MARK: - Configuration

struct MemoryConfigurationTests {

    @Test func defaultValues() {
        let config = MemoryConfiguration()
        #expect(config.enabled == true)
        #expect(config.memoryBudgetTokens == 800)
        #expect(config.extractionMode == .sessionEnd)
        #expect(config.relevanceGateMode == .heuristic)
        #expect(config.salienceFloor == 0.2)
        #expect(config.episodeRetentionDays == 365)
        #expect(config.consolidationIntervalHours == 24)
    }

    @Test func decodesWithMissingKeys() throws {
        let json = #"{"enabled": false}"#
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
        #expect(config.enabled == false)
        #expect(config.memoryBudgetTokens == 800)
        #expect(config.embeddingBackend == "mlx")
    }

    @Test func roundTrips() throws {
        var config = MemoryConfiguration()
        config.memoryBudgetTokens = 1500
        config.salienceFloor = 0.35
        config.enabled = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
        #expect(decoded == config)
    }

    @Test func validationClampsNegativeValues() {
        var config = MemoryConfiguration()
        config.memoryBudgetTokens = -500
        config.summaryDebounceSeconds = -5
        config.salienceFloor = -1.0
        config.consolidationIntervalHours = -1
        let validated = config.validated()
        #expect(validated.memoryBudgetTokens == 100)
        #expect(validated.summaryDebounceSeconds == 10)
        #expect(validated.salienceFloor == 0.0)
        #expect(validated.consolidationIntervalHours == 1)
    }

    @Test func validationClampsExcessiveValues() {
        var config = MemoryConfiguration()
        config.memoryBudgetTokens = 999_999
        config.consolidationIntervalHours = 999_999
        config.episodeRetentionDays = 999_999
        let validated = config.validated()
        #expect(validated.memoryBudgetTokens == 4000)
        #expect(validated.consolidationIntervalHours == 168)
        #expect(validated.episodeRetentionDays == 3650)
    }
}

// MARK: - Model invariants

struct PinnedFactValidationTests {

    @Test func salienceClampedToRange() {
        let high = PinnedFact(agentId: "a", content: "x", salience: 1.5)
        #expect(high.salience == 1.0)
        let low = PinnedFact(agentId: "a", content: "x", salience: -0.2)
        #expect(low.salience == 0.0)
    }

    @Test func contentTruncatedToMaxLength() {
        let long = String(repeating: "a", count: MemoryConfiguration.maxContentLength + 100)
        let fact = PinnedFact(agentId: "a", content: long)
        #expect(fact.content.count == MemoryConfiguration.maxContentLength)
    }

    @Test func tagsParsedFromCSV() {
        let fact = PinnedFact(agentId: "a", content: "x", tagsCSV: "swift, ios, vapor")
        #expect(fact.tags == ["swift", "ios", "vapor"])
    }

    @Test func emptyTagsCSV() {
        let fact = PinnedFact(agentId: "a", content: "x", tagsCSV: nil)
        #expect(fact.tags.isEmpty)
    }
}

struct EpisodeValidationTests {

    @Test func salienceClamped() {
        let ep = Episode(
            agentId: "a",
            conversationId: "c",
            summary: "s",
            salience: 2.0,
            conversationAt: "2025-01-01"
        )
        #expect(ep.salience == 1.0)
    }

    @Test func topicsAndEntitiesParseFromCSV() {
        let ep = Episode(
            agentId: "a",
            conversationId: "c",
            summary: "x",
            topicsCSV: "swift, postgres, deployment",
            entitiesCSV: "Alice, ProjectX",
            conversationAt: "2025-01-01"
        )
        #expect(ep.topics == ["swift", "postgres", "deployment"])
        #expect(ep.entities == ["Alice", "ProjectX"])
    }
}

// MARK: - Database CRUD

struct MemoryDatabaseTests {

    private func makeTempDB() throws -> MemoryDatabase {
        let db = MemoryDatabase()
        try db.openInMemory()
        return db
    }

    // MARK: - Identity

    @Test func identityRoundTrip() throws {
        let db = try makeTempDB()
        let identity = Identity(
            content: "User loves Swift.",
            overrides: ["Always reply in English"],
            tokenCount: 5,
            version: 1,
            model: "test",
            generatedAt: "2025-01-01T00:00:00Z"
        )
        try db.saveIdentity(identity)
        let loaded = try db.loadIdentity()
        #expect(loaded?.content == "User loves Swift.")
        #expect(loaded?.overrides == ["Always reply in English"])
        #expect(loaded?.version == 1)
    }

    @Test func appendIdentityOverrideDeduplicates() throws {
        let db = try makeTempDB()
        try db.appendIdentityOverride("Prefer concise answers")
        try db.appendIdentityOverride("Prefer concise answers")
        try db.appendIdentityOverride("Prefer concise answers")
        let loaded = try db.loadIdentity()
        #expect(loaded?.overrides == ["Prefer concise answers"])
    }

    @Test func removeIdentityOverride() throws {
        let db = try makeTempDB()
        try db.appendIdentityOverride("first")
        try db.appendIdentityOverride("second")
        try db.removeIdentityOverride(at: 0)
        let loaded = try db.loadIdentity()
        #expect(loaded?.overrides == ["second"])
    }

    // MARK: - Pinned facts

    @Test func pinnedFactRoundTrip() throws {
        let db = try makeTempDB()
        let fact = PinnedFact(agentId: "a", content: "User uses Postgres", salience: 0.7)
        try db.insertPinnedFact(fact)
        let loaded = try db.loadPinnedFacts(agentId: "a")
        #expect(loaded.count == 1)
        #expect(loaded[0].content == "User uses Postgres")
        #expect(abs(loaded[0].salience - 0.7) < 0.001)
    }

    @Test func deletePinnedFact() throws {
        let db = try makeTempDB()
        let fact = PinnedFact(agentId: "a", content: "x")
        try db.insertPinnedFact(fact)
        try db.deletePinnedFact(id: fact.id)
        let loaded = try db.loadPinnedFacts(agentId: "a")
        #expect(loaded.isEmpty)
    }

    @Test func bumpPinnedFactUsage() throws {
        let db = try makeTempDB()
        let fact = PinnedFact(agentId: "a", content: "x")
        try db.insertPinnedFact(fact)
        try db.bumpPinnedFactUsage(ids: [fact.id])
        try db.bumpPinnedFactUsage(ids: [fact.id])
        let loaded = try db.loadPinnedFacts(agentId: "a")
        #expect(loaded[0].useCount == 2)
    }

    @Test func evictBelowSalienceFloor() throws {
        let db = try makeTempDB()
        // Eviction also requires the fact to be idle, so we use a low
        // salience and then manually mark last_used to be far in the past
        // by issuing a SQL UPDATE. The simpler check is that nothing gets
        // evicted when last_used is recent.
        try db.insertPinnedFact(PinnedFact(agentId: "a", content: "low", salience: 0.1))
        try db.insertPinnedFact(PinnedFact(agentId: "a", content: "high", salience: 0.9))
        let evicted = try db.evictPinnedFacts(belowSalience: 0.5, idleDays: 0)
        #expect(evicted == 1)
        let remaining = try db.loadPinnedFacts(agentId: "a")
        #expect(remaining.count == 1)
        #expect(remaining[0].content == "high")
    }

    @Test func loadPinnedFactsByIds() throws {
        let db = try makeTempDB()
        let f1 = PinnedFact(agentId: "a", content: "A")
        let f2 = PinnedFact(agentId: "a", content: "B")
        let f3 = PinnedFact(agentId: "a", content: "C")
        try db.insertPinnedFact(f1)
        try db.insertPinnedFact(f2)
        try db.insertPinnedFact(f3)
        let loaded = try db.loadPinnedFactsByIds([f1.id, f3.id])
        #expect(loaded.count == 2)
    }

    @Test func searchPinnedFactsText() throws {
        let db = try makeTempDB()
        try db.insertPinnedFact(PinnedFact(agentId: "a", content: "Loves Swift programming"))
        try db.insertPinnedFact(PinnedFact(agentId: "a", content: "Drinks coffee"))
        let hits = try db.searchPinnedFactsText(query: "swift", agentId: "a")
        #expect(hits.count == 1)
    }

    // MARK: - Episodes

    @Test func episodeRoundTrip() throws {
        let db = try makeTempDB()
        let ep = Episode(
            agentId: "a",
            conversationId: "c1",
            summary: "Discussed Swift",
            topicsCSV: "swift, ios",
            entitiesCSV: "Apple",
            salience: 0.6,
            tokenCount: 4,
            model: "test",
            conversationAt: "2025-01-01T00:00:00Z"
        )
        let id = try db.insertEpisode(ep)
        #expect(id > 0)
        let loaded = try db.loadEpisodes(agentId: "a")
        #expect(loaded.count == 1)
        #expect(loaded[0].summary == "Discussed Swift")
        #expect(loaded[0].topics == ["swift", "ios"])
        #expect(loaded[0].entities == ["Apple"])
    }

    @Test func loadEpisodesRespectsDays() throws {
        let db = try makeTempDB()
        let ep = Episode(
            agentId: "a",
            conversationId: "c",
            summary: "old session",
            conversationAt: "2020-01-01T00:00:00Z"
        )
        _ = try db.insertEpisode(ep)
        let recent = try db.loadEpisodes(agentId: "a", days: 30)
        #expect(recent.isEmpty)
        let all = try db.loadEpisodes(agentId: "a")
        #expect(all.count == 1)
    }

    @Test func insertEpisodeAndMarkProcessedAtomic() throws {
        let db = try makeTempDB()
        try db.insertPendingSignal(
            PendingSignal(agentId: "a", conversationId: "c1", userMessage: "hi")
        )
        let ep = Episode(
            agentId: "a",
            conversationId: "c1",
            summary: "Hello session",
            tokenCount: 3,
            model: "test",
            conversationAt: "2025-01-01T00:00:00Z"
        )
        _ = try db.insertEpisodeAndMarkProcessed(ep)
        let pending = try db.loadPendingSignals(conversationId: "c1")
        #expect(pending.isEmpty)
        let episodes = try db.loadEpisodes(agentId: "a")
        #expect(episodes.count == 1)
    }

    @Test func pruneEpisodes() throws {
        let db = try makeTempDB()
        _ = try db.insertEpisode(
            Episode(
                agentId: "a",
                conversationId: "c",
                summary: "old",
                conversationAt: "2020-01-01T00:00:00Z"
            )
        )
        let pruned = try db.pruneEpisodes(olderThanDays: 365)
        #expect(pruned == 1)
    }

    // MARK: - Transcript

    @Test func transcriptRoundTrip() throws {
        let db = try makeTempDB()
        try db.insertTranscriptTurn(
            agentId: "a",
            conversationId: "conv1",
            chunkIndex: 0,
            role: "user",
            content: "Hello",
            tokenCount: 1
        )
        let turns = try db.loadTranscript(agentId: "a", days: 30)
        #expect(turns.count == 1)
        #expect(turns[0].content == "Hello")
    }

    /// Regression for the 2026-04 memory consolidator crash:
    /// `pruneTranscriptReturningKeys` opens an `inTransaction` block
    /// (which holds `queue.sync`) and then called the locking
    /// `prepareAndExecute` / `executeUpdate` wrappers from inside
    /// that block. Re-entrant `queue.sync` on the same serial
    /// `DispatchQueue` traps with `EXC_BREAKPOINT` (libdispatch
    /// deadlock detector). The fix added non-locking
    /// `…(on: connection, …)` cores; this test exercises the path
    /// end-to-end with rows that span both the "old enough to
    /// prune" and "keep" buckets.
    @Test func pruneTranscriptReturningKeys_doesNotDeadlockTheTransactionQueue() throws {
        let db = try makeTempDB()

        // Insert one ancient row (will be pruned) + one fresh row
        // (will survive). Use explicit dates so the predicate is
        // deterministic.
        try db.insertTranscriptTurn(
            agentId: "a",
            conversationId: "old-conv",
            chunkIndex: 0,
            role: "user",
            content: "ancient",
            tokenCount: 1,
            createdAt: "2020-01-01 00:00:00"
        )
        try db.insertTranscriptTurn(
            agentId: "a",
            conversationId: "fresh-conv",
            chunkIndex: 0,
            role: "user",
            content: "fresh",
            tokenCount: 1
        )

        // Pre-fix, this call crashed with EXC_BREAKPOINT inside
        // `prepareAndExecute → queue.sync` because `inTransaction`
        // already held the serial queue.
        let pruned = try db.pruneTranscriptReturningKeys(olderThanDays: 30)

        #expect(pruned.count == 1)
        #expect(pruned.first?.conversationId == "old-conv")

        // Survivor row must remain.
        let remaining = try db.loadTranscript(agentId: "a", days: 365)
        #expect(remaining.count == 1)
        #expect(remaining[0].conversationId == "fresh-conv")
    }

    @Test func deleteTranscriptForConversation() throws {
        let db = try makeTempDB()
        try db.insertTranscriptTurn(
            agentId: "a",
            conversationId: "c1",
            chunkIndex: 0,
            role: "user",
            content: "A",
            tokenCount: 1
        )
        try db.insertTranscriptTurn(
            agentId: "a",
            conversationId: "c2",
            chunkIndex: 0,
            role: "user",
            content: "B",
            tokenCount: 1
        )
        try db.deleteTranscriptForConversation("c1")
        let remaining = try db.loadTranscript(agentId: "a", days: 30)
        #expect(remaining.count == 1)
        #expect(remaining[0].conversationId == "c2")
    }

    // MARK: - Pending signals

    @Test func pendingSignalRoundTrip() throws {
        let db = try makeTempDB()
        try db.insertPendingSignal(
            PendingSignal(agentId: "a", conversationId: "c", userMessage: "hi", assistantMessage: "hello")
        )
        let pending = try db.loadPendingSignals(conversationId: "c")
        #expect(pending.count == 1)
        #expect(pending[0].userMessage == "hi")
    }

    @Test func markSignalsProcessed() throws {
        let db = try makeTempDB()
        try db.insertPendingSignal(
            PendingSignal(agentId: "a", conversationId: "c", userMessage: "x")
        )
        try db.markSignalsProcessed(conversationId: "c")
        let pending = try db.loadPendingSignals(conversationId: "c")
        #expect(pending.isEmpty)
    }

    @Test func processingLogStats() throws {
        let db = try makeTempDB()
        try db.insertProcessingLog(
            agentId: "a",
            taskType: "distill",
            model: "m",
            status: "success",
            durationMs: 100
        )
        try db.insertProcessingLog(
            agentId: "a",
            taskType: "distill",
            model: "m",
            status: "error",
            durationMs: 200
        )
        let stats = try db.processingStats()
        #expect(stats.totalCalls == 2)
        #expect(stats.successCount == 1)
        #expect(stats.errorCount == 1)
    }
}

// MARK: - Context assembler

struct MemoryContextAssemblerTests {

    @Test func disabledConfigReturnsEmpty() async {
        var config = MemoryConfiguration()
        config.enabled = false
        let context = await MemoryContextAssembler.assembleContext(agentId: "test", config: config)
        #expect(context.isEmpty)
    }
}

// MARK: - Relevance gate

struct MemoryRelevanceGateTests {

    @Test func emptyOrTinyQueryReturnsNone() {
        let verdict = MemoryRelevanceGate.decide(
            query: "",
            identity: nil,
            knownEntities: [],
            mode: .heuristic
        )
        #expect(verdict == .none)
    }

    @Test func identityCuriousReturnsIdentity() {
        let verdict = MemoryRelevanceGate.decide(
            query: "what's my name?",
            identity: nil,
            knownEntities: [],
            mode: .heuristic
        )
        #expect(verdict == .identity)
    }

    @Test func temporalMarkerReturnsEpisode() {
        let verdict = MemoryRelevanceGate.decide(
            query: "what did we talk about yesterday?",
            identity: nil,
            knownEntities: [],
            mode: .heuristic
        )
        #expect(verdict == .episode)
    }

    @Test func priorContextPronounReturnsEpisode() {
        let verdict = MemoryRelevanceGate.decide(
            query: "remember when you said the deployment was broken?",
            identity: nil,
            knownEntities: [],
            mode: .heuristic
        )
        #expect(verdict == .episode)
    }

    @Test func entityHitReturnsPinned() {
        let verdict = MemoryRelevanceGate.decide(
            query: "How is ProjectNova going?",
            identity: nil,
            knownEntities: ["ProjectNova"],
            mode: .heuristic
        )
        #expect(verdict == .pinned)
    }

    @Test func explicitRecallVerbReturnsPinned() {
        let verdict = MemoryRelevanceGate.decide(
            query: "do you remember my preference?",
            identity: nil,
            knownEntities: [],
            mode: .heuristic
        )
        #expect(verdict == .pinned)
    }

    @Test func literalRecallReturnsTranscript() {
        let verdict = MemoryRelevanceGate.decide(
            query: "what were my exact words about the deploy?",
            identity: nil,
            knownEntities: [],
            mode: .heuristic
        )
        #expect(verdict == .transcript)
    }

    @Test func unrelatedQueryReturnsNone() {
        let verdict = MemoryRelevanceGate.decide(
            query: "What's 2 + 2?",
            identity: nil,
            knownEntities: [],
            mode: .heuristic
        )
        #expect(verdict == .none)
    }

    @Test func offModeAlwaysReturnsEpisode() {
        let verdict = MemoryRelevanceGate.decide(
            query: "anything",
            identity: nil,
            knownEntities: [],
            mode: .off
        )
        #expect(verdict == .episode)
    }

    @Test func shortEntityNamesIgnored() {
        // 3-char entities false-match common words; the gate filters them.
        let verdict = MemoryRelevanceGate.decide(
            query: "let me know",
            identity: nil,
            knownEntities: ["AI"],
            mode: .heuristic
        )
        #expect(verdict == .none)
    }
}

// MARK: - Distill response parsing

struct DistillResponseParsingTests {

    @Test func parsesCleanJSON() {
        let json = """
            {
              "episode": {
                "summary": "User picked Postgres for the new project.",
                "topics": ["postgres", "deployment"],
                "decisions": ["Use Postgres"],
                "action_items": ["Spin up RDS"],
                "salience": 0.8
              },
              "entities": ["Postgres", "RDS"],
              "pinned_candidates": [
                {"content": "User picked Postgres", "salience": 0.85, "tags": ["decision", "infra"]}
              ],
              "identity_facts": ["User builds with Postgres"]
            }
            """
        let result = MemoryService.shared.parseDistillResponse(json)
        #expect(result.episode?.summary == "User picked Postgres for the new project.")
        #expect(result.episode?.topics == ["postgres", "deployment"])
        #expect(result.episode?.salience == 0.8)
        #expect(result.entities == ["Postgres", "RDS"])
        #expect(result.pinnedCandidates.count == 1)
        #expect(result.pinnedCandidates[0].content == "User picked Postgres")
        #expect(result.identityFacts == ["User builds with Postgres"])
    }

    @Test func parsesCodeFencedJSON() {
        let response = """
            Here is the digest:
            ```json
            {"episode": {"summary": "Quick chat", "topics": [], "decisions": [], "action_items": [], "salience": 0.3}}
            ```
            """
        let result = MemoryService.shared.parseDistillResponse(response)
        #expect(result.episode?.summary == "Quick chat")
    }

    @Test func parsesEmbeddedJSON() {
        let response =
            "Sure! {\"episode\":{\"summary\":\"x\",\"topics\":[],\"decisions\":[],\"action_items\":[],\"salience\":0.1}}"
        let result = MemoryService.shared.parseDistillResponse(response)
        #expect(result.episode?.summary == "x")
    }

    @Test func returnsEmptyOnGarbage() {
        let result = MemoryService.shared.parseDistillResponse("I'm sorry, I can't.")
        #expect(result.episode == nil)
        #expect(result.entities.isEmpty)
        #expect(result.pinnedCandidates.isEmpty)
    }

    @Test func toleratesSalienceAsString() {
        let json = """
            {"episode": {"summary": "x", "topics": [], "decisions": [], "action_items": [], "salience": "0.4"}}
            """
        let result = MemoryService.shared.parseDistillResponse(json)
        #expect(result.episode?.salience == 0.4)
    }
}

// MARK: - Strip preamble

struct StripPreambleTests {

    @Test func removesCertainlyPreamble() {
        let result = MemoryService.shared.stripPreamble("Certainly! The user prefers Swift.")
        #expect(result == "The user prefers Swift.")
    }

    @Test func preservesCleanText() {
        let text = "John uses Swift."
        let result = MemoryService.shared.stripPreamble(text)
        #expect(result == text)
    }

    @Test func handlesWhitespace() {
        let result = MemoryService.shared.stripPreamble("  \n  Hello world  \n  ")
        #expect(result == "Hello world")
    }
}
