//
//  MethodDatabaseTests.swift
//  osaurus
//
//  Unit tests for MethodDatabase: CRUD roundtrips, score formula,
//  event persistence, and migration verification.
//

import Foundation
import Testing

@testable import OsaurusCore

private typealias Method = OsaurusCore.Method

struct MethodDatabaseTests {

    private func makeTempDB() throws -> MethodDatabase {
        let db = MethodDatabase()
        try db.openInMemory()
        return db
    }

    private func sampleMethod(
        id: String = UUID().uuidString,
        name: String = "test-method",
        toolsUsed: [String] = ["terminal"],
        body: String = "steps:\n  - tool: terminal\n    action: echo hello"
    ) -> Method {
        OsaurusCore.Method(
            id: id,
            name: name,
            description: "A test method",
            triggerText: "test trigger",
            body: body,
            source: MethodSource.user,
            sourceModel: "test-model",
            toolsUsed: toolsUsed,
            skillsUsed: [],
            tokenCount: 100
        )
    }

    // MARK: - Method CRUD

    @Test func insertAndLoadMethodRoundtrip() throws {
        let db = try makeTempDB()
        let method = sampleMethod()
        try db.insertMethod(method)

        let loaded = try db.loadMethod(id: method.id)
        #expect(loaded != nil)
        #expect(loaded?.id == method.id)
        #expect(loaded?.name == method.name)
        #expect(loaded?.description == method.description)
        #expect(loaded?.triggerText == method.triggerText)
        #expect(loaded?.body == method.body)
        #expect(loaded?.source == .user)
        #expect(loaded?.sourceModel == "test-model")
        #expect(loaded?.tier == .active)
        #expect(loaded?.toolsUsed == ["terminal"])
        #expect(loaded?.tokenCount == 100)
        #expect(loaded?.version == 1)
    }

    @Test func updateMethodChangesPersisted() throws {
        let db = try makeTempDB()
        var method = sampleMethod()
        try db.insertMethod(method)

        method.name = "updated-name"
        method.body = "steps:\n  - tool: web_fetch\n    action: GET /health"
        method.toolsUsed = ["web_fetch"]
        method.version = 2
        try db.updateMethod(method)

        let loaded = try db.loadMethod(id: method.id)
        #expect(loaded?.name == "updated-name")
        #expect(loaded?.body.contains("web_fetch") == true)
        #expect(loaded?.toolsUsed == ["web_fetch"])
        #expect(loaded?.version == 2)
    }

    @Test func deleteMethodRemovesFromDB() throws {
        let db = try makeTempDB()
        let method = sampleMethod()
        try db.insertMethod(method)
        #expect(try db.loadMethod(id: method.id) != nil)

        try db.deleteMethod(id: method.id)
        #expect(try db.loadMethod(id: method.id) == nil)
    }

    @Test func loadAllMethodsReturnsAll() throws {
        let db = try makeTempDB()
        try db.insertMethod(sampleMethod(id: "1", name: "m1"))
        try db.insertMethod(sampleMethod(id: "2", name: "m2"))
        try db.insertMethod(sampleMethod(id: "3", name: "m3"))

        let all = try db.loadAllMethods()
        #expect(all.count == 3)
    }

    @Test func loadMethodsByIdsReturnsMatching() throws {
        let db = try makeTempDB()
        try db.insertMethod(sampleMethod(id: "a", name: "alpha"))
        try db.insertMethod(sampleMethod(id: "b", name: "beta"))
        try db.insertMethod(sampleMethod(id: "c", name: "gamma"))

        let result = try db.loadMethodsByIds(["a", "c"])
        #expect(result.count == 2)
        let names = Set(result.map(\.name))
        #expect(names.contains("alpha"))
        #expect(names.contains("gamma"))
    }

    @Test func loadMethodsByIdsEmptyArrayReturnsEmpty() throws {
        let db = try makeTempDB()
        let result = try db.loadMethodsByIds([])
        #expect(result.isEmpty)
    }

    @Test func loadMethodNotFoundReturnsNil() throws {
        let db = try makeTempDB()
        #expect(try db.loadMethod(id: "nonexistent") == nil)
    }

    // MARK: - Events

    @Test func insertAndLoadEventsRoundtrip() throws {
        let db = try makeTempDB()
        let method = sampleMethod()
        try db.insertMethod(method)

        let loadedEvent = MethodEvent(methodId: method.id, eventType: .loaded, agentId: "issue-1")
        try db.insertEvent(loadedEvent)

        let succeededEvent = MethodEvent(methodId: method.id, eventType: .succeeded, modelUsed: "opus")
        try db.insertEvent(succeededEvent)

        let allEvents = try db.loadEvents(methodId: method.id)
        #expect(allEvents.count == 2)

        let loadedOnly = try db.loadEvents(methodId: method.id, ofType: .loaded)
        #expect(loadedOnly.count == 1)
        #expect(loadedOnly[0].agentId == "issue-1")

        let succeededOnly = try db.loadEvents(methodId: method.id, ofType: .succeeded)
        #expect(succeededOnly.count == 1)
        #expect(succeededOnly[0].modelUsed == "opus")
    }

