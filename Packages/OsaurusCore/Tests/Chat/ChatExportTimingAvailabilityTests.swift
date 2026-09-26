import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatExportTimingAvailabilityTests {
    @Test func metadataHydratesPersistedMetrics() async throws {
        let db = ChatHistoryDatabase()
        try db.openInMemory()
        defer { db.close() }
        let full = ChatSessionData(
            title: "Restored chat",
            turns: [ChatTurnData(role: .assistant, content: "Answer", generationTokensPerSecond: 42)]
        )
        try db.saveSession(full)
        let metadata = try #require(db.loadMetadata(ids: [full.id]).first)
        #expect(metadata.turns.isEmpty)
        var requested: UUID?
        let available = await ChatSessionExportCoordinator.hasTimingData(metadataSession: metadata) { id in
            requested = id
            return db.loadSession(id: id)
        }
        #expect(requested == metadata.id)
        #expect(available)
    }

    @Test func loadedMetricsDoNotNeedAnotherRead() async {
        let full = ChatSessionData(
            title: "Live chat",
            turns: [ChatTurnData(role: .assistant, content: "Answer", generationTokenCount: 8)]
        )
        var loaded = false
        let available = await ChatSessionExportCoordinator.hasTimingData(metadataSession: full) { _ in
            loaded = true
            return nil
        }
        #expect(available)
        #expect(!loaded)
    }

    @Test func untimedHistoryRemainsUnavailable() async {
        let metadata = ChatSessionData(title: "Imported chat", turns: [])
        var full = metadata
        full.turns = [ChatTurnData(role: .assistant, content: "Untimed answer")]
        let available = await ChatSessionExportCoordinator.hasTimingData(metadataSession: metadata) { _ in full }
        #expect(!available)
    }

    @Test func missingSessionDoesNotInventMetrics() async {
        let metadata = ChatSessionData(title: "Missing chat", turns: [])
        let available = await ChatSessionExportCoordinator.hasTimingData(metadataSession: metadata) { _ in nil }
        #expect(!available)
    }
}
