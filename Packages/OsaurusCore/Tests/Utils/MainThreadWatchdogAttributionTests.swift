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
//  Robustness under the full parallel suite: other suites block the main
//  thread too (every MainActor test does), so this watchdog instance also
//  breaches on stalls that are not ours and overwrites the record file with
//  snapshots that don't contain our operation. Two countermeasures:
//  - each test injects a PRIVATE diagnostics directory, so parallel suites
//    that re-point `OsaurusPaths.overrideRoot` can't move the file; and
//  - the assertion polls for *any* persisted record naming our operation
//    rather than trusting the first (or last) record it happens to read.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct MainThreadWatchdogAttributionTests {

    private struct StallRecord: Decodable {
        struct Entry: Decodable {
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

    @Test
    func breachPersistsRecordNamingTheInstrumentedOperation() async throws {
        let dir = try Self.makePrivateDiagnosticsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watchdog = MainThreadWatchdog(threshold: 0.2, diagnosticsDirectory: dir)
        watchdog.start()
        defer { watchdog.stop() }

        // Inject the fault: hold the main thread hostage for ~1s with an
        // instrumented operation active — the shape of a wedged Keychain
        // read or database query on the UI thread. The watchdog ticks at
        // 0.2s, so several breach snapshots land while our op is active.
        await MainActor.run {
            let token = MainThreadOperationLedger.shared.begin(
                subsystem: "fault-injection", operation: "blocked-main"
            )
            Thread.sleep(forTimeInterval: 1.0)
            MainThreadOperationLedger.shared.end(token)
        }

        // Poll until we observe a record that names our operation. Records
        // from foreign stalls (other suites blocking the main thread) may
        // interleave and overwrite the file; only a record containing our
        // fault-injection entry proves attribution, so keep sampling.
        var matched: StallRecord?
        var lastSeen: StallRecord?
        for _ in 0..<160 {
            if let record = Self.readRecord(in: dir) {
                lastSeen = record
                if record.operations.contains(where: {
                    $0.subsystem == "fault-injection" && $0.operation == "blocked-main"
                }) {
                    matched = record
                    break
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let stall = try #require(
            matched,
            "no persisted stall record named the instrumented operation; last record: \(String(describing: lastSeen?.operations))"
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
        await MainActor.run {
            Thread.sleep(forTimeInterval: 0.8)
        }

        var record: StallRecord?
        for _ in 0..<160 {
            if let decoded = Self.readRecord(in: dir) {
                record = decoded
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let stall = try #require(record, "watchdog never persisted a stall record")
        #expect(stall.thresholdSeconds == 0.2)
        #expect(
            !stall.operations.contains { $0.subsystem == "fault-injection" },
            "private diagnostics dir leaked a record from another test"
        )
    }
}
