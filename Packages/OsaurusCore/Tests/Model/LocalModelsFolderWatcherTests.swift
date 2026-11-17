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

    /// End to end against the real models directory (`OSU_MODELS_DIR`):
    /// removing a bundle folder on disk posts `.localModelsChanged`.
    @MainActor
    @Test func removingABundleOnDiskPostsLocalModelsChanged() async throws {
        let fm = FileManager.default
        let root = DirectoryPickerService.effectiveModelsDirectory()
        let bundle = root.appendingPathComponent("watcher-probe-\(UUID().uuidString.prefix(8))/Model-4bit")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("config.json"))
        defer { try? fm.removeItem(at: bundle.deletingLastPathComponent()) }

        let watcher = LocalModelsFolderWatcher.shared
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .seconds(1))

        let posted = PostedFlag()
        let token = NotificationCenter.default.addObserver(
            forName: .localModelsChanged, object: nil, queue: .main
        ) { _ in posted.value = true }
        defer { NotificationCenter.default.removeObserver(token) }
        try fm.removeItem(at: bundle)

        for _ in 0 ..< 60 where !posted.value {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(posted.value, "watching \(LocalModelsFolderWatcher.currentRoots())")
    }

    @Test func droppedEventsAndRootChangesForceARescan() {
        #expect(LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels", flags: flags(kFSEventStreamEventFlagRootChanged), roots: roots))
        #expect(LocalModelsFolderWatcher.isInventoryChange(
            path: "/Users/me/MLXModels/x", flags: flags(kFSEventStreamEventFlagMustScanSubDirs), roots: roots))
    }
}
