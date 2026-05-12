//
//  PluginOnceLoggerEntriesTests.swift
//  OsaurusCoreTests
//
//  Pins the entry-retention behavior added so plugin authors can see
//  ABI-misuse warnings the host has already flagged via the plugin
//  detail UI's Diagnostics section, instead of having to grep
//  `Console.app`. The dedup contract (one warning per `key` per
//  process) is preserved — the new behavior just retains the
//  formatted message alongside the dedup set.
//

import Foundation
import Testing

@testable import OsaurusCore

/// `PluginOnceLogger` keeps process-global dedup + entry state, so
/// these tests must run serially — otherwise one test's
/// `_resetForTesting()` wipes another's freshly-added entry mid-run.
@Suite(.serialized)
struct PluginOnceLoggerEntriesTests {

    @Test func warnOnceRetainsEntry() {
        PluginOnceLogger._resetForTesting()
        let pid = "com.test.warn-once.\(UUID())"
        let key = "\(pid)|complete_stream|null_chunk"
        PluginOnceLogger.warnOnce(key: key, "plugin %@ misused", pid)

        let entries = PluginOnceLogger.entries(forPlugin: pid)
        #expect(entries.count == 1)
        #expect(entries.first?.message.contains(pid) == true)
        #expect(entries.first?.key == key)
        #expect(entries.first?.pluginId == pid)
    }

    @Test func dedupStillSuppressesDuplicateKey() {
        // The whole point of `warnOnce` is dedup. Pin that the new
        // retention doesn't accidentally start storing every call.
        PluginOnceLogger._resetForTesting()
        let pid = "com.test.dedup.\(UUID())"
        let key = "\(pid)|noop"
        PluginOnceLogger.warnOnce(key: key, "first")
        PluginOnceLogger.warnOnce(key: key, "second")
        PluginOnceLogger.warnOnce(key: key, "third")

        #expect(PluginOnceLogger.entries(forPlugin: pid).count == 1)
        #expect(PluginOnceLogger.entries(forPlugin: pid).first?.message == "first")
    }

    @Test func differentKeysAccumulate() {
        PluginOnceLogger._resetForTesting()
        let pid = "com.test.multi.\(UUID())"
        PluginOnceLogger.warnOnce(key: "\(pid)|op_a|reason", "msg A")
        PluginOnceLogger.warnOnce(key: "\(pid)|op_b|reason", "msg B")
        PluginOnceLogger.warnOnce(key: "\(pid)|op_c|reason", "msg C")

        #expect(PluginOnceLogger.entries(forPlugin: pid).count == 3)
        #expect(PluginOnceLogger.count(forPlugin: pid) == 3)
    }

    @Test func entriesScopedToPlugin() {
        // `entries(forPlugin:)` must filter by the dedup-key prefix
        // so the UI badge for plugin A doesn't include plugin B's
        // warnings.
        PluginOnceLogger._resetForTesting()
        let pidA = "com.test.scoped.A.\(UUID())"
        let pidB = "com.test.scoped.B.\(UUID())"
        PluginOnceLogger.warnOnce(key: "\(pidA)|op|x", "A1")
        PluginOnceLogger.warnOnce(key: "\(pidA)|op|y", "A2")
        PluginOnceLogger.warnOnce(key: "\(pidB)|op|x", "B1")

        #expect(PluginOnceLogger.entries(forPlugin: pidA).count == 2)
        #expect(PluginOnceLogger.entries(forPlugin: pidB).count == 1)
        #expect(PluginOnceLogger.entries(forPlugin: "com.test.unknown").isEmpty)
    }

    @Test func keyWithoutPipeIsFiledAsUnknown() {
        // Defensive: a caller that forgets the `<pluginId>|...` prefix
        // shouldn't crash. The entry is filed under "<unknown>" so the
        // operator sees that something escaped the convention.
        PluginOnceLogger._resetForTesting()
        let key = "no_pipe_in_key_\(UUID())"
        PluginOnceLogger.warnOnce(key: key, "loose warning")
        #expect(PluginOnceLogger.entries(forPlugin: "<unknown>").contains { $0.key == key })
    }

    @Test func formattedMessageReflectsArguments() {
        // Pin that printf-style arguments still format correctly after
        // we moved formatting from `withVaList(...) { NSLogv(...) }`
        // to a single-pass formatter.
        PluginOnceLogger._resetForTesting()
        let pid = "com.test.fmt.\(UUID())"
        PluginOnceLogger.warnOnce(
            key: "\(pid)|fmt|once",
            "plugin %@ called %@ %d times",
            pid,
            "do_thing",
            42
        )
        let entry = PluginOnceLogger.entries(forPlugin: pid).first
        #expect(entry?.message.contains("do_thing") == true)
        #expect(entry?.message.contains("42") == true)
    }
}
