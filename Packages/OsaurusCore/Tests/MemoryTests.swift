//
//  MemoryTests.swift
//  osaurus
//
//  Unit tests for the memory subsystem: text similarity, context assembly budgets,
//  verification parsing, database CRUD, and transaction safety.
//

import Foundation
import Testing

@testable import OsaurusCore

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
        // Intersection: {the, brown} = 2, Union: {the, quick, brown, fox, slow, dog} = 6
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

    @Test func oneEmptyString() {
        let score = TextSimilarity.jaccard("hello", "")
        #expect(score == 0.0)
    }

    @Test func contradictionWithDifferentPhrasing() {
        let score = TextSimilarity.jaccard("Terence moved to Irvine", "Terence lives in Los Angeles")
        // Intersection: {terence} = 1, Union: {terence, moved, to, irvine, lives, in, los, angeles} = 8
        #expect(abs(score - 1.0 / 8.0) < 0.001)
        #expect(
            score < MemoryConfiguration.contradictionJaccardThreshold,
            "Differently-phrased contradictions fall below Jaccard contradiction threshold"
        )
    }

    @Test func contradictionWithSimilarPhrasing() {
        let score = TextSimilarity.jaccard("Terence lives in Irvine", "Terence lives in Los Angeles")
        // Intersection: {terence, lives, in} = 3, Union: {terence, lives, in, irvine, los, angeles} = 6
        #expect(abs(score - 3.0 / 6.0) < 0.001)
        #expect(
            score > MemoryConfiguration.contradictionJaccardThreshold,
            "Similarly-phrased contradictions exceed Jaccard contradiction threshold"
        )
    }
}

struct MemoryEntryTagsTests {

    @Test func validTagsJSONDecoded() {
        let entry = MemoryEntry(
            agentId: "a",
            type: .fact,
            content: "test",
            model: "m",
            tagsJSON: "[\"swift\",\"ios\"]"
        )
        #expect(entry.tags == ["swift", "ios"])
    }

    @Test func nilTagsJSONReturnsEmpty() {
        let entry = MemoryEntry(
            agentId: "a",
            type: .fact,
            content: "test",
            model: "m",
            tagsJSON: nil
        )
        #expect(entry.tags.isEmpty)
    }

    @Test func invalidTagsJSONReturnsEmpty() {
        let entry = MemoryEntry(
            agentId: "a",
            type: .fact,
            content: "test",
            model: "m",
            tagsJSON: "not json"
        )
        #expect(entry.tags.isEmpty)
    }

    @Test func emptyArrayTagsJSON() {
        let entry = MemoryEntry(
            agentId: "a",
            type: .fact,
            content: "test",
            model: "m",
            tagsJSON: "[]"
        )
        #expect(entry.tags.isEmpty)
    }
}

struct MemoryConfigurationTests {

    @Test func defaultValues() {
        let config = MemoryConfiguration()
        #expect(config.enabled == true)
        #expect(config.maxEntriesPerAgent == 500)
        #expect(config.preset == .production)
        #expect(config.workingMemoryBudgetTokens == 3000)
        #expect(config.summaryBudgetTokens == 2000)
        #expect(config.chunkBudgetTokens == 4000)
        #expect(config.graphBudgetTokens == 300)
        #expect(config.recallTopK == 30)
        #expect(config.mmrLambda == 0.7)
        #expect(config.summaryRetentionDays == 180)
        #expect(config.verificationJaccardDedupThreshold == 0.6)
        #expect(config.configVersion == 3)
    }

    @Test func decodesWithMissingKeys() throws {
        let json = #"{"enabled": false}"#
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
        #expect(config.enabled == false)
        #expect(config.maxEntriesPerAgent == 500)
        #expect(config.coreModelName == "claude-haiku-4-5")
    }

    @Test func roundTrips() throws {
        var config = MemoryConfiguration()
        config.maxEntriesPerAgent = 200
        config.enabled = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
        #expect(decoded == config)
    }