    // MARK: - Scores

    @Test func upsertAndLoadScoreRoundtrip() throws {
        let db = try makeTempDB()
        let method = sampleMethod()
        try db.insertMethod(method)

        var score = MethodScore(
            methodId: method.id,
            timesLoaded: 10,
            timesSucceeded: 8,
            timesFailed: 2,
            successRate: 0.8,
            lastUsedAt: Date(),
            score: 0.75
        )
        try db.upsertScore(score)

        let loaded = try db.loadScore(methodId: method.id)
        #expect(loaded != nil)
        #expect(loaded?.timesLoaded == 10)
        #expect(loaded?.timesSucceeded == 8)
        #expect(loaded?.timesFailed == 2)
        #expect(abs((loaded?.successRate ?? 0) - 0.8) < 0.001)

        score.timesSucceeded = 9
        score.successRate = 0.818
        try db.upsertScore(score)

        let updated = try db.loadScore(methodId: method.id)
        #expect(updated?.timesSucceeded == 9)
    }

    @Test func insertMethodCreatesDefaultScore() throws {
        let db = try makeTempDB()
        let method = sampleMethod()
        try db.insertMethod(method)

        let score = try db.loadScore(methodId: method.id)
        #expect(score != nil)
        #expect(score?.timesLoaded == 0)
        #expect(score?.timesSucceeded == 0)
        #expect(score?.score == 0.0)
    }

    // MARK: - Score Formula

    @Test func recalculateScoreFormula() {
        var score = MethodScore(
            methodId: "test",
            timesLoaded: 10,
            timesSucceeded: 8,
            timesFailed: 2,
            lastUsedAt: Date().addingTimeInterval(-5 * 86400)
        )
        score.recalculate()

        let expectedSuccessRate = 8.0 / 10.0
        #expect(abs(score.successRate - expectedSuccessRate) < 0.001)

        let expectedRecency = 1.0 / (1.0 + 5.0 / 30.0)
        let expectedScore = expectedSuccessRate * expectedRecency
        #expect(abs(score.score - expectedScore) < 0.01)
    }

    @Test func recalculateScoreWithNoUses() {
        var score = MethodScore(methodId: "test")
        score.recalculate()
        #expect(score.successRate == 0.0)
        #expect(score.score == 0.0)
    }

    @Test func recalculateScoreWithNoLastUsed() {
        var score = MethodScore(
            methodId: "test",
            timesSucceeded: 5,
            timesFailed: 0,
            lastUsedAt: nil
        )
        score.recalculate()
        #expect(score.successRate == 1.0)
        let recency = 1.0 / (1.0 + 365.0 / 30.0)
        #expect(abs(score.score - recency) < 0.01)
    }

    // MARK: - Migrations

    @Test func openInMemoryCreatesSchema() throws {
        let db = try makeTempDB()

        try db.insertMethod(sampleMethod())
        let methods = try db.loadAllMethods()
        #expect(methods.count == 1)

        let event = MethodEvent(methodId: methods[0].id, eventType: .loaded)
        try db.insertEvent(event)
        let events = try db.loadEvents(methodId: methods[0].id)
        #expect(events.count == 1)

        let score = try db.loadScore(methodId: methods[0].id)
        #expect(score != nil)
    }

    // MARK: - Cascade Deletes

    @Test func deleteMethodCascadesToEventsAndScores() throws {
        let db = try makeTempDB()
        let method = sampleMethod()
        try db.insertMethod(method)
        try db.insertEvent(MethodEvent(methodId: method.id, eventType: .loaded))
        try db.insertEvent(MethodEvent(methodId: method.id, eventType: .succeeded))

        try db.deleteMethod(id: method.id)

        let events = try db.loadEvents(methodId: method.id)
        #expect(events.isEmpty)

        let score = try db.loadScore(methodId: method.id)
        #expect(score == nil)
    }

    // MARK: - JSON Array Storage

    @Test func toolsUsedPersistsAsJSON() throws {
        let db = try makeTempDB()
        let method = sampleMethod(toolsUsed: ["terminal", "web_fetch", "sandbox_execute_code"])
        try db.insertMethod(method)

        let loaded = try db.loadMethod(id: method.id)
        #expect(loaded?.toolsUsed == ["terminal", "web_fetch", "sandbox_execute_code"])
    }

    @Test func emptyToolsUsedPersists() throws {
        let db = try makeTempDB()
        let method = sampleMethod(toolsUsed: [])
        try db.insertMethod(method)

        let loaded = try db.loadMethod(id: method.id)
        #expect(loaded?.toolsUsed.isEmpty == true)
    }
}
