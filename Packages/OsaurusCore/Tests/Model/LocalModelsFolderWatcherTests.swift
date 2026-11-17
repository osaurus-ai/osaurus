//
//  LocalModelsFolderWatcherTests.swift
//  osaurusTests
//

import CoreServices
import Foundation
import Testing

@testable import OsaurusCore

private final class PostedFlag: @unchecked Sendable {
    var value = false
}

struct LocalModelsFolderWatcherTests {
    private let roots = ["/Users/me/MLXModels"]

    private func flags(_ raw: Int...) -> FSEventStreamEventFlags {
        FSEventStreamEventFlags(raw.reduce(0, |))
    }

    @Test func bundleDirectoryRemovedOrMovedCounts() {
        let removed = flags(kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemRemoved)
        let renamed = flags(kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemRenamed)
        #expect(LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels/OsaurusAI/Model-4bit", flags: removed, roots: roots))
        #expect(LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels/OsaurusAI", flags: renamed, roots: roots))
        #expect(LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels/flat-model/", flags: renamed, roots: roots))
    }

    @Test func fileWritesInsideABundleAreIgnored() {
        let created = flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemCreated)
        let modified = flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified)
        #expect(!LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels/OsaurusAI/Model-4bit/model.safetensors", flags: created, roots: roots))
        #expect(!LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels/OsaurusAI/Model-4bit/model.safetensors", flags: modified, roots: roots))
    }

    @Test func hiddenDeepAndForeignDirectoriesAreIgnored() {
        let created = flags(kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)
        #expect(!LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels/.staging/OsaurusAI", flags: created, roots: roots))
        #expect(!LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels/a/b/c/d", flags: created, roots: roots))
        #expect(!LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModelsOther/OsaurusAI", flags: created, roots: roots))
        #expect(!LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels", flags: created, roots: roots))
    }

    /// FSEvents reports `/private/var/...` for a root under the `/var`
    /// symlink; the watched root has to be spelled the same way or no
    /// event matches it.
    @Test func rootsAreSpelledTheWayFSEventsReportsThem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let link = root.appendingPathComponent("linked-models")
        let target = root.appendingPathComponent("models")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let canonical = try #require(LocalModelsFolderWatcher.canonicalDirectoryPath(link))
        #expect(canonical.hasPrefix("/private/"))
        #expect(canonical.hasSuffix("/models"))
        let created = flags(kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)
        #expect(LocalModelsFolderWatcher.isInventoryChange(
            path: canonical + "/OsaurusAI/Model-4bit", flags: created, roots: [canonical]))
        #expect(LocalModelsFolderWatcher.canonicalDirectoryPath(root.appendingPathComponent("missing")) == nil)
    }

    /// End to end through FSEvents on a private folder, so the shared models
    /// directory and the app-wide `.localModelsChanged` stay untouched for
    /// suites running alongside.
    @MainActor
    @Test func removingABundleOnDiskReportsAChange() async throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = temp.appendingPathComponent("OsaurusAI/Model-4bit")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("config.json"))
        defer { try? fm.removeItem(at: temp) }
        let root = try #require(LocalModelsFolderWatcher.canonicalDirectoryPath(temp))

        let changed = PostedFlag()
        let watcher = LocalModelsFolderWatcher(roots: { [root] }) { changed.value = true }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .seconds(1))

        try fm.removeItem(at: bundle)
        for _ in 0 ..< 60 where !changed.value {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(changed.value, "watching \(root)")
    }

    @Test func droppedEventsAndRootChangesForceARescan() {
        #expect(LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels", flags: flags(kFSEventStreamEventFlagRootChanged), roots: roots))
        #expect(LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels/x", flags: flags(kFSEventStreamEventFlagMustScanSubDirs), roots: roots))
    }
}