    @Test func validationClampsNegativeValues() {
        var config = MemoryConfiguration()
        config.summaryDebounceSeconds = -5
        config.profileMaxTokens = -100
        config.maxEntriesPerAgent = -1
        config.temporalDecayHalfLifeDays = -10
        let validated = config.validated()
        #expect(validated.summaryDebounceSeconds == 10)
        #expect(validated.profileMaxTokens == 100)
        #expect(validated.maxEntriesPerAgent == 0)
        #expect(validated.temporalDecayHalfLifeDays == 1)
    }

    @Test func validationClampsExcessiveValues() {
        var config = MemoryConfiguration()
        config.summaryDebounceSeconds = 999_999
        config.profileMaxTokens = 999_999
        config.maxEntriesPerAgent = 999_999
        let validated = config.validated()
        #expect(validated.summaryDebounceSeconds == 3600)
        #expect(validated.profileMaxTokens == 50_000)
        #expect(validated.maxEntriesPerAgent == 10_000)
    }

    @Test func validationPreservesValidValues() {
        let config = MemoryConfiguration()
        let validated = config.validated()
        #expect(validated.summaryDebounceSeconds == config.summaryDebounceSeconds)
        #expect(validated.maxEntriesPerAgent == config.maxEntriesPerAgent)
        #expect(validated.preset == .production)
    }

    @Test func productionPresetApplied() {
        let config = MemoryConfiguration(preset: .production)
        let validated = config.validated()
        #expect(validated.recallTopK == 30)
        #expect(validated.mmrLambda == 0.7)
        #expect(validated.mmrFetchMultiplier == 2.0)
        #expect(validated.workingMemoryBudgetTokens == 3000)
        #expect(validated.summaryBudgetTokens == 2000)
        #expect(validated.chunkBudgetTokens == 4000)
        #expect(validated.graphBudgetTokens == 300)
        #expect(validated.summaryRetentionDays == 180)
    }

    @Test func benchmarkPresetApplied() {
        let config = MemoryConfiguration(preset: .benchmark)
        let validated = config.validated()
        #expect(validated.recallTopK == 50)
        #expect(validated.mmrLambda == 0.85)
        #expect(validated.mmrFetchMultiplier == 3.0)
        #expect(validated.workingMemoryBudgetTokens == 6000)
        #expect(validated.summaryBudgetTokens == 4000)
        #expect(validated.chunkBudgetTokens == 8000)
        #expect(validated.graphBudgetTokens == 500)
        #expect(validated.summaryRetentionDays == 0)
    }

    @Test func presetRoundTrips() throws {
        var config = MemoryConfiguration(preset: .benchmark)
        config.maxEntriesPerAgent = 200
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MemoryConfiguration.self, from: data)
        #expect(decoded.preset == .benchmark)
        #expect(decoded.maxEntriesPerAgent == 200)
    }
}

struct MemoryEntryValidationTests {

    @Test func confidenceClampedToRange() {
        let entry = MemoryEntry(agentId: "a", type: .fact, content: "test", confidence: 1.5, model: "m")
        #expect(entry.confidence == 1.0)
        let entry2 = MemoryEntry(agentId: "a", type: .fact, content: "test", confidence: -0.5, model: "m")
        #expect(entry2.confidence == 0.0)
    }

    @Test func contentTruncatedToMaxLength() {
        let longContent = String(repeating: "a", count: MemoryConfiguration.maxContentLength + 100)
        let entry = MemoryEntry(agentId: "a", type: .fact, content: longContent, model: "m")
        #expect(entry.content.count == MemoryConfiguration.maxContentLength)
    }

    @Test func accessCountClampedToNonNegative() {
        let entry = MemoryEntry(agentId: "a", type: .fact, content: "test", model: "m", accessCount: -5)
        #expect(entry.accessCount == 0)
    }
}

struct MemoryContextAssemblerTests {

    private func makeTempDB() throws -> MemoryDatabase {
        let db = MemoryDatabase()
        try db.openInMemory()
        return db
    }

    @Test func emptyDatabaseReturnsEmptyContext() async throws {
        let config = MemoryConfiguration()
        let context = await MemoryContextAssembler.assembleContext(agentId: "test", config: config)
        #expect(context.isEmpty || !context.contains("Remembered Details"))
    }

