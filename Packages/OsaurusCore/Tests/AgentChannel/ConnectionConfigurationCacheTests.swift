//
//  ConnectionConfigurationCacheTests.swift
//  osaurusTests
//
//  Regression coverage for Sentry APPLE-MACOS-3C5: connector configuration
//  stores must serve repeat `load()` calls from memory (the MainActor
//  prompt-preview path reads them on every recompute) while staying coherent
//  with `save()` and `overrideDirectory` switches.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ConnectionConfigurationCacheTests {

    @Test func cacheLoadsOncePerURL() {
        let cache = ConnectionConfigurationCache<Int>()
        let url = URL(fileURLWithPath: "/tmp/a.json")
        var loads = 0

        #expect(cache.value(for: url) { loads += 1; return 1 } == 1)
        #expect(cache.value(for: url) { loads += 1; return 2 } == 1)
        #expect(loads == 1)
    }

    @Test func cacheReloadsForDifferentURLAndAfterReset() {
        let cache = ConnectionConfigurationCache<Int>()
        let a = URL(fileURLWithPath: "/tmp/a.json")
        let b = URL(fileURLWithPath: "/tmp/b.json")

        #expect(cache.value(for: a) { 1 } == 1)
        #expect(cache.value(for: b) { 2 } == 2)
        cache.reset()
        #expect(cache.value(for: b) { 3 } == 3)
    }

    @Test func storeOverridesCachedValue() {
        let cache = ConnectionConfigurationCache<Int>()
        let url = URL(fileURLWithPath: "/tmp/a.json")

        #expect(cache.value(for: url) { 1 } == 1)
        cache.store(5, for: url)
        #expect(cache.value(for: url) { 9 } == 5)
    }

    @Test func iMessageStoreServesSavedValueAndHonorsOverrideSwitch() async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let previous = IMessageConnectionConfigurationStore.overrideDirectory
            let first = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-imessage-cache-\(UUID().uuidString)", isDirectory: true)
            let second = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-imessage-cache-\(UUID().uuidString)", isDirectory: true)
            defer {
                IMessageConnectionConfigurationStore.overrideDirectory = previous
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }

            IMessageConnectionConfigurationStore.overrideDirectory = first
            // Missing file -> defaults, including the process-wide attachment root.
            let defaults = IMessageConnectionConfigurationStore.load()
            #expect(!defaults.writeEnabled)
            #expect(
                defaults.allowedAttachmentRoots
                    == IMessageConnectionConfiguration.normalizedRoots(
                        IMessageConnectionConfiguration.defaultAttachmentRoots
                    )
            )

            try IMessageConnectionConfigurationStore.save(
                IMessageConnectionConfiguration(writeEnabled: true, defaultReadLimit: 42)
            )
            let saved = IMessageConnectionConfigurationStore.load()
            #expect(saved.writeEnabled)
            #expect(saved.defaultReadLimit == 42)

            // Disk agrees with the cached value after a forced reload.
            IMessageConnectionConfigurationStore.resetCache()
            let reloaded = IMessageConnectionConfigurationStore.load()
            #expect(reloaded.writeEnabled)
            #expect(reloaded.defaultReadLimit == 42)

            // A different directory must not see the first directory's value.
            IMessageConnectionConfigurationStore.overrideDirectory = second
            let fresh = IMessageConnectionConfigurationStore.load()
            #expect(!fresh.writeEnabled)
            #expect(fresh.defaultReadLimit == 50)
        }
    }
}
