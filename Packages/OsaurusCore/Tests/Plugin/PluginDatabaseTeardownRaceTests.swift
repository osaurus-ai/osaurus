//
//  PluginDatabaseTeardownRaceTests.swift
//  OsaurusCoreTests
//
//  Pins the host-side SQL lifecycle contract behind production crash
//  APPLE-MACOS-18J (EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE inside a
//  plugin `seen_updates`-style SELECT):
//
//  - Plugin SQL arriving AFTER `PluginHostContext.teardown()` must get the
//    "shutting down" error envelope instead of lazily re-opening the
//    database — a resurrected connection is an orphaned fd that storage
//    convergence/rekey later swaps the file under.
//  - `teardown()` must drain in-flight SQL (enter-before-check on the
//    in-flight group) before closing the database, so a plugin-spawned
//    poller thread can never be mid-`sqlite3_step` during the close.
//  - `StorageMutationGate.beginMutating()` must move the mutation epoch
//    that `PluginDatabase.open()` uses to detect a quiesce/swap racing its
//    own open.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct PluginDatabaseTeardownRaceTests {

    /// Runs `body` with `OsaurusPaths` re-pointed at a private temp root so
    /// the context's real on-disk plugin DB lands inside the sandbox.
    private func withSandboxedStorageRoot(
        _ body: @Sendable (String) async throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-plugin-db-teardown-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }
            try await body("com.test.dbteardown.\(UUID().uuidString)")
        }
    }

    @Test func sqlAfterTeardownReturnsShuttingDownEnvelope() async throws {
        try await withSandboxedStorageRoot { pluginId in
            let ctx = try PluginHostContext(pluginId: pluginId)

            // Prove the DB works before teardown (this also lazily opens it).
            let create = ctx.dbExec(
                sql: "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, v TEXT)",
                paramsJSON: nil
            )
            #expect(!create.contains("\"error\""), "pre-teardown SQL must succeed: \(create)")

            ctx.teardown()

            // Post-teardown SQL must be refused by the latch — NOT silently
            // re-open the database. The envelope is produced before
            // `ensureDatabaseOpen()` runs, which is the resurrection guard.
            let exec = ctx.dbExec(sql: "INSERT INTO t (v) VALUES ('x')", paramsJSON: nil)
            #expect(exec.contains("shutting down"), "post-teardown exec must be refused: \(exec)")
            let query = ctx.dbQuery(sql: "SELECT v FROM t", paramsJSON: nil)
            #expect(query.contains("shutting down"), "post-teardown query must be refused: \(query)")
        }
    }

    @Test func teardownDrainsInFlightSQL() async throws {
        try await withSandboxedStorageRoot { pluginId in
            let ctx = try PluginHostContext(pluginId: pluginId)
            _ = ctx.dbExec(
                sql: "CREATE TABLE IF NOT EXISTS poll (id INTEGER PRIMARY KEY, v TEXT)",
                paramsJSON: nil
            )

            // Simulate the production shape: plugin-owned poller threads
            // hammering `db_exec`/`db_query` on queues the host never
            // drains, while teardown lands mid-flight. Every result must be
            // a well-formed envelope (success or the shutting-down refusal)
            // and the process must not crash on a closed/freed handle.
            let workers = 8
            let iterations = 25
            let results = LockedResults()

            await withTaskGroup(of: Void.self) { group in
                for worker in 0 ..< workers {
                    group.addTask {
                        for i in 0 ..< iterations {
                            let exec = ctx.dbExec(
                                sql: "INSERT INTO poll (v) VALUES (?1)",
                                paramsJSON: "[\"w\(worker)-\(i)\"]"
                            )
                            results.append(exec)
                            let query = ctx.dbQuery(
                                sql: "SELECT id, v FROM poll ORDER BY id DESC LIMIT 3",
                                paramsJSON: nil
                            )
                            results.append(query)
                        }
                    }
                }
                group.addTask {
                    // Land the teardown while workers are mid-flight.
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    ctx.teardown()
                }
            }

            for envelope in results.snapshot() {
                let isSuccess =
                    envelope.contains("\"changes\"") || envelope.contains("\"columns\"")
                let isRefusal = envelope.contains("shutting down")
                #expect(
                    isSuccess || isRefusal,
                    "every envelope must be a success or the teardown refusal, got: \(envelope)"
                )
            }

            // And the latch stays latched: nothing after the drain can
            // resurrect the connection.
            let after = ctx.dbQuery(sql: "SELECT COUNT(*) FROM poll", paramsJSON: nil)
            #expect(after.contains("shutting down"))
        }
    }

    @Test @MainActor func beginMutatingMovesTheMutationEpoch() {
        let gate = StorageMutationGate.makeForTesting()
        let before = StorageMutationGate.mutationEpoch
        gate.beginMutating()
        defer { gate.endMutating() }
        #expect(
            StorageMutationGate.mutationEpoch > before,
            "PluginDatabase.open()'s TOCTOU re-check keys off this epoch"
        )
    }
}

/// Tiny thread-safe result collector for the stress test.
private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }

    func snapshot() -> [String] {
        lock.withLock { values }
    }
}
