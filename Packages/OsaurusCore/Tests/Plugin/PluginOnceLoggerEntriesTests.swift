//
//  PluginOnceLoggerEntriesTests.swift
//  OsaurusCoreTests
//
//  Pins entry retention + dedup for the Diagnostics UI.
//

import Foundation
import Testing

@testable import OsaurusCore

/// Each test uses a UUID-suffixed pluginId and resets only its own
/// prefix so parallel suites can't race on the process-global state.
struct PluginOnceLoggerEntriesTests {

    @Test func warnOnceRetainsEntry() {
        let pid = "com.test.warn-once.\(UUID())"
        PluginOnceLogger._resetForTesting(forKeyPrefix: pid)
        let key = "\(pid)|complete_stream|null_chunk"
        PluginOnceLogger.warnOnce(key: key, "plugin %@ misused", pid)

        let entries = PluginOnceLogger.entries(forPlugin: pid)
        #expect(entries.count == 1)
        #expect(entries.first?.message.contains(pid) == true)
        #expect(entries.first?.key == key)
        #expect(entries.first?.pluginId == pid)
    }

    @Test func dedupStillSuppressesDuplicateKey() {
        let pid = "com.test.dedup.\(UUID())"
        PluginOnceLogger._resetForTesting(forKeyPrefix: pid)
        let key = "\(pid)|noop"
        PluginOnceLogger.warnOnce(key: key, "first")
        PluginOnceLogger.warnOnce(key: key, "second")
        PluginOnceLogger.warnOnce(key: key, "third")

        #expect(PluginOnceLogger.entries(forPlugin: pid).count == 1)
        #expect(PluginOnceLogger.entries(forPlugin: pid).first?.message == "first")
    }

    @Test func differentKeysAccumulate() {
        let pid = "com.test.multi.\(UUID())"
        PluginOnceLogger._resetForTesting(forKeyPrefix: pid)
        PluginOnceLogger.warnOnce(key: "\(pid)|op_a|reason", "msg A")
        PluginOnceLogger.warnOnce(key: "\(pid)|op_b|reason", "msg B")
        PluginOnceLogger.warnOnce(key: "\(pid)|op_c|reason", "msg C")

        #expect(PluginOnceLogger.entries(forPlugin: pid).count == 3)
        #expect(PluginOnceLogger.count(forPlugin: pid) == 3)
    }

    @Test func entriesScopedToPlugin() {
        let pidA = "com.test.scoped.A.\(UUID())"
        let pidB = "com.test.scoped.B.\(UUID())"
        PluginOnceLogger._resetForTesting(forKeyPrefix: pidA)
        PluginOnceLogger._resetForTesting(forKeyPrefix: pidB)
        PluginOnceLogger.warnOnce(key: "\(pidA)|op|x", "A1")
        PluginOnceLogger.warnOnce(key: "\(pidA)|op|y", "A2")
        PluginOnceLogger.warnOnce(key: "\(pidB)|op|x", "B1")

        #expect(PluginOnceLogger.entries(forPlugin: pidA).count == 2)
        #expect(PluginOnceLogger.entries(forPlugin: pidB).count == 1)
        #expect(PluginOnceLogger.entries(forPlugin: "com.test.unknown").isEmpty)
    }

    @Test func keyWithoutPipeIsFiledAsUnknown() {
        // Pipeless keys file under "<unknown>". UUID-unique so no reset needed.
        let key = "no_pipe_in_key_\(UUID())"
        PluginOnceLogger.warnOnce(key: key, "loose warning")
        #expect(PluginOnceLogger.entries(forPlugin: "<unknown>").contains { $0.key == key })
    }

    @Test func formattedMessageReflectsArguments() {
        let pid = "com.test.fmt.\(UUID())"
        PluginOnceLogger._resetForTesting(forKeyPrefix: pid)
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
