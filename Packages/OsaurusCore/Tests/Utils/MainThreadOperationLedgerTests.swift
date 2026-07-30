//
//  MainThreadOperationLedgerTests.swift
//  OsaurusCoreTests
//
//  Pins the watchdog-attribution contract: instrumented main-thread
//  operations appear in the ledger for exactly their duration, off-main
//  callers are never recorded (blocking off-main is not a hang), and the
//  snapshot orders entries oldest-first so the watchdog's "primary suspect"
//  is the longest-running operation.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct MainThreadOperationLedgerTests {

    @Test
    func beginEndBracketsEntryLifetime() {
        let ledger = MainThreadOperationLedger()
        #expect(ledger.snapshot().isEmpty)

        let token = ledger.begin(subsystem: "test", operation: "op-a")
        let active = ledger.snapshot()
        #expect(active.count == 1)
        #expect(active.first?.subsystem == "test")
        #expect(active.first?.operation == "op-a")

        ledger.end(token)
        #expect(ledger.snapshot().isEmpty)
    }

    @Test
    func snapshotOrdersOldestFirst() {
        let ledger = MainThreadOperationLedger()
        let first = ledger.begin(subsystem: "test", operation: "older")
        // Distinct timestamps: Date resolution is comfortably sub-millisecond.
        Thread.sleep(forTimeInterval: 0.01)
        let second = ledger.begin(subsystem: "test", operation: "newer")

        let snapshot = ledger.snapshot()
        #expect(snapshot.map(\.operation) == ["older", "newer"])
        #expect(ledger.oldestActive()?.operation == "older")

        ledger.end(first)
        ledger.end(second)
    }

    @Test
    @MainActor
    func withMainThreadOperationRecordsOnMainThread() {
        let ledger = MainThreadOperationLedger()
        var observedDuringBody: [MainThreadOperationLedger.Entry] = []
        ledger.withMainThreadOperation(subsystem: "keychain", operation: "read") {
            observedDuringBody = ledger.snapshot()
        }
        #expect(observedDuringBody.count == 1)
        #expect(observedDuringBody.first?.subsystem == "keychain")
        #expect(ledger.snapshot().isEmpty, "entry must be removed when the body returns")
    }

    @Test
    func withMainThreadOperationBypassesLedgerOffMain() async {
        let ledger = MainThreadOperationLedger()
        let observed = await Task.detached {
            ledger.withMainThreadOperation(subsystem: "keychain", operation: "read") {
                ledger.snapshot().count
            }
        }.value
        #expect(observed == 0, "off-main work must not be recorded — blocking off-main is not a hang")
    }

    @Test
    @MainActor
    func withMainThreadOperationEndsEntryWhenBodyThrows() {
        struct Boom: Error {}
        let ledger = MainThreadOperationLedger()
        do {
            try ledger.withMainThreadOperation(subsystem: "test", operation: "throwing") {
                throw Boom()
            }
        } catch {}
        #expect(ledger.snapshot().isEmpty)
    }

    @Test
    func entryAgeGrowsMonotonically() {
        let ledger = MainThreadOperationLedger()
        let token = ledger.begin(subsystem: "test", operation: "aging")
        defer { ledger.end(token) }
        let entry = ledger.snapshot()[0]
        let early = entry.ageSeconds()
        Thread.sleep(forTimeInterval: 0.05)
        let later = entry.ageSeconds()
        #expect(later >= early)
        #expect(later >= 0.04)
    }

    @Test
    func concurrentBeginEndKeepsLedgerConsistent() async {
        let ledger = MainThreadOperationLedger()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let token = ledger.begin(subsystem: "stress", operation: "op-\(i)")
                    ledger.end(token)
                }
            }
        }
        #expect(ledger.snapshot().isEmpty)
    }
}