    @Test func disabledConfigReturnsEmpty() async {
        var config = MemoryConfiguration()
        config.enabled = false
        let context = await MemoryContextAssembler.assembleContext(agentId: "test", config: config)
        #expect(context.isEmpty)
    }

    @Test func disabledConfigWithQueryReturnsEmpty() async {
        var config = MemoryConfiguration()
        config.enabled = false
        let context = await MemoryContextAssembler.assembleContext(
            agentId: "test",
            config: config,
            query: "What happened yesterday?"
        )
        #expect(context.isEmpty)
    }

    @Test func emptyQueryFallsBackToBaseContext() async {
        let config = MemoryConfiguration()
        let baseContext = await MemoryContextAssembler.assembleContext(agentId: "test", config: config)
        let queryContext = await MemoryContextAssembler.assembleContext(
            agentId: "test",
            config: config,
            query: ""
        )
        #expect(baseContext == queryContext)
    }
}

struct MemoryDatabaseTests {

    private func makeTempDB() throws -> MemoryDatabase {
        let db = MemoryDatabase()
        try db.openInMemory()
        return db
    }

    @Test func insertAndLoadEntry() throws {
        let db = try makeTempDB()
        let entry = MemoryEntry(
            agentId: "agent1",
            type: .fact,
            content: "User likes Swift",
            model: "test"
        )
        try db.insertMemoryEntry(entry)
        let loaded = try db.loadActiveEntries(agentId: "agent1")
        #expect(loaded.count == 1)
        #expect(loaded[0].content == "User likes Swift")
        #expect(loaded[0].type == .fact)
    }

    @Test func deleteMemoryEntry() throws {
        let db = try makeTempDB()
        let entry = MemoryEntry(
            agentId: "agent1",
            type: .preference,
            content: "Prefers dark mode",
            model: "test"
        )
        try db.insertMemoryEntry(entry)
        try db.deleteMemoryEntry(id: entry.id)
        let loaded = try db.loadActiveEntries(agentId: "agent1")
        #expect(loaded.isEmpty)
    }

    @Test func supersedeEntry() throws {
        let db = try makeTempDB()
        let old = MemoryEntry(agentId: "a", type: .fact, content: "Old fact", model: "m")
        let new = MemoryEntry(agentId: "a", type: .fact, content: "New fact", model: "m")
        try db.insertMemoryEntry(old)
        try db.insertMemoryEntry(new)
        try db.supersede(entryId: old.id, by: new.id, reason: "Updated")

        let active = try db.loadActiveEntries(agentId: "a")
        #expect(active.count == 1)
        #expect(active[0].id == new.id)
    }

    @Test func crossTypeSupersede() throws {
        let db = try makeTempDB()
        let fact = MemoryEntry(agentId: "a", type: .fact, content: "Terence lives in Los Angeles", model: "m")
        let correction = MemoryEntry(agentId: "a", type: .correction, content: "Terence moved to Irvine", model: "m")
        try db.insertMemoryEntry(fact)
        try db.insertMemoryEntry(correction)
        try db.supersede(entryId: fact.id, by: correction.id, reason: "Semantically contradicted by newer information")

        let active = try db.loadActiveEntries(agentId: "a")
        #expect(active.count == 1)
        #expect(active[0].id == correction.id)
        #expect(active[0].type == .correction)
    }

    @Test func insertAndLoadEntryWithValidFrom() throws {
        let db = try makeTempDB()
        let entry = MemoryEntry(
            agentId: "agent1",
            type: .fact,
            content: "Went to the park",
            model: "test",
            validFrom: "2023-05-08"
        )
        try db.insertMemoryEntry(entry)
        let loaded = try db.loadActiveEntries(agentId: "agent1")
        #expect(loaded.count == 1)
        #expect(loaded[0].validFrom == "2023-05-08")
    }

    @Test func insertEntryWithEmptyValidFromDefaultsToNow() throws {
        let db = try makeTempDB()
        let entry = MemoryEntry(
            agentId: "agent1",
            type: .fact,
            content: "Timeless fact",
            model: "test",
            validFrom: ""
        )
        try db.insertMemoryEntry(entry)
        let loaded = try db.loadActiveEntries(agentId: "agent1")
        #expect(loaded.count == 1)
        #expect(!loaded[0].validFrom.isEmpty, "Empty validFrom should default to current timestamp")
    }

