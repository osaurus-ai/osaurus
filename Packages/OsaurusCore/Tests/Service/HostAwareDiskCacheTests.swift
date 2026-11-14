import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct HostAwareDiskCacheTests {
    @Test func sizeOnlySaveRetainsLoadedModels() {
        let previous = VMLXServerRuntimeSettings()
        var next = previous
        next.cache.blockDisk.maxSizePercent = 0.005
        next.cache.blockDisk.maxSizeGB = nil
        #expect(!ServerController.loadedModelRuntimeInputsRequireRefresh(previous: previous, next: next))
        next.cache.prefix.enabled.toggle()
        #expect(ServerController.loadedModelRuntimeInputsRequireRefresh(previous: previous, next: next))
    }

    @Test func hostAndEngineResolveTheSameCap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = VMLXServerRuntimeSettings()
        for percent in [Double?.none, 0.005, 10] {
            settings.cache.blockDisk.maxSizePercent = percent
            let host = ModelRuntime.diskCacheCap(for: settings.cache, directory: root)
            let engine = settings.cacheCoordinatorConfig(diskCacheDirectory: root)
            #expect(abs(host.capGB - Double(engine.diskCacheMaxGB)) < 0.1)
            #expect(engine.enableDiskCache)
        }
    }

    @Test func disabledReuseStillDisplaysTheConfiguredRoot() {
        var cache = VMLXServerCacheSettings()
        cache.prefix.enabled = false
        cache.blockDisk.directory = "/tmp/custom-ssd-root"
        #expect(ModelRuntime.cacheDiskDirectoryOverride(for: cache) == nil)
        #expect(ModelRuntime.diskCacheDirectoryForDisplay(for: cache).path == "/tmp/custom-ssd-root")
    }

    @Test func disabledReuseKeepsTheLegacyConfiguredRootVisible() {
        var cache = VMLXServerCacheSettings()
        cache.prefix.enabled = false
        cache.pagedKV.enabled = false
        cache.blockDisk.enabled = false
        cache.legacyDisk.enabled = true
        cache.blockDisk.directory = "/tmp/inactive-block-root"
        cache.legacyDisk.directory = "/tmp/legacy-ssd-root"
        #expect(ModelRuntime.cacheDiskDirectoryOverride(for: cache) == nil)
        #expect(ModelRuntime.diskCacheDirectoryForDisplay(for: cache).path == "/tmp/legacy-ssd-root")
    }

    @Test func clearRequiresSaveOnlyWhenTheResolvedDirectoryChanges() {
        var saved = VMLXServerCacheSettings()
        saved.blockDisk.directory = "/tmp/cache-root"
        var draft = saved
        draft.prefix.enabled.toggle()
        draft.blockDisk.maxSizeGB = 1
        #expect(!CacheSection.hasUnsavedDiskCacheDirectory(draft: draft, saved: saved))
        draft.blockDisk.directory = " /tmp/cache-root/ "
        #expect(!CacheSection.hasUnsavedDiskCacheDirectory(draft: draft, saved: saved))
        draft.blockDisk.directory = "/tmp/other-cache-root"
        #expect(CacheSection.hasUnsavedDiskCacheDirectory(draft: draft, saved: saved))
        draft = saved
        draft.pagedKV.enabled = false
        draft.blockDisk.enabled = false
        draft.legacyDisk.enabled = true
        draft.legacyDisk.directory = "/tmp/legacy-cache-root"
        #expect(CacheSection.hasUnsavedDiskCacheDirectory(draft: draft, saved: saved))
    }

    @Test func legacyFallbackKeepsTheSavedSize() {
        var cache = VMLXServerCacheSettings()
        cache.pagedKV.enabled = false
        cache.blockDisk.enabled = false
        cache.legacyDisk.enabled = true
        cache.legacyDisk.maxSizeGB = 0.125
        let cap = ModelRuntime.diskCacheCap(for: cache, directory: FileManager.default.temporaryDirectory)
        #expect(cap.rule == .legacyGB)
        #expect(cap.capGB == 0.125)
    }
}
