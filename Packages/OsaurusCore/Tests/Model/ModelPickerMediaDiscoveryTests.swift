import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ModelPickerMediaDiscoveryTests {
    @MainActor
    private final class MediaScan {
        var calls = 0
        var result: [ModelPickerItem] = []
        var blocked = true
        var waiters: [CheckedContinuation<Void, Never>] = []

        func load() async -> [ModelPickerItem] {
            calls += 1
            let snapshot = result
            if blocked {
                await withCheckedContinuation { waiters.append($0) }
            }
            return snapshot
        }

        func release() {
            blocked = false
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func item(_ id: String, source: ModelPickerItem.Source) -> ModelPickerItem {
        ModelPickerItem(id: id, displayName: id, source: source)
    }

    private func readyImage(_ id: String = "fixture/image") -> ModelPickerItem {
        ModelPickerItem(
            id: id,
            displayName: id,
            source: .imageGeneration,
            imageCapabilities: ImageModelCapabilities(textToImage: true),
            imageReady: true
        )
    }

    @Test func blockedMediaDoesNotWithholdChatOrCurrentItems() async {
        let scan = MediaScan()
        defer { scan.release() }
        let local = item("fixture/chat", source: .local)
        let cache = ModelPickerItemCache._makeForTesting(
            loadChatAndCloudItems: { [local] },
            loadLocalMediaItems: { await scan.load() }
        )
        var built: [ModelPickerItem]?
        let build = Task { built = await cache.buildModelPickerItems() }
        await waitUntil { built != nil && scan.calls > 0 }
        #expect(built?.map(\.id) == [local.id])
        #expect(cache.isLoaded)
        #expect(cache.items.map(\.id) == [local.id])
        #expect(scan.blocked && scan.calls == 1)

        var current: [ModelPickerItem]?
        let read = Task { current = await cache.currentItems() }
        await waitUntil { current != nil }
        #expect(current?.map(\.id) == [local.id])
        // Always release before joining, including on failure, so a regression
        // fails assertions instead of leaving an unstructured task wedged.
        scan.release()
        await build.value
        await read.value
        await cache.refreshLocalMediaModelItems()
    }

    @Test func lateMediaPublishesInOrderAndRemovalPreservesChat() async {
        let scan = MediaScan()
        defer { scan.release() }
        let local = item("fixture/chat", source: .local)
        let remote = item("fixture/remote", source: .remote(providerName: "Fixture", providerId: UUID()))
        let image = readyImage()
        scan.result = [image]
        let cache = ModelPickerItemCache._makeForTesting(
            loadChatAndCloudItems: { [local, remote] },
            loadLocalMediaItems: { await scan.load() }
        )
        _ = await cache.buildModelPickerItems()
        #expect(cache.items.map(\.id) == [local.id, remote.id])
        #expect(!cache.hasReadyImageGenerationModel)
        scan.release()
        await cache.refreshLocalMediaModelItems()
        #expect(cache.items.map(\.id) == [local.id, image.id, remote.id])
        #expect(cache.hasReadyImageGenerationModel)

        scan.result = []
        scan.blocked = true
        let priorCalls = scan.calls
        let refresh = Task { await cache.refreshLocalMediaModelItems() }
        await waitUntil { scan.calls > priorCalls }
        #expect(cache.items.map(\.id) == [local.id, image.id, remote.id])
        scan.release()
        await refresh.value
        #expect(cache.items.map(\.id) == [local.id, remote.id])
        #expect(!cache.hasReadyImageGenerationModel)
        #expect(cache.isLoaded)
    }

    @Test func blockedMediaCoalescesRefreshAndKeepsLatestChatCatalog() async {
        let scan = MediaScan()
        defer { scan.release() }
        var local = item("fixture/first", source: .local)
        let image = readyImage()
        scan.result = [image]
        let cache = ModelPickerItemCache._makeForTesting(
            loadChatAndCloudItems: { [local] },
            loadLocalMediaItems: { await scan.load() }
        )
        _ = await cache.buildModelPickerItems()
        await waitUntil { scan.calls == 1 }
        local = item("fixture/latest", source: .local)
        for _ in 0 ..< 32 { _ = await cache.buildModelPickerItems() }
        #expect(scan.calls == 1, "blocked media must not spawn a scan per chat refresh")
        #expect(cache.items.map(\.id) == [local.id])
        scan.release()
        await cache.refreshLocalMediaModelItems()
        #expect(scan.calls == 2, "the notification burst needs at most one follow-up scan")
        #expect(cache.items.map(\.id) == [local.id, image.id])
    }

    @Test func invalidationDuringScanDiscardsSupersededMedia() async {
        let scan = MediaScan()
        defer { scan.release() }
        let local = item("fixture/chat", source: .local)
        let oldImage = readyImage("fixture/removed-image")
        let newImage = readyImage("fixture/current-image")
        scan.result = [oldImage]
        let cache = ModelPickerItemCache._makeForTesting(
            loadChatAndCloudItems: { [local] },
            loadLocalMediaItems: { await scan.load() }
        )
        _ = await cache.buildModelPickerItems()
        await waitUntil { scan.calls == 1 }
        cache.invalidateCache()
        #expect(cache.items.isEmpty && !cache.isLoaded)
        scan.result = [newImage]
        _ = await cache.buildModelPickerItems()
        scan.release()
        await cache.refreshLocalMediaModelItems()
        #expect(scan.calls == 2)
        #expect(cache.items.map(\.id) == [local.id, newImage.id])
        #expect(!cache.items.contains { $0.id == oldImage.id })
    }
}