    @Test func loadEntriesAsOfFiltersCorrectly() throws {
        let db = try makeTempDB()
        let past = MemoryEntry(
            agentId: "a",
            type: .fact,
            content: "Past fact",
            model: "m",
            validFrom: "2023-01-01T00:00:00Z"
        )
        let future = MemoryEntry(
            agentId: "a",
            type: .fact,
            content: "Future fact",
            model: "m",
            validFrom: "2099-01-01T00:00:00Z"
        )
        try db.insertMemoryEntry(past)
        try db.insertMemoryEntry(future)
        let asOf = try db.loadEntriesAsOf(agentId: "a", asOf: "2024-06-01T00:00:00Z")
        #expect(asOf.count == 1)
        #expect(asOf[0].content == "Past fact")
    }

    @Test func touchMemoryEntryUpdatesAccess() throws {
        let db = try makeTempDB()
        let entry = MemoryEntry(agentId: "a", type: .fact, content: "Test", model: "m")
        try db.insertMemoryEntry(entry)
        try db.touchMemoryEntry(id: entry.id)
        try db.touchMemoryEntry(id: entry.id)
        let loaded = try db.loadActiveEntries(agentId: "a")
        #expect(loaded[0].accessCount == 2)
    }

    @Test func batchTouchEntries() throws {
        let db = try makeTempDB()
        let e1 = MemoryEntry(agentId: "a", type: .fact, content: "A", model: "m")
        let e2 = MemoryEntry(agentId: "a", type: .fact, content: "B", model: "m")
        try db.insertMemoryEntry(e1)
        try db.insertMemoryEntry(e2)
        try db.touchMemoryEntries(ids: [e1.id, e2.id])
        let loaded = try db.loadActiveEntries(agentId: "a")
        for entry in loaded {
            #expect(entry.accessCount == 1)
        }
    }

    @Test func loadEntriesByIds() throws {
        let db = try makeTempDB()
        let e1 = MemoryEntry(agentId: "a", type: .fact, content: "A", model: "m")
        let e2 = MemoryEntry(agentId: "a", type: .fact, content: "B", model: "m")
        let e3 = MemoryEntry(agentId: "a", type: .fact, content: "C", model: "m")
        try db.insertMemoryEntry(e1)
        try db.insertMemoryEntry(e2)
        try db.insertMemoryEntry(e3)
        let loaded = try db.loadEntriesByIds([e1.id, e3.id])
        #expect(loaded.count == 2)
        let ids = Set(loaded.map(\.id))
        #expect(ids.contains(e1.id))
        #expect(ids.contains(e3.id))
    }

    @Test func archiveExcessEntries() throws {
        let db = try makeTempDB()
        for i in 0 ..< 5 {
            let e = MemoryEntry(agentId: "a", type: .fact, content: "Fact \(i)", model: "m")
            try db.insertMemoryEntry(e)
        }
        let archived = try db.archiveExcessEntries(agentId: "a", maxEntries: 3)
        #expect(archived == 2)
        let remaining = try db.loadActiveEntries(agentId: "a")
        #expect(remaining.count == 3)
    }

    @Test func userProfileRoundTrip() throws {
        let db = try makeTempDB()
        let profile = UserProfile(
            content: "Test user profile",
            tokenCount: 10,
            version: 1,
            model: "test",
            generatedAt: "2025-01-01T00:00:00Z"
        )
        try db.saveUserProfile(profile)
        let loaded = try db.loadUserProfile()
        #expect(loaded?.content == "Test user profile")
        #expect(loaded?.version == 1)
    }

    @Test func userEditsLifecycle() throws {
        let db = try makeTempDB()
        try db.insertUserEdit("Always respond in English")
        try db.insertUserEdit("Prefer concise answers")
        var edits = try db.loadUserEdits()
        #expect(edits.count == 2)
        try db.deleteUserEdit(id: edits[0].id)
        edits = try db.loadUserEdits()
        #expect(edits.count == 1)
        #expect(edits[0].content == "Prefer concise answers")
    }

