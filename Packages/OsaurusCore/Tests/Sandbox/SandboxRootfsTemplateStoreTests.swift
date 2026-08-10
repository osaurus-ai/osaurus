import Foundation
import Testing

@testable import OsaurusCore

/// Unit coverage for the copy-on-write rootfs template store: key
/// derivation, template capture/clone/prune, per-agent environment
/// clone lifecycle, stamp validity, and LRU-bounded eviction. Uses
/// small stand-in files — the store never inspects rootfs contents.
/// Serialized + storage-lock-guarded because everything lives under
/// the (test-root-redirected) container directory.
@Suite(.serialized)
struct SandboxRootfsTemplateStoreTests {

    private func withCleanStore(_ body: @Sendable () async throws -> Void) async rethrows {
        try await StoragePathsTestLock.shared.run {
            SandboxRootfsTemplateStore.removeAll()
            defer { SandboxRootfsTemplateStore.removeAll() }
            try await body()
        }
    }

    private func makeFakeRootfs(contents: String = "fake-rootfs") throws -> URL {
        let url = OsaurusPaths.container().appendingPathComponent("fake-rootfs-\(UUID().uuidString).ext4")
        try OsaurusPaths.ensureExists(OsaurusPaths.container())
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Keys

    @Test
    func templateKey_isStableAndDistinguishesInputs() {
        let a = SandboxRootfsTemplateStore.templateKey(
            imageReference: "ghcr.io/x@sha256:aaa", runtimeFormatVersion: "cz-0.35.0-oci")
        let b = SandboxRootfsTemplateStore.templateKey(
            imageReference: "ghcr.io/x@sha256:aaa", runtimeFormatVersion: "cz-0.35.0-oci")
        let c = SandboxRootfsTemplateStore.templateKey(
            imageReference: "ghcr.io/x@sha256:bbb", runtimeFormatVersion: "cz-0.35.0-oci")
        let d = SandboxRootfsTemplateStore.templateKey(
            imageReference: "ghcr.io/x@sha256:aaa", runtimeFormatVersion: "cz-0.36.0-oci")
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        #expect(a.count == 16)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test
    func safeName_rejectsTraversalAndEmpty() {
        #expect(SandboxRootfsTemplateStore.safeName("agent-abc-123") == "agent-abc-123")
        #expect(!SandboxRootfsTemplateStore.safeName("../../etc").contains("/"))
        #expect(!SandboxRootfsTemplateStore.safeName("../../etc").contains("."))
        #expect(SandboxRootfsTemplateStore.safeName("") == "agent")
        #expect(SandboxRootfsTemplateStore.safeName("...///") == "agent")
    }

    // MARK: - Templates

    @Test
    func captureAndCloneTemplate_roundTrips() async throws {
        try await withCleanStore {
            let rootfs = try makeFakeRootfs(contents: "pristine")
            defer { try? FileManager.default.removeItem(at: rootfs) }

            let key = "abc123"
            #expect(!SandboxRootfsTemplateStore.hasTemplate(key: key))
            try SandboxRootfsTemplateStore.captureTemplate(from: rootfs, key: key)
            #expect(SandboxRootfsTemplateStore.hasTemplate(key: key))

            let clone = OsaurusPaths.container().appendingPathComponent("clone.ext4")
            defer { try? FileManager.default.removeItem(at: clone) }
            try SandboxRootfsTemplateStore.cloneTemplate(key: key, to: clone)
            #expect(try String(contentsOf: clone, encoding: .utf8) == "pristine")

            // Clone replaces an existing destination.
            try Data("stale".utf8).write(to: clone)
            try SandboxRootfsTemplateStore.cloneTemplate(key: key, to: clone)
            #expect(try String(contentsOf: clone, encoding: .utf8) == "pristine")
        }
    }

    @Test
    func captureTemplate_isIdempotentAndPrunesOtherKeys() async throws {
        try await withCleanStore {
            let first = try makeFakeRootfs(contents: "v1")
            let second = try makeFakeRootfs(contents: "v2")
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }

            try SandboxRootfsTemplateStore.captureTemplate(from: first, key: "old-key")
            try SandboxRootfsTemplateStore.captureTemplate(from: second, key: "new-key")
            // Only the current pin's template survives.
            #expect(!SandboxRootfsTemplateStore.hasTemplate(key: "old-key"))
            #expect(SandboxRootfsTemplateStore.hasTemplate(key: "new-key"))

            // Re-capture with different contents is a no-op (immutable).
            try SandboxRootfsTemplateStore.captureTemplate(from: first, key: "new-key")
            let clone = OsaurusPaths.container().appendingPathComponent("c.ext4")
            defer { try? FileManager.default.removeItem(at: clone) }
            try SandboxRootfsTemplateStore.cloneTemplate(key: "new-key", to: clone)
            #expect(try String(contentsOf: clone, encoding: .utf8) == "v2")
        }
    }

    @Test
    func cloneTemplate_missingTemplateThrows() async {
        await withCleanStore {
            let dest = OsaurusPaths.container().appendingPathComponent("nope.ext4")
            #expect(throws: (any Error).self) {
                try SandboxRootfsTemplateStore.cloneTemplate(key: "missing", to: dest)
            }
        }
    }

    // MARK: - Environments

