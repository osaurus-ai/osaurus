//
//  PluginDatabaseSizeCapTests.swift
//  OsaurusCoreTests
//
//  Pins the per-plugin SQLite size cap. Without it, a runaway plugin
//  can fill `~/.osaurus/Tools/<id>/data/data.db` arbitrarily — there's
//  no host limit otherwise. The cap is enforced via SQLite's
//  `PRAGMA max_page_count`, so an INSERT past the cap fails with
//  `database or disk is full` and the plugin sees a normal SQL error
//  in the JSON envelope (no host crash).
//

import Foundation
import Testing

@testable import OsaurusCore

struct PluginDatabaseSizeCapTests {

    @Test func defaultCapIs100MiB() {
        // The published default is the contract authors will see in
        // HOST_API.md / osaurus_plugin.h. Pin it here so a casual
        // tweak doesn't silently change the documented number.
        #expect(PluginDatabase.defaultMaxBytes == 100 * 1024 * 1024)
    }

    @Test func capIsEnforcedAtSmallLimit() throws {
        // Open with a tiny cap and verify SQLite refuses growth.
        // Use 64 KiB which forces SQLITE_FULL after a single small
        // table + a few inserts on a default 4096-byte page DB
        // (the schema itself plus a handful of rows blows past
        // ~16 pages quickly).
        let db = PluginDatabase(pluginId: "com.test.dbcap.\(UUID())", maxBytes: 64 * 1024)
        try db.openInMemory()
        defer { db.close() }

        let create = db.exec(
            sql: "CREATE TABLE blob_table (id INTEGER PRIMARY KEY, payload TEXT)",
            paramsJSON: nil
        )
        #expect(!create.contains("\"error\""), "schema creation must succeed under cap")

        // Insert ~4 KiB rows until something rejects. The exact number
        // of rows is page-size dependent, but with a 64 KiB cap we'll
        // hit `SQLITE_FULL` well within 200 attempts.
        let payload = String(repeating: "x", count: 4_000)
        var sawFull = false
        for i in 0 ..< 200 {
            let result = db.exec(
                sql: "INSERT INTO blob_table (id, payload) VALUES (?1, ?2)",
                paramsJSON: "[\(i), \"\(payload)\"]"
            )
            if result.contains("\"error\"") {
                sawFull = true
                // SQLite reports "database or disk is full" for the
                // SQLITE_FULL return code from `sqlite3_step`. Pin the
                // wording so a future SQLCipher upgrade that changes
                // the message doesn't go unnoticed.
                #expect(
                    result.localizedCaseInsensitiveContains("full")
                        || result.localizedCaseInsensitiveContains("disk"),
                    "expected SQLITE_FULL-shaped error, got: \(result)"
                )
                break
            }
        }
        #expect(sawFull, "INSERTs past the 64 KiB cap must trigger SQLITE_FULL")
    }

    @Test func writesUnderCapStillSucceed() throws {
        // Smoke that the cap doesn't block ordinary use. 1 MiB is
        // generous for a tiny in-test workload.
        let db = PluginDatabase(pluginId: "com.test.dbcap.under.\(UUID())", maxBytes: 1024 * 1024)
        try db.openInMemory()
        defer { db.close() }

        _ = db.exec(sql: "CREATE TABLE kv (k TEXT, v TEXT)", paramsJSON: nil)
        for i in 0 ..< 10 {
            let result = db.exec(
                sql: "INSERT INTO kv VALUES (?1, ?2)",
                paramsJSON: "[\"k\(i)\", \"v\(i)\"]"
            )
            #expect(result.contains("\"changes\":1"))
        }
    }

    @Test func capOfZeroDisablesEnforcement() throws {
        // An explicit `maxBytes = 0` is the escape hatch for tests /
        // diagnostic flows that don't want a cap at all. Confirm it
        // doesn't fault out at PRAGMA time.
        let db = PluginDatabase(pluginId: "com.test.dbcap.zero.\(UUID())", maxBytes: 0)
        try db.openInMemory()
        defer { db.close() }
        let result = db.exec(sql: "CREATE TABLE t (x INTEGER)", paramsJSON: nil)
        #expect(!result.contains("\"error\""))
    }
}