    @Test func purgeOldEventData() throws {
        let db = try makeTempDB()
        let entry = MemoryEntry(agentId: "a", type: .fact, content: "F", model: "m")
        try db.insertMemoryEntry(entry)
        try db.purgeOldEventData(retentionDays: 0)
    }

    @Test func activeEntryCount() throws {
        let db = try makeTempDB()
        try db.insertMemoryEntry(MemoryEntry(agentId: "a", type: .fact, content: "A", model: "m"))
        try db.insertMemoryEntry(MemoryEntry(agentId: "a", type: .fact, content: "B", model: "m"))
        try db.insertMemoryEntry(MemoryEntry(agentId: "b", type: .fact, content: "C", model: "m"))
        #expect(try db.activeEntryCount(agentId: "a") == 2)
        #expect(try db.activeEntryCount(agentId: "b") == 1)
        #expect(try db.activeEntryCount() == 3)
    }

    @Test func loadAllActiveEntriesRespectsLimit() throws {
        let db = try makeTempDB()
        for i in 0 ..< 10 {
            try db.insertMemoryEntry(MemoryEntry(agentId: "a", type: .fact, content: "Fact \(i)", model: "m"))
        }
        let limited = try db.loadAllActiveEntries(limit: 3)
        #expect(limited.count == 3)
        let all = try db.loadAllActiveEntries(limit: 100)
        #expect(all.count == 10)
    }

    @Test func pendingSignalRoundTrip() throws {
        let db = try makeTempDB()
        let signal = PendingSignal(
            agentId: "agent1",
            conversationId: "conv1",
            signalType: "conversation",
            userMessage: "Hello",
            assistantMessage: "Hi there"
        )
        try db.insertPendingSignal(signal)
        let loaded = try db.loadPendingSignals(agentId: "agent1")
        #expect(loaded.count == 1)
        #expect(loaded[0].userMessage == "Hello")
        #expect(loaded[0].assistantMessage == "Hi there")
    }

    @Test func markSignalsProcessedByConversation() throws {
        let db = try makeTempDB()
        try db.insertPendingSignal(
            PendingSignal(
                agentId: "a",
                conversationId: "c",
                signalType: "conversation",
                userMessage: "test"
            )
        )
        #expect(try db.loadPendingSignals(conversationId: "c").count == 1)
        try db.markSignalsProcessed(conversationId: "c")
        #expect(try db.loadPendingSignals(conversationId: "c").count == 0)
    }

    @Test func summaryRoundTrip() throws {
        let db = try makeTempDB()
        let now = ISO8601DateFormatter().string(from: Date())
        let summary = ConversationSummary(
            agentId: "a",
            conversationId: "c1",
            summary: "Test summary",
            tokenCount: 10,
            model: "test",
            conversationAt: now
        )
        try db.insertSummary(summary)
        let loaded = try db.loadSummaries(agentId: "a", days: 365)
        #expect(loaded.count == 1)
        #expect(loaded[0].summary == "Test summary")
    }

    @Test func loadSummariesUnlimitedRetention() throws {
        let db = try makeTempDB()
        try db.upsertConversation(id: "c1", agentId: "a", title: nil)
        let summary = ConversationSummary(
            agentId: "a",
            conversationId: "c1",
            summary: "Old summary",
            tokenCount: 10,
            model: "test",
            conversationAt: "2020-01-01"
        )
        try db.insertSummary(summary)
        let withFilter = try db.loadSummaries(agentId: "a", days: 90)
        #expect(withFilter.isEmpty, "90-day filter should exclude 2020 summary")
        let unlimited = try db.loadSummaries(agentId: "a", days: 0)
        #expect(unlimited.count == 1, "days=0 should return all summaries")
        #expect(unlimited[0].summary == "Old summary")
    }

    @Test func insertChunkWithCreatedAt() throws {
        let db = try makeTempDB()
        try db.upsertConversation(id: "conv1", agentId: "a", title: nil)
        try db.insertChunk(
            conversationId: "conv1",
            chunkIndex: 0,
            role: "user",
            content: "Hello from 2023",
            tokenCount: 5,
            createdAt: "2023-05-08"
        )
        let chunks = try db.loadAllChunks(days: 3650)
        #expect(chunks.count == 1)
        #expect(chunks[0].content == "Hello from 2023")
        #expect(chunks[0].createdAt.hasPrefix("2023-05-08"))
    }

