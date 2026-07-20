//
//  AgentRunSessionFreezeTests.swift
//  osaurusTests
//
//  Locks the `/agents/{id}/run` session-freeze contract at the store/unit
//  level: the second request for a session echoes the FIRST compose's
//  snapshot (fingerprint, manifest, SOUL, delegation set, image swap), a
//  (mode, toolMode) fingerprint flip invalidates the snapshot, and store
//  keys are agent-namespaced so two agents sharing a client-chosen
//  `session_id` can never cross-contaminate each other's frozen state.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct AgentRunSessionFreezeTests {

    private func uniqueSid() -> String { "sid-\(UUID().uuidString)" }

    // MARK: - Second request echoes the first compose's snapshot

    @Test
    func secondRequestEchoesFrozenSnapshot() async {
        let store = SessionToolStateStore.shared
        let agent = UUID()
        let key = HTTPHandler.agentSessionStoreKey(agentId: agent, sessionId: uniqueSid())
        let fingerprint = SessionToolState.fingerprint(executionMode: .none, toolMode: .auto)

        // First request: no snapshot yet → live compose records one,
        // including the delegation set + image generation-only swap.
        #expect(await store.get(key) == nil)
        await store.setInitial(
            key,
            alwaysLoadedNames: ["capabilities_load"],
            fingerprint: fingerprint,
            manifest: "MANIFEST-TURN-1",
            soul: "SOUL-TURN-1",
            delegationTools: ["image", "spawn"],
            imageGenerationOnly: true
        )

        // Second request with the SAME live fingerprint: nothing
        // invalidates and every frozen field echoes turn 1's bytes.
        let invalidated = await store.invalidateIfFingerprintChanged(
            key, liveFingerprint: fingerprint)
        #expect(!invalidated)
        let cached = await store.get(key)
        #expect(cached?.sessionFingerprint == fingerprint)
        #expect(cached?.frozenManifest == "MANIFEST-TURN-1")
        #expect(cached?.frozenSoul == "SOUL-TURN-1")
        #expect(cached?.initialAlwaysLoadedNames == ["capabilities_load"])
        #expect(cached?.frozenDelegationTools == ["image", "spawn"])
        #expect(cached?.frozenImageGenerationOnly == true)

        // `setInitial` stays idempotent: a racing turn-2 write must not
        // replace the frozen snapshot with drifted values.
        await store.setInitial(
            key,
            alwaysLoadedNames: ["capabilities_load", "late_tool"],
            fingerprint: fingerprint,
            manifest: "MANIFEST-DRIFTED",
            soul: "SOUL-DRIFTED",
            delegationTools: ["image", "spawn", "computer"],
            imageGenerationOnly: false
        )
        let afterRace = await store.get(key)
        #expect(afterRace?.frozenManifest == "MANIFEST-TURN-1")
        #expect(afterRace?.frozenDelegationTools == ["image", "spawn"])
        #expect(afterRace?.frozenImageGenerationOnly == true)

        await store.invalidate(key)
    }

    /// An EMPTY frozen delegation set is a valid snapshot, distinct from
    /// "no snapshot": later turns must not grow delegation tools the first
    /// turn didn't have.
    @Test
    func emptyFrozenDelegationSetIsAValidSnapshot() async {
        let store = SessionToolStateStore.shared
        let key = HTTPHandler.agentSessionStoreKey(agentId: UUID(), sessionId: uniqueSid())
        await store.setInitial(
            key,
            alwaysLoadedNames: [],
            fingerprint: "none/auto",
            delegationTools: [],
            imageGenerationOnly: false
        )
        let cached = await store.get(key)
        // Non-nil AND empty: the snapshot exists and pins zero tools.
        #expect(cached?.frozenDelegationTools?.isEmpty == true)
        #expect(cached?.frozenImageGenerationOnly == false)
        await store.invalidate(key)
    }

    // MARK: - Fingerprint flip invalidates

    @Test
    func fingerprintFlipInvalidatesFrozenSnapshot() async {
        let store = SessionToolStateStore.shared
        let key = HTTPHandler.agentSessionStoreKey(agentId: UUID(), sessionId: uniqueSid())
        let recordedFp = SessionToolState.fingerprint(executionMode: .none, toolMode: .auto)
        await store.setInitial(
            key,
            alwaysLoadedNames: ["capabilities_load"],
            fingerprint: recordedFp,
            manifest: "MANIFEST",
            soul: "SOUL",
            delegationTools: ["spawn"],
            imageGenerationOnly: false
        )

        // The (executionMode, toolMode) surface flipped → the whole frozen
        // snapshot (delegation set included) is dropped; the next compose
        // resolves live and records fresh.
        let flippedFp = SessionToolState.fingerprint(
            executionMode: .sandbox(hostRead: nil), toolMode: .auto)
        #expect(flippedFp != recordedFp)
        let invalidated = await store.invalidateIfFingerprintChanged(
            key, liveFingerprint: flippedFp)
        #expect(invalidated)
        #expect(await store.get(key) == nil)
    }

    // MARK: - Cross-agent key isolation

    /// `session_id` is client-chosen: two agents given the same value must
    /// resolve DIFFERENT store keys, so agent A's frozen snapshot is never
    /// echoed into agent B's session.
    @Test
    func sameSessionIdDifferentAgentsNeverShareState() async {
        let store = SessionToolStateStore.shared
        let sid = uniqueSid()
        let agentA = UUID()
        let agentB = UUID()
        let keyA = HTTPHandler.agentSessionStoreKey(agentId: agentA, sessionId: sid)
        let keyB = HTTPHandler.agentSessionStoreKey(agentId: agentB, sessionId: sid)
        #expect(keyA != keyB)

        await store.setInitial(
            keyA,
            alwaysLoadedNames: ["capabilities_load"],
            fingerprint: "none/auto",
            manifest: "AGENT-A-MANIFEST",
            soul: "AGENT-A-SOUL",
            delegationTools: ["image"],
            imageGenerationOnly: true
        )
        await store.recordUserPrefix(keyA, key: "msg-0", prefix: "AGENT-A-MEMORY ")

        // Agent B with the same client session_id sees a cold session:
        // no frozen snapshot, no replayed memory prefixes.
        #expect(await store.get(keyB) == nil)
        #expect(await store.frozenUserPrefixes(keyB).isEmpty)

        // And B's own snapshot never leaks back into A's.
        await store.setInitial(
            keyB,
            alwaysLoadedNames: [],
            fingerprint: "none/auto",
            manifest: "AGENT-B-MANIFEST",
            soul: "AGENT-B-SOUL",
            delegationTools: [],
            imageGenerationOnly: false
        )
        #expect(await store.get(keyA)?.frozenManifest == "AGENT-A-MANIFEST")
        #expect(await store.get(keyB)?.frozenManifest == "AGENT-B-MANIFEST")
        #expect(await store.frozenUserPrefixes(keyA) == ["msg-0": "AGENT-A-MEMORY "])

        await store.invalidate(keyA)
        await store.invalidate(keyB)
    }

    /// The key derivation itself: stable shape, agent-scoped, and the raw
    /// client string is preserved (no lossy hashing that could collide).
    @Test
    func agentSessionStoreKeyShape() {
        let agent = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let key = HTTPHandler.agentSessionStoreKey(agentId: agent, sessionId: "my-session")
        #expect(key == "agent:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE:my-session")
    }
}
