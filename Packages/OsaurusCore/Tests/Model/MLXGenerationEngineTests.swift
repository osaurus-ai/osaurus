//
//  MLXGenerationEngineTests.swift
//  osaurusTests
//
//  Tests for free functions and helpers in MLXGenerationEngine.swift
//  that can be exercised without Metal / GPU.
//

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import OsaurusCore

struct MLXGenerationEngineTests {

    // MARK: effectiveCacheOffset

    /// All layers are MambaCache (ArraysCache subclass) → offset is always 0 for all.
    /// effectiveCacheOffset must fall through to the last branch and return 0.
    @Test func effectiveCacheOffset_allArraysCache_returnsZero() {
        let layers: [any KVCache] = [MambaCache(), MambaCache(), MambaCache()]
        #expect(effectiveCacheOffset(layers) == 0)
    }

    /// Empty cache array → returns 0.
    @Test func effectiveCacheOffset_emptyArray_returnsZero() {
        #expect(effectiveCacheOffset([]) == 0)
    }

    /// First layer is a KVCacheSimple with offset set — should return that offset.
    @Test func effectiveCacheOffset_firstLayerIsKVCacheSimple_returnsItsOffset() {
        let kv = KVCacheSimple()
        // Inject state so offset becomes 4 (key dim(2) == 4).
        kv.state = [MLX.zeros([1, 1, 4, 1]), MLX.zeros([1, 1, 4, 1])]
        #expect(kv.offset == 4)

        let layers: [any KVCache] = [kv]
        #expect(effectiveCacheOffset(layers) == 4)
    }

    /// Hybrid: MambaCache layers come first (offset 0), then a KVCacheSimple with
    /// a real offset.  effectiveCacheOffset must skip Mamba layers and return the
    /// KVCacheSimple's offset.
    @Test func effectiveCacheOffset_hybridCache_skipsArraysCacheReturnsKVOffset() {
        let mamba1 = MambaCache()
        let mamba2 = MambaCache()
        let mamba3 = MambaCache()

        let kv = KVCacheSimple()
        kv.state = [MLX.zeros([1, 1, 8, 1]), MLX.zeros([1, 1, 8, 1])]
        #expect(kv.offset == 8)

        let layers: [any KVCache] = [mamba1, mamba2, mamba3, kv]
        #expect(effectiveCacheOffset(layers) == 8)
    }

    /// If there are multiple KVCacheSimple layers, the first one's offset is returned.
    @Test func effectiveCacheOffset_multipleKVLayers_returnsFirstOffset() {
        let kv1 = KVCacheSimple()
        kv1.state = [MLX.zeros([1, 1, 4, 1]), MLX.zeros([1, 1, 4, 1])]

        let kv2 = KVCacheSimple()
        kv2.state = [MLX.zeros([1, 1, 16, 1]), MLX.zeros([1, 1, 16, 1])]

        let layers: [any KVCache] = [kv1, kv2]
        #expect(effectiveCacheOffset(layers) == 4)
    }

    /// Hybrid with KVCacheSimple that has no state yet (offset 0).
    /// Should return 0 from that layer (not skip it).
    @Test func effectiveCacheOffset_hybridWithFreshKVLayer_returnsZero() {
        let mamba = MambaCache()
        let kv = KVCacheSimple()  // fresh, offset == 0
        let layers: [any KVCache] = [mamba, kv]
        #expect(effectiveCacheOffset(layers) == 0)
    }

    @Test func hasWrappedRotatingCache_returnsTrueWhenPromptExceedsWindow() {
        let rotating = RotatingKVCache(maxSize: 1024, keep: 4)
        let layers: [any KVCache] = [rotating]

        #expect(hasWrappedRotatingCache(layers, cachedTokenCount: 2048))
    }

    @Test func hasWrappedRotatingCache_returnsFalseWhenPromptFitsWindow() {
        let rotating = RotatingKVCache(maxSize: 1024, keep: 4)
        let layers: [any KVCache] = [rotating]

        #expect(!hasWrappedRotatingCache(layers, cachedTokenCount: 1024))
    }

    @Test func hasWrappedRotatingCache_ignoresNonRotatingLayers() {
        let kv = KVCacheSimple()
        let layers: [any KVCache] = [kv]

        #expect(!hasWrappedRotatingCache(layers, cachedTokenCount: 4096))
    }

    @Test func snapshotCopyByteLimit_capsAtEightGiB() {
        let limit = MLXGenerationEngine.snapshotCopyByteLimit(
            physicalMemory: 128 * 1024 * 1024 * 1024
        )

        #expect(limit == 8 * 1024 * 1024 * 1024)
    }

    @Test func snapshotCopyByteLimit_reservesOneEighthOfSystemMemory() {
        let limit = MLXGenerationEngine.snapshotCopyByteLimit(
            physicalMemory: 32 * 1024 * 1024 * 1024
        )

        #expect(limit == 4 * 1024 * 1024 * 1024)
    }

    @Test func shouldSkipSnapshotCopy_trueWhenCacheExceedsLimit() {
        let skip = MLXGenerationEngine.shouldSkipSnapshotCopy(
            cacheBytes: 9 * 1024 * 1024 * 1024,
            physicalMemory: 128 * 1024 * 1024 * 1024
        )

        #expect(skip)
    }

    @Test func shouldSkipSnapshotCopy_falseWhenCacheFitsLimit() {
        let skip = MLXGenerationEngine.shouldSkipSnapshotCopy(
            cacheBytes: 3 * 1024 * 1024 * 1024,
            physicalMemory: 32 * 1024 * 1024 * 1024
        )

        #expect(!skip)
    }
}
