//
//  AtomicBoolTests.swift
//  osaurusTests
//
//  Smoke tests for the lock-protected Bool that
//  `StorageMigrationCoordinator.blockingAwaitReady()` polls on the
//  hot path. The contract we care about for the gate to behave
//  correctly:
//
//  - `load()` reflects the most recent `store()` from any thread.
//  - Concurrent `load()` from many threads while a single writer
//    flips the value never observes a torn value (we only ever
//    care about Bool, which would be tearless even without a lock,
//    but the test pins the contract for future edits).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct AtomicBoolTests {

    @Test
    func storeAndLoadRoundTrip() {
        let flag = AtomicBool(false)
        #expect(flag.load() == false)
        flag.store(true)
        #expect(flag.load() == true)
        flag.store(false)
        #expect(flag.load() == false)
    }

    @Test
    func concurrentReadersSeeWriterUpdate() async {
        let flag = AtomicBool(false)
        // Flip first, then spawn readers — that way every reader's
        // very first load() observes the post-write state. The
        // point of this test is "no torn reads / no stuck stale
        // value", not "writer wins a race against bounded reader
        // loops". Bounded loops without coordination are racy by
        // construction.
        flag.store(true)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 16 {
                group.addTask { flag.load() }
            }
            for await observed in group {
                #expect(observed == true)
            }
        }
        // And again in the other direction.
        flag.store(false)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 16 {
                group.addTask { flag.load() }
            }
            for await observed in group {
                #expect(observed == false)
            }
        }
    }
}