    @Test func insertChunkDefaultCreatedAt() throws {
        let db = try makeTempDB()
        try db.upsertConversation(id: "conv1", agentId: "a", title: nil)
        try db.insertChunk(
            conversationId: "conv1",
            chunkIndex: 0,
            role: "user",
            content: "Hello today",
            tokenCount: 5
        )
        let chunks = try db.loadAllChunks(days: 1)
        #expect(chunks.count == 1, "Chunk with default created_at should be within 1 day")
    }

    @Test func deleteChunksForConversation() throws {
        let db = try makeTempDB()
        try db.upsertConversation(id: "conv1", agentId: "a", title: nil)
        try db.upsertConversation(id: "conv2", agentId: "a", title: nil)
        try db.insertChunk(conversationId: "conv1", chunkIndex: 0, role: "user", content: "A", tokenCount: 1)
        try db.insertChunk(conversationId: "conv1", chunkIndex: 1, role: "assistant", content: "B", tokenCount: 1)
        try db.insertChunk(conversationId: "conv2", chunkIndex: 0, role: "user", content: "C", tokenCount: 1)
        try db.deleteChunksForConversation("conv1")
        let remaining = try db.loadAllChunks(days: 1)
        #expect(remaining.count == 1)
        #expect(remaining[0].conversationId == "conv2")
    }

    @Test func deleteChunksForAgent() throws {
        let db = try makeTempDB()
        try db.upsertConversation(id: "conv1", agentId: "agent1", title: nil)
        try db.upsertConversation(id: "conv2", agentId: "agent2", title: nil)
        try db.insertChunk(conversationId: "conv1", chunkIndex: 0, role: "user", content: "A", tokenCount: 1)
        try db.insertChunk(conversationId: "conv2", chunkIndex: 0, role: "user", content: "B", tokenCount: 1)
        try db.deleteChunksForAgent("agent1")
        let remaining = try db.loadAllChunks(days: 1)
        #expect(remaining.count == 1)
        #expect(remaining[0].conversationId == "conv2")
    }

    @Test func profileEventLifecycle() throws {
        let db = try makeTempDB()
        try db.insertProfileEvent(
            ProfileEvent(
                agentId: "a",
                eventType: "contribution",
                content: "fact1",
                model: "test"
            )
        )
        try db.insertProfileEvent(
            ProfileEvent(
                agentId: "a",
                eventType: "contribution",
                content: "fact2",
                model: "test"
            )
        )
        let contributions = try db.loadActiveContributions()
        #expect(contributions.count == 2)
        let count = try db.contributionCountSinceLastRegeneration()
        #expect(count == 2)
    }

    @Test func processingLogAndStats() throws {
        let db = try makeTempDB()
        try db.insertProcessingLog(agentId: "a", taskType: "test", model: "m", status: "success", durationMs: 100)
        try db.insertProcessingLog(agentId: "a", taskType: "test", model: "m", status: "error", durationMs: 200)
        let stats = try db.processingStats()
        #expect(stats.totalCalls == 2)
        #expect(stats.successCount == 1)
        #expect(stats.errorCount == 1)
    }

    @Test func entityAndRelationshipRoundTrip() throws {
        let db = try makeTempDB()
        let entity1 = try db.resolveEntity(name: "Alice", type: "person", model: "test")
        let entity2 = try db.resolveEntity(name: "ProjectX", type: "project", model: "test")
        try db.insertRelationship(
            sourceId: entity1.id,
            targetId: entity2.id,
            relation: "works_on",
            confidence: 0.9,
            model: "test"
        )
        let results = try db.queryRelationships(relation: "works_on")
        #expect(results.count == 1)
        #expect(results[0].path.contains("Alice"))
        #expect(results[0].path.contains("ProjectX"))
    }

    @Test func resolveEntityDeduplicates() throws {
        let db = try makeTempDB()
        let e1 = try db.resolveEntity(name: "Alice", type: "person", model: "test")
        let e2 = try db.resolveEntity(name: "Alice", type: "person", model: "test")
        #expect(e1.id == e2.id)
    }

