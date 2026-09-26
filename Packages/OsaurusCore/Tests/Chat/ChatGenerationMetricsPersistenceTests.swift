import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ChatGenerationMetricsPersistenceTests {
    @Test @MainActor
    func displayedMetricsSurviveDTOAndJSONRoundTrip() throws {
        let turn = ChatTurn(role: .assistant, content: "A complete answer.")
        turn.generationTokenCount = 144
        turn.generationTokensPerSecond = 106.6
        turn.modelLoadSeconds = 0.4
        turn.timeToFirstToken = 0.62
        turn.lastOutputAt = Date(timeIntervalSince1970: 1002)
        turn.completedAt = Date(timeIntervalSince1970: 1012)
        let data = try JSONEncoder().encode(ChatTurnData(from: turn))
        let restored = ChatTurn(from: try JSONDecoder().decode(ChatTurnData.self, from: data))
        #expect(restored.id == turn.id)
        #expect(restored.generationTokensPerSecond == 106.6)
        #expect(restored.modelLoadSeconds == 0.4)
        #expect(restored.timeToFirstToken == 0.62)
        #expect(restored.lastOutputAt == turn.lastOutputAt)
        #expect(restored.completedAt == turn.completedAt)
    }

    @Test
    func legacyJSONDoesNotInventMeasurements() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"role\":\"assistant\",\"content\":\"old answer\"}"
        let turn = try JSONDecoder().decode(ChatTurnData.self, from: Data(json.utf8))
        #expect(turn.generationTokensPerSecond == nil)
        #expect(turn.modelLoadSeconds == nil)
        #expect(turn.lastOutputAt == nil)
    }

    @Test
    func eachLateMetricTriggersIncrementalSaveAndCanBeCleared() throws {
        let db = ChatHistoryDatabase()
        try db.openInMemory()
        defer { db.close() }
        var session = ChatSessionData(title: "metrics", turns: [ChatTurnData(role: .assistant, content: "answer")])
        try db.saveSession(session)
        let originalHash = ChatHistoryDatabase.contentHash(for: session.turns[0])
        session.turns[0].generationTokensPerSecond = 106.6
        #expect(ChatHistoryDatabase.contentHash(for: session.turns[0]) != originalHash)
        try db.saveSession(session)
        #expect(db.loadSession(id: session.id)?.turns[0].generationTokensPerSecond == 106.6)
        session.turns[0].modelLoadSeconds = 0
        try db.saveSession(session)
        #expect(db.loadSession(id: session.id)?.turns[0].modelLoadSeconds == 0)
        session.turns[0].lastOutputAt = Date(timeIntervalSince1970: 1002)
        try db.saveSession(session)
        #expect(db.loadSession(id: session.id)?.turns[0].lastOutputAt == session.turns[0].lastOutputAt)
        #expect(db.loadSession(id: session.id)?.turns[0].completedAt == nil)
        session.turns[0].generationTokensPerSecond = nil
        session.turns[0].modelLoadSeconds = nil
        session.turns[0].lastOutputAt = nil
        try db.saveSession(session)
        let cleared = try #require(db.loadSession(id: session.id)?.turns[0])
        #expect(cleared.generationTokensPerSecond == nil)
        #expect(cleared.modelLoadSeconds == nil)
        #expect(cleared.lastOutputAt == nil)
    }

    @Test @MainActor
    func exportPrefersRecordedRateAndKeepsLegacyFallback() {
        var turn = ChatTurnData(
            role: .assistant,
            content: "answer",
            createdAt: Date(timeIntervalSince1970: 1000),
            completedAt: Date(timeIntervalSince1970: 1020),
            lastOutputAt: Date(timeIntervalSince1970: 1010),
            generationTokenCount: 100,
            generationTokensPerSecond: 106.6
        )
        func export(_ turn: ChatTurnData) -> String {
            ChatSessionExporter.markdown(
                for: ChatSessionData(title: "metrics", turns: [turn]),
                options: ChatExportOptions(includeTokenUsage: true)
            )
        }
        #expect(export(turn).contains("106.6 tok/s"))
        turn.generationTokensPerSecond = nil
        #expect(export(turn).contains("10.0 tok/s"))
        turn.lastOutputAt = nil
        #expect(export(turn).contains("5.0 tok/s"))
        turn.generationTokenCount = nil
        #expect(!export(turn).contains("tok/s"))
        #expect(!ChatSessionExporter.markdown(for: ChatSessionData(title: "metrics", turns: [turn])).contains("tok/s"))
    }

    @Test
    func recordedRateMakesExportTimingAvailableWithoutLegacyFields() {
        let turn = ChatTurnData(role: .assistant, content: "answer", generationTokensPerSecond: 106.6)
        #expect(ChatSessionData(title: "metrics", turns: [turn]).hasAnyTimingData)
    }
}