    @Test
    func ensureEnvironment_clonesOnceThenReusesUntilKeyMoves() async throws {
        try await withCleanStore {
            let rootfs = try makeFakeRootfs(contents: "base-v1")
            defer { try? FileManager.default.removeItem(at: rootfs) }
            try SandboxRootfsTemplateStore.captureTemplate(from: rootfs, key: "k1")

            let env = try SandboxRootfsTemplateStore.ensureEnvironment(agentName: "agent-a", key: "k1")
            #expect(SandboxRootfsTemplateStore.environmentIsValid(agentName: "agent-a", key: "k1"))

            // Simulate the agent mutating its clone; re-ensure must NOT
            // re-clone (state persists across boots).
            try Data("base-v1+apk-installs".utf8).write(to: env)
            _ = try SandboxRootfsTemplateStore.ensureEnvironment(agentName: "agent-a", key: "k1")
            #expect(try String(contentsOf: env, encoding: .utf8) == "base-v1+apk-installs")

            // A key move (image/runtime bump) makes the clone stale and
            // re-clones from the new template.
            let rootfs2 = try makeFakeRootfs(contents: "base-v2")
            defer { try? FileManager.default.removeItem(at: rootfs2) }
            try SandboxRootfsTemplateStore.captureTemplate(from: rootfs2, key: "k2")
            #expect(!SandboxRootfsTemplateStore.environmentIsValid(agentName: "agent-a", key: "k2"))
            _ = try SandboxRootfsTemplateStore.ensureEnvironment(agentName: "agent-a", key: "k2")
            #expect(try String(contentsOf: env, encoding: .utf8) == "base-v2")
        }
    }

    @Test
    func resetEnvironment_discardsTheClone() async throws {
        try await withCleanStore {
            let rootfs = try makeFakeRootfs()
            defer { try? FileManager.default.removeItem(at: rootfs) }
            try SandboxRootfsTemplateStore.captureTemplate(from: rootfs, key: "k1")
            _ = try SandboxRootfsTemplateStore.ensureEnvironment(agentName: "agent-a", key: "k1")
            #expect(SandboxRootfsTemplateStore.environmentIsValid(agentName: "agent-a", key: "k1"))

            try SandboxRootfsTemplateStore.resetEnvironment(agentName: "agent-a")
            #expect(!SandboxRootfsTemplateStore.environmentIsValid(agentName: "agent-a", key: "k1"))
            // Idempotent on a missing directory.
            try SandboxRootfsTemplateStore.resetEnvironment(agentName: "agent-a")
        }
    }

    @Test
    func enforceLimit_evictsLRUButProtectsCurrentAndKeepsCap() async throws {
        try await withCleanStore {
            let rootfs = try makeFakeRootfs()
            defer { try? FileManager.default.removeItem(at: rootfs) }
            try SandboxRootfsTemplateStore.captureTemplate(from: rootfs, key: "k1")

            for name in ["agent-a", "agent-b", "agent-c", "agent-d"] {
                _ = try SandboxRootfsTemplateStore.ensureEnvironment(agentName: name, key: "k1")
            }
            // Recency order (oldest → newest): a, b, c, d. Make `a` the
            // most recent, then protect `d`.
            SandboxRootfsTemplateStore.saveStamp(
                .init(key: "k1", lastUsedAt: Date().addingTimeInterval(60)),
                agentName: "agent-a"
            )

            let evicted = SandboxRootfsTemplateStore.enforceLimit(
                max: 2, currentKey: "k1", protecting: "agent-d")

            // b and c are the least recently used unprotected clones.
            #expect(Set(evicted) == ["agent-b", "agent-c"])
            #expect(SandboxRootfsTemplateStore.environmentIsValid(agentName: "agent-a", key: "k1"))
            #expect(SandboxRootfsTemplateStore.environmentIsValid(agentName: "agent-d", key: "k1"))
        }
    }

    @Test
    func enforceLimit_evictsStaleKeyClonesRegardlessOfCap() async throws {
        try await withCleanStore {
            let rootfs = try makeFakeRootfs()
            defer { try? FileManager.default.removeItem(at: rootfs) }
            try SandboxRootfsTemplateStore.captureTemplate(from: rootfs, key: "k-old")
            _ = try SandboxRootfsTemplateStore.ensureEnvironment(agentName: "agent-old", key: "k-old")

            let rootfs2 = try makeFakeRootfs()
            defer { try? FileManager.default.removeItem(at: rootfs2) }
            try SandboxRootfsTemplateStore.captureTemplate(from: rootfs2, key: "k-new")
            _ = try SandboxRootfsTemplateStore.ensureEnvironment(agentName: "agent-new", key: "k-new")

            let evicted = SandboxRootfsTemplateStore.enforceLimit(
                max: 10, currentKey: "k-new", protecting: "agent-new")
            #expect(evicted == ["agent-old"])
            #expect(SandboxRootfsTemplateStore.environmentIsValid(agentName: "agent-new", key: "k-new"))
        }
    }

    @Test
    func enforceLimit_neverEvictsTheProtectedEnvironmentEvenWhenOverCap() async throws {
        try await withCleanStore {
            let rootfs = try makeFakeRootfs()
            defer { try? FileManager.default.removeItem(at: rootfs) }
            try SandboxRootfsTemplateStore.captureTemplate(from: rootfs, key: "k1")
            _ = try SandboxRootfsTemplateStore.ensureEnvironment(agentName: "agent-only", key: "k1")

            let evicted = SandboxRootfsTemplateStore.enforceLimit(
                max: 1, currentKey: "k1", protecting: "agent-only")
            #expect(evicted.isEmpty)
            #expect(SandboxRootfsTemplateStore.environmentIsValid(agentName: "agent-only", key: "k1"))
        }
    }
}
