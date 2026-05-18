//
//  GenerativeGreetingPoolPersistenceTests.swift
//  osaurusTests
//
//  End-to-end checks for `GenerativeGreetingPool`'s on-disk cache.
//  The pool is a singleton actor, so we run the cases under
//  `StoragePathsTestLock` and rebuild in-memory state via the
//  test-only `_testingReloadFromDisk` / `_testingResetInMemory`
//  hooks. Hand-crafted JSON exercises the load-side TTL filter
//  without waiting 30 real minutes for an entry to expire.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("GenerativeGreetingPool persistence", .serialized)
struct GenerativeGreetingPoolPersistenceTests {

    // MARK: - Helpers

    /// Synthesise a fresh `Agent` for use as a pool key. We don't go
    /// through `AgentManager` because the test only needs an `id` and
    /// the few fields `GenerativeGreetingPool.revision(for:)` hashes
    /// over; mocking those out keeps the test runtime independent of
    /// the agent store on disk.
    private func makeAgent(name: String = "Persistence Probe") -> Agent {
        Agent(
            id: UUID(),
            name: name,
            description: "Synthetic agent for pool persistence tests.",
            systemPrompt: "Test prompt for \(name).",
            isBuiltIn: false
        )
    }

    private func makeGreeting() -> GenerativeGreeting {
        GenerativeGreeting(
            greeting: "Soho Delight",
            subtitle: "Map your next move with a quick win.",
            actions: [
                AgentQuickAction(icon: "sparkles", text: "Boost", prompt: "Give me one bold idea for "),
                AgentQuickAction(icon: "calendar", text: "Plan Ahead", prompt: "Sketch tomorrow's plan for "),
            ]
        )
    }

    /// Wrap a test body so it runs against an isolated temp root.
    /// Cleans up after itself even on failure so the next case
    /// starts from a fresh on-disk state.
    private func withTempRoot(
        _ body: @Sendable (URL) async throws -> Void
    ) async rethrows {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-greeting-pool-\(UUID().uuidString)",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previous = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            await GenerativeGreetingPool.shared._testingResetInMemory()
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            try await body(root)
        }
    }

    // MARK: - Save round-trip

    @Test("seed + flushPendingSave persists entries that survive a reload")
    func saveAndReloadRoundTrip() async throws {
        try await withTempRoot { _ in
            let agent = makeAgent()
            let greeting = makeGreeting()

            await GenerativeGreetingPool.shared.seed(
                greeting,
                for: agent,
                model: "foundation"
            )
            await GenerativeGreetingPool.shared.flushPendingSave()

            // File should exist + be valid JSON with our agent id.
            let url = OsaurusPaths.greetingPoolCacheFile()
            #expect(FileManager.default.fileExists(atPath: url.path))
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["schemaVersion"] as? Int == 1)
            let pools = json?["pools"] as? [String: [[String: Any]]]
            #expect(pools?[agent.id.uuidString] != nil)

            // Reload from disk and confirm the entry survived.
            await GenerativeGreetingPool.shared._testingReloadFromDisk()
            let count = await GenerativeGreetingPool.shared._testingEntryCount(for: agent.id)
            #expect(count == 1)

            // popFresh should now return our seeded greeting (revision
            // matches because we haven't mutated the agent fields the
            // pool hashes over).
            let popped = await GenerativeGreetingPool.shared.popFresh(
                for: agent,
                model: "foundation"
            )
            #expect(popped?.greeting == "Soho Delight")
        }
    }

    // MARK: - TTL semantics

    @Test("entries older than TTL are dropped on reload")
    func ttlExpiredEntriesDropped() async throws {
        try await withTempRoot { _ in
            let agent = makeAgent()

            await GenerativeGreetingPool.shared.seed(
                makeGreeting(),
                for: agent,
                model: "foundation"
            )
            await GenerativeGreetingPool.shared.flushPendingSave()

            // Rewrite the on-disk `createdAt` to a value far in the past
            // so the next restore treats the entry as expired. We use
            // JSONSerialization on the raw JSON rather than rebuilding
            // the `PersistedPool` shape because the persisted format is
            // an internal detail — touching it directly via dictionaries
            // catches accidental key renames.
            let url = OsaurusPaths.greetingPoolCacheFile()
            let data = try Data(contentsOf: url)
            var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var pools = root["pools"] as! [String: [[String: Any]]]
            var entries = pools[agent.id.uuidString]!
            // -1_000_000 seconds since reference date == late 1968 —
            // far older than the 30-minute TTL the pool uses today.
            entries[0]["createdAt"] = -1_000_000.0
            pools[agent.id.uuidString] = entries
            root["pools"] = pools
            let mutated = try JSONSerialization.data(withJSONObject: root, options: [])
            try mutated.write(to: url)

            await GenerativeGreetingPool.shared._testingReloadFromDisk()
            let count = await GenerativeGreetingPool.shared._testingEntryCount(for: agent.id)
            #expect(count == 0)
        }
    }

    // MARK: - Schema versioning

    @Test("payloads with a future schema version are ignored")
    func futureSchemaVersionIgnored() async throws {
        try await withTempRoot { _ in
            let agent = makeAgent()

            // Write a syntactically valid payload that claims a higher
            // schema version. The pool must refuse to load it rather
            // than crash or silently accept potentially-incompatible
            // entries.
            let payload: [String: Any] = [
                "schemaVersion": 999,
                "pools": [
                    agent.id.uuidString: [
                        [
                            "greeting": [
                                "greeting": "Future Hello",
                                "subtitle": "From a build that doesn't exist yet.",
                                "actions": [
                                    [
                                        "id": UUID().uuidString,
                                        "icon": "sparkles",
                                        "text": "A",
                                        "prompt": "x ",
                                    ]
                                ],
                            ],
                            "model": "foundation",
                            "agentRevision": 0,
                            "createdAt": Date().timeIntervalSinceReferenceDate,
                        ]
                    ]
                ],
            ]
            let url = OsaurusPaths.greetingPoolCacheFile()
            OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
            try JSONSerialization.data(withJSONObject: payload, options: []).write(to: url)

            await GenerativeGreetingPool.shared._testingReloadFromDisk()
            let count = await GenerativeGreetingPool.shared._testingEntryCount(for: agent.id)
            #expect(count == 0)
        }
    }
}
