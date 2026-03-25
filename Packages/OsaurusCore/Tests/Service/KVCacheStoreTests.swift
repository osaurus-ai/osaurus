//
//  KVCacheStoreTests.swift
//  osaurusTests
//

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct KVCacheStoreTests {

    /// Creates a lightweight `[any KVCache]` without triggering Metal GPU ops.
    /// State bytes are 0, but entry management and LRU logic are fully exercised.
    private func makeCache() -> [any KVCache] {
        [KVCacheSimple()]
    }

    // MARK: - Hot tier put / get

    @Test func putAndGetHotCache() {
        var store = KVCacheStore()
        let cache = makeCache()

        store.putCache(sessionId: "s1", cache: cache, tokens: nil, modelName: "llama")

        let retrieved = store.getCache(sessionId: "s1", modelName: "llama")
        #expect(retrieved.0 != nil)
        #expect(retrieved.0!.count == 1)
    }

    @Test func getCacheReturnsNilOnMiss() {
        var store = KVCacheStore()
        let result = store.getCache(sessionId: "nonexistent", modelName: "llama")
        #expect(result.0 == nil)
    }

    @Test func getCacheInvalidatesOnModelChange() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "modelA")

        let result = store.getCache(sessionId: "s1", modelName: "modelB")
        #expect(result.0 == nil)

        let retry = store.getCache(sessionId: "s1", modelName: "modelA")
        #expect(retry.0 == nil)
    }

    // MARK: - LRU ordering

    @Test func lruOrderMaintainedAcrossAccesses() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m")
        store.putCache(sessionId: "s2", cache: makeCache(), tokens: nil, modelName: "m")
        store.putCache(sessionId: "s3", cache: makeCache(), tokens: nil, modelName: "m")

        // Access s1 -- should promote it to MRU; s2 becomes coldest
        _ = store.getCache(sessionId: "s1", modelName: "m")

        // All three should still be retrievable
        #expect(store.getCache(sessionId: "s1", modelName: "m").0 != nil)
        #expect(store.getCache(sessionId: "s2", modelName: "m").0 != nil)
        #expect(store.getCache(sessionId: "s3", modelName: "m").0 != nil)
    }

    @Test func putCacheTouchesLRU() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m")
        store.putCache(sessionId: "s2", cache: makeCache(), tokens: nil, modelName: "m")

        // Re-putting s1 should promote it to MRU
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m")

        // Both should still be retrievable after re-put
        #expect(store.getCache(sessionId: "s1", modelName: "m").0 != nil)
        #expect(store.getCache(sessionId: "s2", modelName: "m").0 != nil)
    }

    // MARK: - ensureBudget

    @Test func ensureBudgetIsNoOpWhenUnderBudget() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m")

        // With 0-byte caches, totalHotBytes is 0 which is within any budget
        store.ensureBudget(1024)
        #expect(store.getCache(sessionId: "s1", modelName: "m").0 != nil)
    }

    // MARK: - Invalidation

    @Test func invalidateRemovesSession() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m")
        #expect(store.getCache(sessionId: "s1", modelName: "m").0 != nil)

        store.invalidate(sessionId: "s1")
        #expect(store.getCache(sessionId: "s1", modelName: "m").0 == nil)
    }

    @Test func invalidateIsNoOpForUnknownSession() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m")
        store.invalidate(sessionId: "unknown")
        #expect(store.getCache(sessionId: "s1", modelName: "m").0 != nil)
    }

    @Test func invalidateModelRemovesAllForModel() {
        var store = KVCacheStore()
        store.putCache(sessionId: "a1", cache: makeCache(), tokens: nil, modelName: "modelA")
        store.putCache(sessionId: "a2", cache: makeCache(), tokens: nil, modelName: "modelA")
        store.putCache(sessionId: "b1", cache: makeCache(), tokens: nil, modelName: "modelB")

        store.invalidateModel("modelA")

        #expect(store.getCache(sessionId: "a1", modelName: "modelA").0 == nil)
        #expect(store.getCache(sessionId: "a2", modelName: "modelA").0 == nil)
        #expect(store.getCache(sessionId: "b1", modelName: "modelB").0 != nil)
    }

    @Test func invalidateModelIsNoOpForUnknownModel() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m")
        store.invalidateModel("unknown")
        #expect(store.getCache(sessionId: "s1", modelName: "m").0 != nil)
    }

    @Test func clearAllRemovesEverything() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m1")
        store.putCache(sessionId: "s2", cache: makeCache(), tokens: nil, modelName: "m2")

        store.clearAll()

        #expect(store.totalHotBytes == 0)
        #expect(store.getCache(sessionId: "s1", modelName: "m1").0 == nil)
        #expect(store.getCache(sessionId: "s2", modelName: "m2").0 == nil)
    }

    // MARK: - Prefix cache

    @Test func prefixKeyFormat() {
        let key = KVCacheStore.prefixKey(modelName: "llama", hash: "abc123")
        #expect(key == "prefix_llama_abc123")
    }

    @Test func prefixKeyDifferentModelsProduceDifferentKeys() {
        let k1 = KVCacheStore.prefixKey(modelName: "llama", hash: "h1")
        let k2 = KVCacheStore.prefixKey(modelName: "gemma", hash: "h1")
        #expect(k1 != k2)
    }

    @Test func prefixKeyDifferentHashesProduceDifferentKeys() {
        let k1 = KVCacheStore.prefixKey(modelName: "llama", hash: "h1")
        let k2 = KVCacheStore.prefixKey(modelName: "llama", hash: "h2")
        #expect(k1 != k2)
    }

    /// Seeds a prefix cache entry without triggering SSD serialization.
    /// Uses `putCache` with the composite prefix key directly.
    private func seedPrefixCache(
        _ store: inout KVCacheStore,
        modelName: String,
        hash: String
    ) {
        let key = KVCacheStore.prefixKey(modelName: modelName, hash: hash)
        store.putCache(sessionId: key, cache: makeCache(), tokens: nil, modelName: modelName)
    }

    @Test func putPrefixCacheRegistersEntry() {
        var store = KVCacheStore()
        seedPrefixCache(&store, modelName: "llama", hash: "hash1")

        #expect(store.hasPrefixCache(modelName: "llama", hash: "hash1"))
    }

    @Test func getPrefixCacheReturnsNilWithoutSSD() {
        var store = KVCacheStore()
        seedPrefixCache(&store, modelName: "llama", hash: "hash1")

        // getPrefixCache always loads from SSD to avoid shared-reference mutation;
        // seeded entries have no ssdPath so it returns nil.
        let retrieved = store.getPrefixCache(modelName: "llama", hash: "hash1")
        #expect(retrieved.0 == nil)
    }

    @Test func hasPrefixCacheReturnsFalseOnMiss() {
        let store = KVCacheStore()
        #expect(!store.hasPrefixCache(modelName: "llama", hash: "nonexistent"))
    }

    @Test func differentHashesDontCollide() {
        var store = KVCacheStore()
        seedPrefixCache(&store, modelName: "llama", hash: "hash_a")
        seedPrefixCache(&store, modelName: "llama", hash: "hash_b")

        #expect(store.hasPrefixCache(modelName: "llama", hash: "hash_a"))
        #expect(store.hasPrefixCache(modelName: "llama", hash: "hash_b"))
        #expect(!store.hasPrefixCache(modelName: "llama", hash: "hash_c"))
    }

    @Test func prefixCacheEvictedByModelInvalidation() {
        var store = KVCacheStore()
        seedPrefixCache(&store, modelName: "llama", hash: "h1")
        #expect(store.hasPrefixCache(modelName: "llama", hash: "h1"))

        store.invalidateModel("llama")
        #expect(!store.hasPrefixCache(modelName: "llama", hash: "h1"))
    }

    @Test func prefixCacheEvictedByClearAll() {
        var store = KVCacheStore()
        seedPrefixCache(&store, modelName: "llama", hash: "h1")
        store.clearAll()
        #expect(!store.hasPrefixCache(modelName: "llama", hash: "h1"))
    }

    // MARK: - Async behavior TDD

    @Test func saveToDiskIsNonBlocking() async throws {
        var store = KVCacheStore()
        let cache = makeCache()
        
        let start = Date()
        store.saveToDisk(sessionId: "testAsync", cache: cache, tokens: nil, modelName: "llama")
        let duration = Date().timeIntervalSince(start)
        
        // Assert it returns immediately (much faster than a safetensors disk write)
        #expect(duration < 0.05)
        
        // Confirm a background task was dispatched
        #expect(store.lastSaveTask != nil)
        
        // Await the background task so we don't leak it across tests
        if let task = store.lastSaveTask {
            await task.value
        }
    }

    // MARK: - Budget computation

    @Test func computeBudgetFloor() {
        let hugeWeights: Int64 = Int64(ProcessInfo.processInfo.physicalMemory) * 2
        let budget = KVCacheStore.computeBudget(modelWeightsBytes: hugeWeights)
        #expect(budget == 512 * 1024 * 1024)
    }

    @Test func computeBudgetPositiveForReasonableWeights() {
        let budget = KVCacheStore.computeBudget(modelWeightsBytes: 0)
        #expect(budget >= 512 * 1024 * 1024)
    }

    @Test func computeBudgetDecreasesWithLargerWeights() {
        let small = KVCacheStore.computeBudget(modelWeightsBytes: 1_000_000_000)
        let large = KVCacheStore.computeBudget(modelWeightsBytes: 4_000_000_000)
        #expect(small >= large)
    }

    // MARK: - cacheBytes

    @Test func cacheBytesZeroForEmptyCache() {
        let cache: [any KVCache] = [KVCacheSimple()]
        let bytes = KVCacheStore.cacheBytes(cache)
        #expect(bytes == 0)
    }

    @Test func cacheBytesZeroForEmptyArray() {
        let bytes = KVCacheStore.cacheBytes([])
        #expect(bytes == 0)
    }

    // MARK: - Update existing session

    @Test func putCacheUpdatesExistingSession() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m")
        #expect(store.getCache(sessionId: "s1", modelName: "m").0 != nil)

        let newCache = makeCache()
        store.putCache(sessionId: "s1", cache: newCache, tokens: nil, modelName: "m")

        let retrieved = store.getCache(sessionId: "s1", modelName: "m")
        #expect(retrieved.0 != nil)
        #expect(retrieved.0!.count == 1)
    }

    @Test func putCacheCanChangeModel() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "old")
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "new")

        #expect(store.getCache(sessionId: "s1", modelName: "new").0 != nil)
    }

    // MARK: - totalHotBytes tracking (uses _testPutSized to avoid Metal)

    @Test func totalHotBytesTracksInserts() {
        var store = KVCacheStore()
        #expect(store.totalHotBytes == 0)

        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        #expect(store.totalHotBytes == 1000)

        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 2000)
        #expect(store.totalHotBytes == 3000)
    }

    @Test func totalHotBytesDecreasesOnInvalidate() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 2000)
        #expect(store.totalHotBytes == 3000)

        store.invalidate(sessionId: "s1")
        #expect(store.totalHotBytes == 2000)
    }

    @Test func totalHotBytesZeroAfterClearAll() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 2000)
        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 3000)
        store.clearAll()
        #expect(store.totalHotBytes == 0)
    }

    @Test func testPutSizedUpdatesHotBytesOnReplace() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 500)
        #expect(store.totalHotBytes == 500)

        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 2000)
        #expect(store.totalHotBytes == 2000)
    }

    // MARK: - ensureBudget eviction

    @Test func ensureBudgetEvictsLRUWhenOverBudget() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s3", modelName: "m", sizeBytes: 1000)
        #expect(store.totalHotBytes == 3000)

        // Access s2 and s3 to make s1 the coldest
        _ = store.getCache(sessionId: "s2", modelName: "m")
        _ = store.getCache(sessionId: "s3", modelName: "m")

        // Budget allows only 2 entries
        store.ensureBudget(2001)

        // s1 was coldest and should have been evicted
        #expect(store.totalHotBytes <= 2001)
    }

    @Test func ensureBudgetEvictsMultipleEntries() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s3", modelName: "m", sizeBytes: 1000)

        // Budget of 0 should evict everything from hot tier
        store.ensureBudget(0)
        #expect(store.totalHotBytes == 0)
    }

    @Test func ensureBudgetPreservesMRU() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s2", modelName: "m", sizeBytes: 1000)
        store._testPutSized(sessionId: "s3", modelName: "m", sizeBytes: 1000)

        // Touch s3 to make it MRU
        _ = store.getCache(sessionId: "s3", modelName: "m")

        // Budget for exactly 1 entry
        store.ensureBudget(1000)

        // s3 (most recently used) should survive
        #expect(store.getCache(sessionId: "s3", modelName: "m").0 != nil)
        #expect(store.totalHotBytes == 1000)
    }

    // MARK: - evictToSSD

    @Test func evictToSSDClearsHotCache() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        #expect(store.totalHotBytes == 1000)

        store.evictToSSD(sessionId: "s1")
        #expect(store.totalHotBytes == 0)
    }

    @Test func evictToSSDIsIdempotent() {
        var store = KVCacheStore()
        store._testPutSized(sessionId: "s1", modelName: "m", sizeBytes: 1000)
        store.evictToSSD(sessionId: "s1")
        #expect(store.totalHotBytes == 0)

        // Second eviction should be a no-op (cache already nil, removed from LRU)
        store.evictToSSD(sessionId: "s1")
        #expect(store.totalHotBytes == 0)
    }

    // MARK: - putCache clears stale ssdPath

    @Test func putCacheClearsSsdPath() {
        var store = KVCacheStore()
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m")
        store.putCache(sessionId: "s1", cache: makeCache(), tokens: nil, modelName: "m")

        // After re-put, the entry is still hot-retrievable (ssdPath cleared internally).
        #expect(store.getCache(sessionId: "s1", modelName: "m").0 != nil)
    }

    // MARK: - Prefix key null-byte delimiter

    @Test func prefixKeyWithColonInModelName() {
        let k1 = KVCacheStore.prefixKey(modelName: "org:model", hash: "h1")
        let k2 = KVCacheStore.prefixKey(modelName: "org", hash: "model_h1")
        #expect(k1 != k2)
    }

    // MARK: - isValidCache (hybrid model support)

    /// A fresh KVCacheSimple has no keys/values yet → state is empty → invalid.
    @Test func isValidCache_falseForFreshKVCacheSimple() {
        let cache: [any KVCache] = [KVCacheSimple()]
        #expect(!KVCacheStore._testIsValidCache(cache))
    }

    /// An empty array is invalid.
    @Test func isValidCache_falseForEmptyArray() {
        #expect(!KVCacheStore._testIsValidCache([]))
    }

    /// A KVCacheSimple whose state has been set (simulating post-prefill) is valid.
    /// Setting `state` also sets offset = keys.dim(2) via the KVCacheSimple setter.
    @Test func isValidCache_trueForKVCacheSimpleWithState() {
        let cache = KVCacheSimple()
        // Inject a 2-element state (keys + values) as if prefill ran.
        // Shape [1, 1, 4, 1] → dim(2) == 4 → offset becomes 4.
        let fakeKeys = MLX.zeros([1, 1, 4, 1])
        let fakeValues = MLX.zeros([1, 1, 4, 1])
        cache.state = [fakeKeys, fakeValues]
        #expect(cache.offset == 4)
        #expect(KVCacheStore._testIsValidCache([cache]))
    }

    /// An ArraysCache always has offset == 0, so a cache made entirely of
    /// ArraysCache layers (like Qwen3.5-27B's Mamba layers) must be invalid.
    @Test func isValidCache_falseForAllArraysCache() {
        // ArraysCache(size: 2) starts with nil slots → state is empty → guard fails.
        // We need to inject state to pass the first guard (allSatisfy { !state.isEmpty }).
        // MambaCache extends ArraysCache and has size 2.
        let mamba = MambaCache()
        // Inject two dummy arrays so state is non-empty, but offset stays 0.
        mamba.state = [MLX.zeros([1]), MLX.zeros([1])]
        // offset is still 0 because ArraysCache never updates it.
        #expect(mamba.offset == 0)
        #expect(!KVCacheStore._testIsValidCache([mamba]))
    }

    /// A hybrid cache (MambaCache layers interleaved with a KVCacheSimple layer that
    /// has a positive offset) must be considered valid — this is the Qwen3.5-27B case.
    @Test func isValidCache_trueForHybridCacheWithOneValidKVLayer() {
        // Simulate 3 Mamba layers + 1 KVCacheSimple layer (every 4th layer pattern).
        let mamba1 = MambaCache()
        let mamba2 = MambaCache()
        let mamba3 = MambaCache()
        mamba1.state = [MLX.zeros([1]), MLX.zeros([1])]
        mamba2.state = [MLX.zeros([1]), MLX.zeros([1])]
        mamba3.state = [MLX.zeros([1]), MLX.zeros([1])]

        let attn = KVCacheSimple()
        let fakeKeys = MLX.zeros([1, 1, 8, 1])
        let fakeValues = MLX.zeros([1, 1, 8, 1])
        attn.state = [fakeKeys, fakeValues]

        let hybrid: [any KVCache] = [mamba1, mamba2, mamba3, attn]
        #expect(KVCacheStore._testIsValidCache(hybrid))
    }

    /// A hybrid cache where the KVCacheSimple layer is present but still empty
    /// (offset == 0, empty state) must be invalid.
    @Test func isValidCache_falseForHybridCacheWithEmptyKVLayer() {
        let mamba = MambaCache()
        mamba.state = [MLX.zeros([1]), MLX.zeros([1])]

        let attn = KVCacheSimple()  // fresh — empty state, offset 0

        let hybrid: [any KVCache] = [mamba, attn]
        // attn.state is empty, so allSatisfy { !state.isEmpty } fails → invalid.
        #expect(!KVCacheStore._testIsValidCache(hybrid))
    }
}
