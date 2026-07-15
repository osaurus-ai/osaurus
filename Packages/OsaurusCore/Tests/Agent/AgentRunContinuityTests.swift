//
//  AgentRunContinuityTests.swift
//  OsaurusCoreTests
//

import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AgentRunContinuityTests {
    @Test func activityDurationNeverRendersNegativeTime() {
        let start = Date(timeIntervalSince1970: 100)

        #expect(ActivityRunDurationFormatter.label(from: start, to: start.addingTimeInterval(3.25)) == "3.2s")
        #expect(ActivityRunDurationFormatter.label(from: start, to: start.addingTimeInterval(-1)) == "n/a")
    }

    @Test func versionOneDatabaseMigratesWithoutLosingRuns() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-run-continuity-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
                try? FileManager.default.removeItem(at: root)
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared.wipeCache()

            let agentId = UUID()
            let runId = UUID()
            try Self.seedVersionOneDatabase(agentId: agentId, runId: runId)

            let database = SchedulerDatabase()
            try database.open()
            defer { database.close() }

            let run = try #require(database.runs(agentId: agentId).first)
            #expect(run.id == runId)
            #expect(run.sessionId == nil)
            #expect(Self.diskSchemaVersion() == 2)
            #expect(Self.diskRunColumns().contains("session_id"))
        }
    }

    @Test func partialVersionTwoMigrationRepairsSchemaVersion() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-run-partial-migration-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                StorageEncryptionPolicy.shared.invalidateCache()
                StorageKeyManager.shared.wipeCache()
                try? FileManager.default.removeItem(at: root)
            }
            try StorageEncryptionPolicy.shared.setDesiredMode(.plaintext)
            StorageKeyManager.shared.wipeCache()

            let agentId = UUID()
            try Self.seedVersionOneDatabase(
                agentId: agentId,
                runId: UUID(),
                includeSessionColumn: true
            )

            let database = SchedulerDatabase()
            try database.open()
            defer { database.close() }

            #expect(try database.runs(agentId: agentId).count == 1)
            #expect(Self.diskSchemaVersion() == 2)
            #expect(Self.diskRunColumns().contains("session_id"))
        }
    }

    @Test func runRoundTripPreservesSessionAndInterruptedStatus() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let agentId = UUID()
        let sessionId = UUID()
        let runId = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "Prepare the report",
            sessionId: sessionId
        )
        try database.recordRunEnd(runId: runId, status: .interrupted)

        let run = try #require(database.runs(agentId: agentId).first)
        #expect(run.id == runId)
        #expect(run.sessionId == sessionId)
        #expect(run.status == .interrupted)
        #expect(run.error == nil)
    }

    @Test func reconciliationOnlyInterruptsOrphanedPreProcessRows() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let agentId = UUID()
        let processStartedAt = Date(timeIntervalSince1970: 10_000)
        let oldStart = processStartedAt.addingTimeInterval(-10)
        let currentStart = processStartedAt.addingTimeInterval(10)
        let orphan = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .watcher,
            instructions: "orphan",
            startedAt: oldStart
        )
        let sameSecondOrphan = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .watcher,
            instructions: "same-second orphan",
            startedAt: processStartedAt
        )
        let active = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "active",
            startedAt: oldStart
        )
        let current = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "current process",
            startedAt: currentStart
        )
        let completed = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .schedule,
            instructions: "complete",
            startedAt: oldStart
        )
        try database.recordRunEnd(runId: completed, status: .success)

        let endedAt = processStartedAt.addingTimeInterval(20)
        let changed = try database.reconcileInterruptedRuns(
            startedBefore: processStartedAt,
            excluding: [active],
            endedAt: endedAt
        )
        let byId = Dictionary(uniqueKeysWithValues: try database.runs(agentId: agentId).map {
            ($0.id, $0)
        })

        #expect(changed == 2)
        #expect(byId[orphan]?.status == .interrupted)
        #expect(byId[sameSecondOrphan]?.status == .interrupted)
        #expect(byId[orphan]?.endedAt == endedAt)
        #expect(byId[orphan]?.error == nil)
        #expect(byId[active]?.status == .running)
        #expect(byId[current]?.status == .running)
        #expect(byId[completed]?.status == .success)
        #expect(
            try database.reconcileInterruptedRuns(
                startedBefore: processStartedAt,
                excluding: [active],
                endedAt: endedAt.addingTimeInterval(10)
            ) == 0
        )
    }

    @Test func schedulerReconcilesInterruptedRunsBeforeColdStartDispatch() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Managers/NextRunScheduler.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let reconciliation = try #require(
            source.range(of: "guard await reconcileInterruptedRunsIfNeeded() else")
        )
        let dispatch = try #require(source.range(of: "await dispatchDueRows()"))
        #expect(reconciliation.lowerBound < dispatch.lowerBound)
        #expect(source.contains("startupReconciliationGate.run"))
        #expect(source.contains("excluding: liveRunIds"))
        #expect(source.contains("includingBoundary: false"))
    }

    @Test
    @MainActor
    func startupGateRetriesAfterFailureAndCompletesOnlyOnce() async {
        let gate = AgentRunStartupReconciliationGate()

        let failed = await gate.run {
            throw StartupGateTestError.unavailable
        }
        #expect(failed == .failed(message: "temporarily unavailable"))
        #expect(!gate.didSucceed)

        let completed = await gate.run { 3 }
        #expect(completed == .completed(changed: 3))
        #expect(gate.didSucceed)

        let duplicate = await gate.run {
            Issue.record("completed reconciliation must not run twice")
            return 99
        }
        #expect(duplicate == .alreadyCompleted)
    }

    @Test func strictStartupBoundaryLeavesCurrentLaunchSecondUntouched() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let agentId = UUID()
        let processStartedAt = Date(timeIntervalSince1970: 20_000)
        let orphan = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .watcher,
            instructions: "prior process",
            startedAt: processStartedAt.addingTimeInterval(-1)
        )
        let launchSecond = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .user,
            instructions: "current process",
            startedAt: processStartedAt
        )

        #expect(
            try database.reconcileInterruptedRuns(
                startedBefore: processStartedAt,
                excluding: [],
                includingBoundary: false
            ) == 1
        )
        let byId = Dictionary(uniqueKeysWithValues: try database.runs(agentId: agentId).map {
            ($0.id, $0)
        })
        #expect(byId[orphan]?.status == .interrupted)
        #expect(byId[launchSecond]?.status == .running)
    }

    @Test func skippedRunWithoutSessionDoesNotInventChatLink() throws {
        let database = SchedulerDatabase()
        try database.openInMemory()
        defer { database.close() }

        let agentId = UUID()
        let runId = try database.recordRunStart(
            agentId: agentId,
            triggerKind: .schedule,
            triggerPayload: "missed",
            instructions: "scheduled work"
        )
        try database.recordRunEnd(runId: runId, status: .cancelled)

        let run = try #require(database.runs(agentId: agentId).first)
        #expect(run.sessionId == nil)
        #expect(run.status == .cancelled)
    }

    @Test func filtersUseManagerLivenessAndHonestTerminalGroups() {
        let live = Self.run(status: .running, instructions: "live report")
        let stale = Self.run(status: .running, instructions: "stale report")
        let success = Self.run(status: .success, instructions: "completed report")
        let failure = Self.run(status: .error, instructions: "provider failed")
        let interrupted = Self.run(status: .interrupted, instructions: "restart recovery")
        let cancelled = Self.run(status: .cancelled, instructions: "user stopped")
        let liveIds: Set<UUID> = [live.id]

        #expect(ActivityRunFilter.active.includes(live, liveRunIds: liveIds))
        #expect(!ActivityRunFilter.active.includes(stale, liveRunIds: liveIds))
        #expect(ActivityRunFilter.completed.includes(success, liveRunIds: liveIds))
        #expect(ActivityRunFilter.attention.includes(failure, liveRunIds: liveIds))
        #expect(ActivityRunFilter.attention.includes(interrupted, liveRunIds: liveIds))
        #expect(!ActivityRunFilter.attention.includes(cancelled, liveRunIds: liveIds))
        #expect(ActivityRunFilter.all.includes(cancelled, liveRunIds: liveIds))
    }

    @Test func runSearchMatchesStatusTriggerAndInstructions() {
        let run = Self.run(
            status: .interrupted,
            triggerKind: .watcher,
            instructions: "Prepare quarterly forecast"
        )

        #expect(ActivityRunFilter.matchesSearch(run, searchText: "interrupted"))
        #expect(ActivityRunFilter.matchesSearch(run, searchText: "WATCHER"))
        #expect(ActivityRunFilter.matchesSearch(run, searchText: "quarterly"))
        #expect(!ActivityRunFilter.matchesSearch(run, searchText: "invoice"))
    }

    @Test func interruptedScheduleHistoryMapsToCancelled() {
        #expect(ScheduleRunStatus(.interrupted) == .cancelled)
    }

    @Test func chatOwnershipNormalizesLegacyDefaultAgentSessions() {
        #expect(
            ActivityRunChatRouting.sessionBelongsToRun(
                sessionAgentId: nil,
                runAgentId: Agent.defaultId
            )
        )
        #expect(
            !ActivityRunChatRouting.sessionBelongsToRun(
                sessionAgentId: nil,
                runAgentId: UUID()
            )
        )
        let custom = UUID()
        #expect(
            ActivityRunChatRouting.sessionBelongsToRun(
                sessionAgentId: custom,
                runAgentId: custom
            )
        )
    }

    private static func run(
        status: AgentRunStatus,
        triggerKind: AgentRunTriggerKind = .user,
        instructions: String
    ) -> AgentRunRecord {
        AgentRunRecord(
            id: UUID(),
            agentId: UUID(),
            triggerKind: triggerKind,
            instructions: instructions,
            startedAt: Date(),
            status: status
        )
    }

    private enum StartupGateTestError: LocalizedError {
        case unavailable

        var errorDescription: String? { "temporarily unavailable" }
    }

    private static func seedVersionOneDatabase(
        agentId: UUID,
        runId: UUID,
        includeSessionColumn: Bool = false
    ) throws {
        let path = OsaurusPaths.schedulerDatabaseFile().path
        let connection = try EncryptedSQLiteOpener.open(path: path, key: nil)
        defer { sqlite3_close(connection) }
        let sessionColumn = includeSessionColumn ? ", session_id TEXT" : ""
        try execute(
            connection,
            """
            CREATE TABLE agent_runs (
                id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, trigger_kind TEXT NOT NULL,
                trigger_payload TEXT, instructions TEXT NOT NULL, started_at INTEGER NOT NULL,
                ended_at INTEGER, status TEXT NOT NULL, tokens_in INTEGER, tokens_out INTEGER,
                cost_usd REAL, error TEXT\(sessionColumn)
            )
            """
        )
        try execute(
            connection,
            """
            INSERT INTO agent_runs
                (id, agent_id, trigger_kind, instructions, started_at, status)
            VALUES ('\(runId.uuidString)', '\(agentId.uuidString)', 'user',
                    'legacy run', 1000, 'success')
            """
        )
        try execute(connection, "PRAGMA user_version = 1")
    }

    private static func diskSchemaVersion() -> Int {
        withDiskConnection(-1) { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &statement, nil)
                == SQLITE_OK
            else { return -1 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW
                ? Int(sqlite3_column_int(statement, 0))
                : -1
        }
    }

    private static func diskRunColumns() -> Set<String> {
        withDiskConnection([]) { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                "PRAGMA table_info(agent_runs)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var columns: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 1) {
                    columns.insert(String(cString: text))
                }
            }
            return columns
        }
    }

    private static func withDiskConnection<T>(
        _ fallback: T,
        _ body: (OpaquePointer) -> T
    ) -> T {
        guard let connection = try? EncryptedSQLiteOpener.open(
            path: OsaurusPaths.schedulerDatabaseFile().path,
            key: nil,
            applyPerfPragmas: false,
            applyForeignKeys: false
        ) else { return fallback }
        defer { sqlite3_close(connection) }
        return body(connection)
    }

    private static func execute(_ connection: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(error)
            throw NSError(
                domain: "AgentRunContinuityTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
