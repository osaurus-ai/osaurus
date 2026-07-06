//
//  MemoryManagementConsoleTests.swift
//  osaurus
//
//  Focused coverage for the Memory management console service.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Memory Management Console")
struct MemoryManagementConsoleTests {
    private let agentId = Agent.defaultId.uuidString

    private func makeDB() throws -> MemoryDatabase {
        let db = MemoryDatabase()
        try db.openInMemory()
        return db
    }

    @Test func searchReturnsPrivacySafeRowsWithRelevanceExplanation() throws {
        let db = try makeDB()
        let service = MemoryManagementConsoleService()
        try db.insertPinnedFact(
            PinnedFact(
                agentId: agentId,
                content: "Project OSIRIS contact is alex@example.com",
                salience: 0.92,
                tagsCSV: "osiris, planning"
            )
        )
        _ = try db.insertEpisode(
            Episode(
                agentId: agentId,
                conversationId: "conversation-1",
                summary: "We picked the OSIRIS release checklist.",
                topicsCSV: "OSIRIS, release",
                entitiesCSV: "OSIRIS",
                decisions: "Ship after privacy review",
                salience: 0.8,
                tokenCount: 42,
                model: "test",
                conversationAt: "2026-06-18T10:00:00Z"
            )
        )

        let results = try service.search(
            query: MemoryConsoleQuery(text: "osiris", scope: .all, agentId: agentId),
            db: db
        )

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.relevanceExplanation.lowercased().contains("osiris") })
        #expect(results.contains { $0.kind == .pinnedFact && $0.preview.text.contains("[redacted email]") })
        #expect(!results.contains { $0.preview.text.contains("alex@example.com") })
    }

    @Test func disablePinnedFactHidesItUnlessDisabledRowsAreIncluded() async throws {
        let db = try makeDB()
        let service = MemoryManagementConsoleService()
        let fact = PinnedFact(
            id: UUID().uuidString,
            agentId: agentId,
            content: "Remember Project Clover budget",
            salience: 0.7
        )
        try db.insertPinnedFact(fact)

        let disableResult = try await service.disable(itemId: "pinned:\(fact.id)", db: db)
        #expect(disableResult.changed)

        let activeOnly = try service.search(
            query: MemoryConsoleQuery(text: "clover", scope: .pinned, agentId: agentId),
            db: db
        )
        #expect(activeOnly.isEmpty)

        let includingDisabled = try service.search(
            query: MemoryConsoleQuery(
                text: "clover",
                scope: .pinned,
                agentId: agentId,
                includeDisabled: true
            ),
            db: db
        )
        #expect(includingDisabled.count == 1)
        #expect(includingDisabled[0].isDisabled)
        #expect(includingDisabled[0].canDisable == false)
    }

    @Test func forgetRemovesEpisodeAndTranscriptRows() async throws {
        let db = try makeDB()
        let service = MemoryManagementConsoleService()
        let episodeId = try db.insertEpisode(
            Episode(
                agentId: agentId,
                conversationId: "conversation-forget",
                summary: "We discussed the Atlas launch timeline.",
                topicsCSV: "Atlas",
                entitiesCSV: "Atlas",
                conversationAt: "2026-06-18T11:00:00Z"
            )
        )
        try db.insertTranscriptTurn(
            agentId: agentId,
            conversationId: "conversation-forget",
            chunkIndex: 0,
            role: "user",
            content: "Literal Atlas launch note",
            tokenCount: 5,
            title: "Atlas",
            createdAt: "2026-06-18T11:01:00Z"
        )

        let episodeForget = try await service.forget(itemId: "episode:\(episodeId)", db: db)
        #expect(episodeForget.changed)

        let transcript = try service.search(
            query: MemoryConsoleQuery(text: "literal atlas", scope: .transcript, agentId: agentId),
            db: db
        )
        #expect(transcript.count == 1)

        let transcriptForget = try await service.forget(itemId: transcript[0].id, db: db)
        #expect(transcriptForget.changed)

        let remaining = try service.search(
            query: MemoryConsoleQuery(text: "atlas", scope: .all, agentId: agentId),
            db: db
        )
        #expect(remaining.isEmpty)
    }

    @Test func diagnosticsReportStorageCountsAndSchemaHealth() async throws {
        let db = try makeDB()
        let service = MemoryManagementConsoleService()
        try db.insertPinnedFact(PinnedFact(agentId: agentId, content: "Active preference"))
        try db.insertPinnedFact(PinnedFact(agentId: agentId, content: "Disabled preference", status: "disabled"))
        _ = try db.insertEpisode(
            Episode(
                agentId: agentId,
                conversationId: "health-1",
                summary: "Active episode",
                conversationAt: "2026-06-18T12:00:00Z"
            )
        )
        _ = try db.insertEpisode(
            Episode(
                agentId: agentId,
                conversationId: "health-2",
                summary: "Disabled episode",
                conversationAt: "2026-06-18T12:10:00Z",
                status: "disabled"
            )
        )
        try db.insertTranscriptTurn(
            agentId: agentId,
            conversationId: "health-3",
            chunkIndex: 0,
            role: "user",
            content: "Health transcript",
            tokenCount: 3,
            createdAt: "2026-06-18T12:20:00Z"
        )

        let health = await service.diagnoseStorage(db: db, includeVectorState: false)

        #expect(health.databaseOpen)
        #expect(health.schemaVersion == health.expectedSchemaVersion)
        #expect(health.activePinnedCount == 1)
        #expect(health.disabledPinnedCount == 1)
        #expect(health.activeEpisodeCount == 1)
        #expect(health.disabledEpisodeCount == 1)
        #expect(health.transcriptCount == 1)
        #expect(health.ftsTablesReady)
    }

    @Test func diagnosticsExplainBufferedButSkippedDistillation() async throws {
        let db = try makeDB()
        let service = MemoryManagementConsoleService()
        try db.insertPendingSignal(
            PendingSignal(agentId: agentId, conversationId: "blocked-memory", userMessage: "Remember this")
        )
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "none",
            status: "skipped",
            details: "core_model_unset"
        )

        let health = await service.diagnoseStorage(db: db, includeVectorState: false)

        #expect(health.level == .degraded)
        #expect(health.pendingSignals.totalSignals == 1)
        #expect(health.processingStats.skippedCount == 1)
        #expect(health.diagnostics.contains("Turns are buffered, but distillation has only skipped so far."))
        #expect(health.diagnostics.contains("Chat turns reached memory, but no active episode has been written yet."))
    }

    @Test func diagnosticsExplainFailedEmptyAndDeadLetteredDistillation() async throws {
        let db = try makeDB()
        let service = MemoryManagementConsoleService()
        try db.insertPendingSignal(
            PendingSignal(agentId: agentId, conversationId: "dead-memory", userMessage: "Remember this")
        )
        let signals = try db.loadPendingSignals(conversationId: "dead-memory")
        _ = try db.recordDistillFailure(ids: signals.map(\.id), maxAttempts: 1)
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "test",
            status: "error",
            details: "model failed"
        )
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "test",
            status: "empty",
            details: "no episode"
        )
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "test",
            status: "dead_letter",
            details: "retry cap"
        )

        let health = await service.diagnoseStorage(db: db, includeVectorState: false)

        #expect(health.level == .degraded)
        #expect(health.pendingSignals.deadLetteredSignals == 1)
        #expect(health.processingStats.errorCount == 1)
        #expect(health.processingStats.emptyCount == 1)
        #expect(health.processingStats.deadLetterCount == 1)
        #expect(health.diagnostics.contains("Distillation recorded 1 error row(s)."))
        #expect(health.diagnostics.contains("Distillation recorded 1 empty result row(s)."))
        #expect(health.diagnostics.contains("Some memory signals were dead-lettered after repeated distillation failures."))
    }

    @Test func diagnosticsStayHealthyWithRecoveredErrorAndEmptyHistory() async throws {
        let db = try makeDB()
        let service = MemoryManagementConsoleService()
        _ = try db.insertEpisode(
            Episode(
                agentId: agentId,
                conversationId: "recovered-memory",
                summary: "A useful fact was stored after a transient failure.",
                conversationAt: "2026-06-18T13:00:00Z"
            )
        )
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "test",
            status: "error",
            details: "transient"
        )
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "test",
            status: "empty",
            details: "not memorable"
        )
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "test",
            status: "success",
            details: "recovered"
        )
        try db.insertPendingSignal(
            PendingSignal(agentId: agentId, conversationId: "active-chat", userMessage: "A new in-flight turn")
        )

        let health = await service.diagnoseStorage(db: db, includeVectorState: false)

        #expect(health.level == .healthy)
        #expect(health.activeEpisodeCount == 1)
        #expect(health.pendingSignals.totalSignals == 1)
        #expect(health.processingStats.successCount == 1)
        #expect(health.processingStats.errorCount == 1)
        #expect(health.processingStats.emptyCount == 1)
        #expect(health.diagnostics.isEmpty)
    }

    @Test func diagnosticsStayHealthyWithRecoveredDeadLetterHistory() async throws {
        let db = try makeDB()
        let service = MemoryManagementConsoleService()
        try db.insertPendingSignal(
            PendingSignal(agentId: agentId, conversationId: "recovered-dead", userMessage: "Remember this")
        )
        let signals = try db.loadPendingSignals(conversationId: "recovered-dead")
        _ = try db.recordDistillFailure(ids: signals.map(\.id), maxAttempts: 1)
        _ = try db.insertEpisode(
            Episode(
                agentId: agentId,
                conversationId: "later-success",
                summary: "Memory recovered after the retry cap.",
                conversationAt: "2026-06-18T14:00:00Z"
            )
        )
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "test",
            status: "dead_letter",
            details: "retry cap"
        )
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "test",
            status: "success",
            details: "recovered"
        )
        try db.insertPendingSignal(
            PendingSignal(agentId: agentId, conversationId: "active-chat", userMessage: "A new in-flight turn")
        )

        let health = await service.diagnoseStorage(db: db, includeVectorState: false)

        #expect(health.level == .healthy)
        #expect(health.activeEpisodeCount == 1)
        #expect(health.pendingSignals.totalSignals == 1)
        #expect(health.pendingSignals.deadLetteredSignals == 1)
        #expect(health.processingStats.successCount == 1)
        #expect(health.processingStats.deadLetterCount == 1)
        #expect(health.diagnostics.isEmpty)
    }

    @Test func diagnosticsDegradeWhenLatestFailureFollowsRecovery() async throws {
        let db = try makeDB()
        let service = MemoryManagementConsoleService()
        _ = try db.insertEpisode(
            Episode(
                agentId: agentId,
                conversationId: "already-working",
                summary: "Memory was working before this failure.",
                conversationAt: "2026-06-18T15:00:00Z"
            )
        )
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "test",
            status: "success",
            details: "worked"
        )
        try db.insertProcessingLog(
            agentId: agentId,
            taskType: "distill",
            model: "test",
            status: "error",
            details: "fresh failure"
        )

        let health = await service.diagnoseStorage(db: db, includeVectorState: false)

        #expect(health.level == .degraded)
        #expect(health.activeEpisodeCount == 1)
        #expect(health.processingStats.successCount == 1)
        #expect(health.processingStats.errorCount == 1)
        #expect(health.diagnostics.contains("Distillation recorded 1 error row(s)."))
    }

    @Test func privacyRedactorMasksSensitiveValuesAndBoundsPreview() {
        let sensitive = """
            Email alex@example.com, phone 415-555-1212, SSN 123-45-6789,
            account 4242 4242 4242 4242, token sk-test_abcdefghijklmnopqrstuvwxyz1234567890,
            url https://example.com/private/path
            """

        let redacted = MemoryPrivacyRedactor.redact(sensitive, maxCharacters: 120)

        #expect(redacted.wasTruncated)
        #expect(redacted.text.count <= 120)
        #expect(!redacted.text.contains("alex@example.com"))
        #expect(!redacted.text.contains("415-555-1212"))
        #expect(!redacted.text.contains("123-45-6789"))
        #expect(!redacted.text.contains("4242 4242 4242 4242"))
        #expect(!redacted.text.contains("sk-test_abcdefghijklmnopqrstuvwxyz1234567890"))
        #expect(redacted.redactionCounts["email"] == 1)
        #expect(redacted.redactionCounts["phone"] == 1)
        #expect(redacted.redactionCounts["ssn"] == 1)
        #expect(redacted.redactionCounts["account"] == 1)
        #expect(redacted.redactionCounts["secret"] == 1)
        #expect((redacted.redactionCounts["url"] ?? 0) >= 1)
    }
}