    @Test func insertSummaryAndMarkProcessedAtomic() throws {
        let db = try makeTempDB()
        try db.insertPendingSignal(
            PendingSignal(agentId: "a", conversationId: "c1", signalType: "conversation", userMessage: "hi")
        )
        let summary = ConversationSummary(
            agentId: "a",
            conversationId: "c1",
            summary: "Test",
            tokenCount: 5,
            model: "test",
            conversationAt: ISO8601DateFormatter().string(from: Date())
        )
        try db.insertSummaryAndMarkProcessed(summary)

        let pending = try db.loadPendingSignals(conversationId: "c1")
        #expect(pending.isEmpty, "Signals should be marked processed")
        let summaries = try db.loadSummaries(agentId: "a", days: 365)
        #expect(summaries.count == 1)
        #expect(summaries[0].summary == "Test")
    }
}

struct MemoryServiceParseTests {

    private let service = MemoryService.shared

    @Test func parseResponseValidJSON() {
        let json = """
            {
                "entries": [{"type": "fact", "content": "User likes Swift", "confidence": 0.9, "tags": ["swift"], "valid_from": ""}],
                "profile_facts": ["Prefers dark mode"],
                "entities": [{"name": "Swift", "type": "tool"}],
                "relationships": [{"source": "User", "relation": "uses", "target": "Swift", "confidence": 0.8}]
            }
            """
        let result = service.parseResponse(json)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].content == "User likes Swift")
        #expect(result.entries[0].valid_from == "")
        #expect(result.profileFacts == ["Prefers dark mode"])
        #expect(result.graph.entities.count == 1)
        #expect(result.graph.relationships.count == 1)
    }

    @Test func parseResponseWithValidFrom() {
        let json = """
            {
                "entries": [
                    {"type": "fact", "content": "Went to the park", "confidence": 0.9, "tags": ["activity"], "valid_from": "2023-05-08"},
                    {"type": "preference", "content": "Likes hiking", "confidence": 0.8, "tags": ["hobby"], "valid_from": ""}
                ],
                "profile_facts": [],
                "entities": [],
                "relationships": []
            }
            """
        let result = service.parseResponse(json)
        #expect(result.entries.count == 2)
        #expect(result.entries[0].valid_from == "2023-05-08")
        #expect(result.entries[1].valid_from == "")
    }

    @Test func parseResponseCodeFenced() {
        let response = """
            Here is the result:
            ```json
            {"entries": [{"type": "preference", "content": "Likes tea"}], "profile_facts": [], "entities": [], "relationships": []}
            ```
            """
        let result = service.parseResponse(response)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].type == "preference")
    }

    @Test func parseResponseNoJSON() {
        let result = service.parseResponse("I'm sorry, I can't do that.")
        #expect(result.entries.isEmpty)
        #expect(result.profileFacts.isEmpty)
    }

    @Test func parseResponseLenientConfidenceAsString() {
        let json = """
            {"entries": [{"type": "fact", "content": "Test", "confidence": "0.75", "tags": "single"}], "profile_facts": ["F1"]}
            """
        guard let data = json.data(using: .utf8) else { return }
        let result = service.parseResponseLenient(data)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].confidence == 0.75)
        #expect(result.entries[0].tags == ["single"])
        #expect(result.profileFacts == ["F1"])
    }

    @Test func parseResponseLenientWithValidFrom() {
        let json = """
            {"entries": [{"type": "fact", "content": "Met Alice", "confidence": 0.9, "tags": [], "valid_from": "2023-06-15"}], "profile_facts": []}
            """
        guard let data = json.data(using: .utf8) else { return }
        let result = service.parseResponseLenient(data)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].valid_from == "2023-06-15")
    }

    @Test func parseResponsePartialJSON() {
        let json = """
            {"entries": [{"type": "skill", "content": "Knows Python"}]}
            """
        let result = service.parseResponse(json)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].type == "skill")
        #expect(result.profileFacts.isEmpty)
    }
}

struct StripPreambleTests {

    private let service = MemoryService.shared

