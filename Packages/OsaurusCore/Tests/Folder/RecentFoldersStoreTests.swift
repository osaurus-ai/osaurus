//
//  RecentFoldersStoreTests.swift
//  osaurus
//
//  Ordering, dedupe, cap, removal, and persistence of the recent working
//  folders list behind the composer's hover panel.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct RecentFoldersStoreTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "RecentFoldersStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func recordPutsMostRecentFirstAndDedupes() {
        let store = RecentFoldersStore(defaults: makeDefaults())
        store.record(path: "/tmp/a", bookmark: nil)
        store.record(path: "/tmp/b", bookmark: nil)
        store.record(path: "/tmp/a", bookmark: Data([1]))

        #expect(store.entries.map(\.path) == ["/tmp/a", "/tmp/b"])
        #expect(store.entries.first?.bookmark == Data([1]))
    }

    @Test func recordCapsAtLimit() {
        let store = RecentFoldersStore(defaults: makeDefaults())
        for i in 0..<(RecentFoldersStore.limit + 3) {
            store.record(path: "/tmp/\(i)", bookmark: nil)
        }
        #expect(store.entries.count == RecentFoldersStore.limit)
        #expect(store.entries.first?.path == "/tmp/\(RecentFoldersStore.limit + 2)")
        #expect(store.entries.last?.path == "/tmp/3")
    }

    @Test func recordNormalizesTrailingSlashAndIgnoresEmpty() {
        let store = RecentFoldersStore(defaults: makeDefaults())
        store.record(path: "/tmp/a/", bookmark: nil)
        store.record(path: "/tmp/a", bookmark: nil)
        store.record(path: "", bookmark: nil)
        #expect(store.entries.map(\.path) == ["/tmp/a"])
    }

    @Test func removeDropsOnlyThatEntry() {
        let store = RecentFoldersStore(defaults: makeDefaults())
        store.record(path: "/tmp/a", bookmark: nil)
        store.record(path: "/tmp/b", bookmark: nil)
        store.remove(path: "/tmp/b")
        #expect(store.entries.map(\.path) == ["/tmp/a"])
    }

    @Test func entriesPersistAcrossInstances() {
        let defaults = makeDefaults()
        let first = RecentFoldersStore(defaults: defaults)
        first.record(path: "/tmp/a", bookmark: Data([7]))
        first.record(path: "/tmp/b", bookmark: nil)

        let second = RecentFoldersStore(defaults: defaults)
        #expect(second.entries == first.entries)
        #expect(second.entries.last?.bookmark == Data([7]))
    }

    @Test func resolveFallsBackToPathWhenBookmarkMissing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentFoldersStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let present = RecentFoldersStore.Entry(path: dir.path, bookmark: nil)
        let resolved = await RecentFoldersStore.resolveURL(for: present)
        #expect(resolved?.standardizedFileURL.path == dir.standardizedFileURL.path)

        let gone = RecentFoldersStore.Entry(path: dir.appendingPathComponent("missing").path, bookmark: nil)
        #expect(await RecentFoldersStore.resolveURL(for: gone) == nil)
    }
}
