//
//  MainThreadWatchdogAttributionTests.swift
//  OsaurusCoreTests
//
//  Fault injection for the watchdog-attribution pipeline: block the REAL
//  main thread past a short watchdog threshold while a ledger-instrumented
//  operation is in flight, and assert the persisted last-stall diagnostic
//  names that operation. This is the contract that turns a field "app
//  hang" report into an actionable subsystem/operation pair.
//
//  Keep the fault active until the background watchdog has persisted its
//  record. A fixed-duration fault can finish before a cold/contended timer
//  gets its first callback; polling afterward cannot recover a record that
//  was never written. Reading while the fault is still active also avoids
//  another stall overwriting the last-record file before the assertion runs.
//  Each test uses a private directory, independent of OsaurusPaths overrides.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct MainThreadWatchdogAttributionTests {

    private struct StallRecord: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            let subsystem: String
            let operation: String
        }
        let thresholdSeconds: TimeInterval
        let operations: [Entry]
    }

    private static func makePrivateDiagnosticsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-watchdog-attr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func readRecord(in dir: URL) -> StallRecord? {
        let url = dir.appendingPathComponent("last-main-thread-stall.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StallRecord.self, from: data)
    }

    /// The polling itself is the injected main-thread fault. Release it only
    /// after observing the persisted record, with a bounded failure deadline.
    private static func waitForRecordWhileMainIsBlocked(
        in dir: URL,
        matching predicate: (StallRecord) -> Bool
    ) -> (matched: StallRecord?, lastSeen: StallRecord?) {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var lastSeen: StallRecord?
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let record = readRecord(in: dir) {
                lastSeen = record
                if predicate(record) { return (record, record) }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return (nil, lastSeen)
    }

    @Test
    func breachPersistsRecordNamingTheInstrumentedOperation() async throws {
        let dir = try Self.makePrivateDiagnosticsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watchdog = MainThreadWatchdog(threshold: 0.2, diagnosticsDirectory: dir)
        watchdog.start()
        defer { watchdog.stop() }

        // Hold the actual main-thread fault until its attribution is on disk,
        // rather than guessing when the background timer will be scheduled.
        let observed = await MainActor.run {
            let token = MainThreadOperationLedger.shared.begin(
                subsystem: "fault-injection",
                operation: "blocked-main"
            )
            defer { MainThreadOperationLedger.shared.end(token) }
            return Self.waitForRecordWhileMainIsBlocked(in: dir) { record in
                record.operations.contains(where: {
                    $0.subsystem == "fault-injection" && $0.operation == "blocked-main"
                })
            }
        }

        let stall = try #require(
            observed.matched,
            "no persisted stall record named the instrumented operation; last record: \(String(describing: observed.lastSeen?.operations))"
        )
        #expect(stall.thresholdSeconds == 0.2)
    }

    @Test
    func breachWithNoInstrumentedOperationStillPersists() async throws {
        let dir = try Self.makePrivateDiagnosticsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watchdog = MainThreadWatchdog(threshold: 0.2, diagnosticsDirectory: dir)
        watchdog.start()
        defer { watchdog.stop() }

        // Uninstrumented stall: the record must still be written — that
        // volume is the signal that ledger coverage is missing where users
        // actually hang. Under the parallel suite another test's
        // instrumented main-thread operation may be in flight during our
        // block, so the only portable assertion is that a record persists
        // (with whatever the ledger held at breach time), not that the
        // operations list is empty.
        let observed = await MainActor.run {
            Self.waitForRecordWhileMainIsBlocked(in: dir) { _ in true }
        }
        let stall = try #require(observed.matched, "watchdog never persisted a stall record")
        #expect(stall.thresholdSeconds == 0.2)
        #expect(
            !stall.operations.contains { $0.subsystem == "fault-injection" },
            "private diagnostics dir leaked a record from another test"
        )
    }
}