    @Test func removesCertainlyPreamble() {
        let result = service.stripPreamble("Certainly! The user prefers Swift.")
        #expect(result == "The user prefers Swift.")
    }

    @Test func removesOfCoursePreamble() {
        let result = service.stripPreamble("Of course, the answer is yes.")
        #expect(result == "the answer is yes.")
    }

    @Test func removesHeresPreamble() {
        let result = service.stripPreamble("Here's the result.")
        #expect(result == "the result.")
    }

    @Test func preservesCleanText() {
        let text = "John is a software developer who uses Swift."
        let result = service.stripPreamble(text)
        #expect(result == text)
    }

    @Test func handlesWhitespace() {
        let result = service.stripPreamble("  \n  Hello world  \n  ")
        #expect(result == "Hello world")
    }
}

struct FindContradictionTests {

    private let service = MemoryService.shared

    @Test func detectsContradictionWithSimilarWording() {
        let existing = MemoryEntry(agentId: "a", type: .fact, content: "Terence lives in Los Angeles", model: "m")
        let candidate = MemoryEntry(agentId: "a", type: .fact, content: "Terence lives in Irvine", model: "m")
        let existingTokens = [TextSimilarity.tokenize(existing.content)]
        let candidateTokens = TextSimilarity.tokenize(candidate.content)

        let result = service.findContradiction(
            entry: candidate,
            entryTokens: candidateTokens,
            existing: [existing],
            existingTokens: existingTokens
        )
        #expect(result != nil, "Should detect contradiction between similar-phrased location facts")
        #expect(result?.id == existing.id)
    }

    @Test func noContradictionForDifferentTypes() {
        let existing = MemoryEntry(agentId: "a", type: .preference, content: "Terence lives in LA", model: "m")
        let candidate = MemoryEntry(agentId: "a", type: .fact, content: "Terence lives in Irvine", model: "m")
        let existingTokens = [TextSimilarity.tokenize(existing.content)]
        let candidateTokens = TextSimilarity.tokenize(candidate.content)

        let result = service.findContradiction(
            entry: candidate,
            entryTokens: candidateTokens,
            existing: [existing],
            existingTokens: existingTokens
        )
        #expect(result == nil, "Preference vs fact should not contradict")
    }

    @Test func noContradictionForCompletelyDifferentContent() {
        let existing = MemoryEntry(agentId: "a", type: .fact, content: "Loves pizza", model: "m")
        let candidate = MemoryEntry(agentId: "a", type: .fact, content: "Terence lives in Irvine", model: "m")
        let existingTokens = [TextSimilarity.tokenize(existing.content)]
        let candidateTokens = TextSimilarity.tokenize(candidate.content)

        let result = service.findContradiction(
            entry: candidate,
            entryTokens: candidateTokens,
            existing: [existing],
            existingTokens: existingTokens
        )
        #expect(result == nil, "Completely different facts should not contradict")
    }

    @Test func crossTypeContradiction() {
        let existing = MemoryEntry(agentId: "a", type: .fact, content: "Terence lives in LA", model: "m")
        let candidate = MemoryEntry(agentId: "a", type: .correction, content: "Terence lives in Irvine", model: "m")
        let existingTokens = [TextSimilarity.tokenize(existing.content)]
        let candidateTokens = TextSimilarity.tokenize(candidate.content)

        let result = service.findContradiction(
            entry: candidate,
            entryTokens: candidateTokens,
            existing: [existing],
            existingTokens: existingTokens
        )
        #expect(result != nil, "Correction should contradict a fact with similar wording")
    }

    @Test func identicalContentNotContradiction() {
        let existing = MemoryEntry(agentId: "a", type: .fact, content: "Terence lives in LA", model: "m")
        let candidate = MemoryEntry(agentId: "a", type: .fact, content: "Terence lives in LA", model: "m")
        let existingTokens = [TextSimilarity.tokenize(existing.content)]
        let candidateTokens = TextSimilarity.tokenize(candidate.content)

        let result = service.findContradiction(
            entry: candidate,
            entryTokens: candidateTokens,
            existing: [existing],
            existingTokens: existingTokens
        )
        #expect(result == nil, "Identical content should not be flagged as contradiction")
    }
}
