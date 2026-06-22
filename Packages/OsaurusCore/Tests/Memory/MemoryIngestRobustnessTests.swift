//
//  MemoryIngestRobustnessTests.swift
//  osaurus
//
//  Coverage for the issue #1632 distillation/ingestion robustness fixes:
//  id-scoped signal marking (D2), bounded retries + dead-lettering (D1),
//  per-conversation idempotency deletes (I1), the stored-memory episode
//  count (U3), and the `DistillOutcome` -> API status mapping (A).
//
//  All DB tests use an in-memory `MemoryDatabase` (runs migrations through
//  v10 on open) so they're deterministic and don't touch the user's
//  on-disk memory store or any model runtime.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct MemoryIngestRobustnessTests {

    private func makeTempDB() throws -> MemoryDatabase {
        let db = MemoryDatabase()
        try db.openInMemory()
        return db
    }

    private func episode(_ agentId: String, _ conversationId: String, _ summary: String) -> Episode {
        Episode(
            agentId: agentId,
            conversationId: conversationId,
            summary: summary,
            tokenCount: 3,
            model: "test",
            conversationAt: "2025-01-01T00:00:00Z"
        )
    }

    // MARK: - D2: id-scoped marking

    @Test func markSignals_marksOnlyGivenIds() throws {
        let db = try makeTempDB()
        try db.insertPendingSignal(PendingSignal(agentId: "a", conversationId: "c", userMessage: "one"))
        try db.insertPendingSignal(PendingSignal(agentId: "a", conversationId: "c", userMessage: "two"))
        let loaded = try db.loadPendingSignals(conversationId: "c")
        #expect(loaded.count == 2)

        // Mark only the first signal processed.
        try db.markSignals(ids: [loaded[0].id], status: "processed")

        let remaining = try db.loadPendingSignals(conversationId: "c")
        #expect(remaining.count == 1)
        #expect(remaining[0].id == loaded[1].id)
        #expect(remaining[0].userMessage == "two")
    }

    @Test func markSignals_emptyIds_isNoOp() throws {
        let db = try makeTempDB()
        try db.insertPendingSignal(PendingSignal(agentId: "a", conversationId: "c", userMessage: "one"))
        try db.markSignals(ids: [], status: "processed")
        #expect(try db.loadPendingSignals(conversationId: "c").count == 1)
    }

    @Test func insertEpisodeAndMarkProcessed_leavesNewerSignalsPending() throws {
        let db = try makeTempDB()
        // The turn that the distiller snapshots.
        try db.insertPendingSignal(PendingSignal(agentId: "a", conversationId: "c", userMessage: "snapshotted"))
        let snapshot = try db.loadPendingSignals(conversationId: "c")
        #expect(snapshot.count == 1)

        // A turn buffered *during* the (simulated) LLM call.
        try db.insertPendingSignal(
            PendingSignal(agentId: "a", conversationId: "c", userMessage: "buffered mid-distill")
        )

        // Insert the episode marking only the snapshotted id.
        _ = try db.insertEpisodeAndMarkProcessed(
            episode("a", "c", "session summary"),
            signalIds: snapshot.map(\.id)
        )

        // The mid-distill turn survives as pending (lands in the next episode).
        let remaining = try db.loadPendingSignals(conversationId: "c")
        #expect(remaining.count == 1)
        #expect(remaining[0].userMessage == "buffered mid-distill")
        #expect(try db.loadEpisodes(agentId: "a").count == 1)
    }

    // MARK: - D1: bounded retries + dead-letter

    @Test func recordDistillFailure_incrementsAttempts_belowCap() throws {
        let db = try makeTempDB()
        try db.insertPendingSignal(PendingSignal(agentId: "a", conversationId: "c", userMessage: "x"))
        let ids = try db.loadPendingSignals(conversationId: "c").map(\.id)

        let first = try db.recordDistillFailure(ids: ids, maxAttempts: 3)
        #expect(first.attempts == 1)
        #expect(first.deadLettered == false)
        // Still pending — a transient failure must be retried.
        #expect(try db.loadPendingSignals(conversationId: "c").count == 1)

        let second = try db.recordDistillFailure(ids: ids, maxAttempts: 3)
        #expect(second.attempts == 2)
        #expect(second.deadLettered == false)
        #expect(try db.loadPendingSignals(conversationId: "c").count == 1)
    }

    @Test func recordDistillFailure_deadLettersAtCap_andDropsFromPending() throws {
        let db = try makeTempDB()
        try db.insertPendingSignal(PendingSignal(agentId: "a", conversationId: "c", userMessage: "x"))
        let ids = try db.loadPendingSignals(conversationId: "c").map(\.id)

        _ = try db.recordDistillFailure(ids: ids, maxAttempts: 2)
        let atCap = try db.recordDistillFailure(ids: ids, maxAttempts: 2)
        #expect(atCap.attempts == 2)
        #expect(atCap.deadLettered == true)

        // Dead-lettered signals must not be re-distilled.
        #expect(try db.loadPendingSignals(conversationId: "c").isEmpty)
        let stillPendingConvos = try db.pendingConversations().contains { $0.conversationId == "c" }
        #expect(stillPendingConvos == false)
    }

    @Test func recordDistillFailure_emptyIds_isNoOp() throws {
        let db = try makeTempDB()
        let result = try db.recordDistillFailure(ids: [], maxAttempts: 3)
        #expect(result.attempts == 0)
        #expect(result.deadLettered == false)
    }

    // MARK: - I1: per-conversation idempotency deletes

    @Test func deletePendingSignalsForConversation_clearsRegardlessOfStatus() throws {
        let db = try makeTempDB()
        try db.insertPendingSignal(PendingSignal(agentId: "a", conversationId: "c", userMessage: "pending"))
        try db.insertPendingSignal(PendingSignal(agentId: "a", conversationId: "c", userMessage: "to-process"))
        let ids = try db.loadPendingSignals(conversationId: "c").map(\.id)
        try db.markSignals(ids: [ids[0]], status: "processed")
        // One pending, one processed — both should be cleared.

        try db.deletePendingSignalsForConversation("c")
        #expect(try db.loadPendingSignals(conversationId: "c").isEmpty)
        // Re-buffering after the clear starts fresh.
        try db.insertPendingSignal(PendingSignal(agentId: "a", conversationId: "c", userMessage: "fresh"))
        #expect(try db.loadPendingSignals(conversationId: "c").count == 1)
    }

    @Test func deleteEpisodesForConversation_clearsThatConversationOnly() throws {
        let db = try makeTempDB()
        _ = try db.insertEpisode(episode("a", "c1", "first"))
        _ = try db.insertEpisode(episode("a", "c1", "duplicate of first"))
        _ = try db.insertEpisode(episode("a", "c2", "other conversation"))

        try db.deleteEpisodesForConversation("c1")

        let remaining = try db.loadEpisodes(agentId: "a")
        #expect(remaining.count == 1)
        #expect(remaining[0].conversationId == "c2")
    }

    // MARK: - U3: stored-memory episode count

    @Test func agentIdsWithEpisodes_countsActivePerAgent() throws {
        let db = try makeTempDB()
        _ = try db.insertEpisode(episode("agent-1", "c1", "s1"))
        _ = try db.insertEpisode(episode("agent-1", "c2", "s2"))
        _ = try db.insertEpisode(episode("agent-2", "c3", "s3"))

        let counts = Dictionary(
            uniqueKeysWithValues: try db.agentIdsWithEpisodes().map { ($0.agentId, $0.count) }
        )
        #expect(counts["agent-1"] == 2)
        #expect(counts["agent-2"] == 1)
    }

    // MARK: - A: DistillOutcome -> API status mapping

    @Test func distillOutcome_apiStatus_mapsEveryCase() {
        #expect(DistillOutcome.distilled(episodeId: 7, pinned: 1, identityFacts: 0).apiStatus == "distilled")
        #expect(DistillOutcome.noSignals.apiStatus == "no_signals")
        #expect(DistillOutcome.skipped(reason: "core_model_unset").apiStatus == "skipped:core_model_unset")
        #expect(DistillOutcome.empty(reason: "no_episode").apiStatus == "empty:no_episode")
        #expect(DistillOutcome.deadLettered(attempts: 3).apiStatus == "dead_letter:3")
        #expect(DistillOutcome.error("boom").apiStatus == "error:boom")
    }

    @Test func distillOutcome_episodeId_onlyForDistilled() {
        #expect(DistillOutcome.distilled(episodeId: 42, pinned: 0, identityFacts: 0).episodeId == 42)
        #expect(DistillOutcome.noSignals.episodeId == nil)
        #expect(DistillOutcome.skipped(reason: "not_resident").episodeId == nil)
        #expect(DistillOutcome.empty(reason: "empty_summary").episodeId == nil)
        #expect(DistillOutcome.deadLettered(attempts: 3).episodeId == nil)
        #expect(DistillOutcome.error("x").episodeId == nil)
    }
}
