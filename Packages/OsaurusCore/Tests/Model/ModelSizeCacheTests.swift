//
//  ModelSizeCacheTests.swift
//  osaurusTests
//
//  Covers the on-disk model download-size cache: round-trip persistence,
//  revision-gated reuse/invalidation, and the revision-less TTL path.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelSizeCacheTests {

    /// Point `OsaurusPaths` at a throwaway root and clear the in-memory
    /// cache so each test starts from a clean, isolated state.
    private func withTempRoot(_ body: @Sendable (URL) -> Void) async {
        await OsaurusTestGlobals.withPathsLock {
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-size-cache-\(UUID().uuidString)", isDirectory: true)
            OsaurusPaths.overrideRoot = root
            ModelSizeCache.invalidateInMemory()
            defer {
                OsaurusPaths.overrideRoot = previous
                ModelSizeCache.invalidateInMemory()
                try? FileManager.default.removeItem(at: root)
            }
            body(root)
        }
    }

    @Test func record_thenReadBack_matchingRevision() async {
        await withTempRoot { _ in
            ModelSizeCache.record(id: "Org/Repo", bytes: 12_345, revision: "rev-a")

            // Exact id (case-insensitive) + matching revision returns bytes.
            #expect(ModelSizeCache.bytes(forId: "org/repo", matchingRevision: "rev-a") == 12_345)
            // Wrong revision invalidates.
            #expect(ModelSizeCache.bytes(forId: "org/repo", matchingRevision: "rev-b") == nil)
        }
    }

    @Test func persistsAcrossInMemoryReset() async {
        await withTempRoot { _ in
            ModelSizeCache.record(id: "Org/Repo", bytes: 999, revision: "r1")
            // Drop the in-memory copy; the next read must re-hydrate from disk.
            ModelSizeCache.invalidateInMemory()
            #expect(ModelSizeCache.bytes(forId: "Org/Repo", matchingRevision: "r1") == 999)
        }
    }

    @Test func revisionlessEntry_servedWithoutRevision() async {
        await withTempRoot { _ in
            ModelSizeCache.record(id: "a/b", bytes: 4_096, revision: nil)
            // No revision supplied -> any non-expired entry is accepted.
            #expect(ModelSizeCache.bytes(forId: "a/b") == 4_096)
        }
    }

    @Test func zeroBytes_notRecorded() async {
        await withTempRoot { _ in
            ModelSizeCache.record(id: "a/b", bytes: 0, revision: "r")
            #expect(ModelSizeCache.bytes(forId: "a/b") == nil)
        }
    }

    @Test func concreteRevisionEntry_servedWhenNoRevisionRequested() async {
        await withTempRoot { _ in
            ModelSizeCache.record(id: "a/b", bytes: 77, revision: "rev")
            // A concrete-revision entry is trusted even without a comparison
            // revision (revisions only change when the repo changes).
            #expect(ModelSizeCache.bytes(forId: "a/b") == 77)
        }
    }
}
