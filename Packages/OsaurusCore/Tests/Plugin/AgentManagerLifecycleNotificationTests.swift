//
//  AgentManagerLifecycleNotificationTests.swift
//  OsaurusCoreTests
//
//  Pins the `.agentAdded` and `.agentRemoved` notifications introduced
//  in `Plugin Config + Loading Hardening`. PluginManager subscribes to
//  these so newly added agents get an initial config + tunnel-URL push
//  on every loaded plugin without waiting for the next force-reload,
//  and so deleted agents trigger plugin-side webhook deregistration.
//
//  Also pins `delete(id:)`'s per-agent keychain sweep — without it,
//  a deleted agent's bot tokens / OAuth credentials would linger in
//  Keychain Access forever.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct AgentManagerLifecycleNotificationTests {

    // MARK: - Helpers

    private func makeCustomAgent(name: String) -> Agent {
        Agent(
            name: "\(name)-\(UUID().uuidString.prefix(6))",
            systemPrompt: "Test identity",
            agentAddress: "test-lifecycle-\(UUID().uuidString)"
        )
    }

    /// Subscribes to `name` and returns the `agentId` from the first
    /// notification received, or nil after `timeoutMs`. We capture only
    /// the `agentId` (a `UUID`, value type) rather than the whole
    /// `Notification` so the observer block stays free of `Sendable`
    /// violations under Swift 6 strict concurrency.
    private func awaitAgentIdNotification(
        _ name: Notification.Name,
        triggeredBy action: () async -> Void,
        timeoutMs: Int = 1_000
    ) async -> UUID? {
        let received = AgentIdBox()
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { note in
            if let id = note.userInfo?["agentId"] as? UUID {
                received.set(id)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await action()

        // Brief polling loop. The notification is posted synchronously
        // from `add` / `delete` on the main actor, so it's already
        // delivered by the time `action()` returns — but we add a
        // bounded wait to keep the test robust against future async
        // tweaks.
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let id = received.value { return id }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return received.value
    }

    /// Lock-protected, sendable across actor boundaries. The
    /// notification observer block runs nonisolated, so the box can't
    /// be `@MainActor`. `UUID` values are `Sendable`.
    private final class AgentIdBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: UUID?
        var value: UUID? { lock.withLock { _value } }
        func set(_ id: UUID) { lock.withLock { _value = id } }
    }

    // MARK: - .agentAdded

    @Test
    func addPostsAgentAddedWithAgentIdInUserInfo() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = self.makeCustomAgent(name: "AddNotify")

            let receivedId = await self.awaitAgentIdNotification(.agentAdded) {
                AgentManager.shared.add(agent)
            }

            // Synchronously delete inside the temp-root block so the
            // agent record never survives past `ChatHistoryTestStorage.run`.
            // (A deferred Task would run after the override root was
            // restored and try to delete a missing file in the real
            // ~/.osaurus/agents directory.)
            _ = await AgentManager.shared.delete(id: agent.id)

            let id = try #require(receivedId, "expected .agentAdded to fire after add()")
            #expect(id == agent.id)
        }
    }

    @Test
    func multipleAddsEachPostNotification() async throws {
        try await ChatHistoryTestStorage.run {
            let agentA = self.makeCustomAgent(name: "MultiAddA")
            let agentB = self.makeCustomAgent(name: "MultiAddB")

            let receivedIds = ReceivedIdsBox()
            let token = NotificationCenter.default.addObserver(
                forName: .agentAdded,
                object: nil,
                queue: .main
            ) { note in
                if let id = note.userInfo?["agentId"] as? UUID {
                    receivedIds.append(id)
                }
            }

            AgentManager.shared.add(agentA)
            AgentManager.shared.add(agentB)

            // Drain any pending main-queue work the observer was scheduled on.
            try? await Task.sleep(nanoseconds: 50_000_000)

            NotificationCenter.default.removeObserver(token)
            _ = await AgentManager.shared.delete(id: agentA.id)
            _ = await AgentManager.shared.delete(id: agentB.id)

            #expect(receivedIds.contains(agentA.id))
            #expect(receivedIds.contains(agentB.id))
        }
    }

    /// Lock-protected sibling of `AgentIdBox` for the multi-id case.
    private final class ReceivedIdsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [UUID] = []
        func append(_ id: UUID) { lock.withLock { ids.append(id) } }
        func contains(_ id: UUID) -> Bool { lock.withLock { ids.contains(id) } }
    }

    // MARK: - .agentRemoved

    @Test
    func deletePostsAgentRemovedWithAgentIdInUserInfo() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = self.makeCustomAgent(name: "DeleteNotify")
            AgentManager.shared.add(agent)

            let receivedId = await self.awaitAgentIdNotification(.agentRemoved) {
                _ = await AgentManager.shared.delete(id: agent.id)
            }

            let id = try #require(receivedId, "expected .agentRemoved to fire after delete()")
            #expect(id == agent.id)
        }
    }

    @Test
    func deletingNonExistentAgentDoesNotFireNotification() async throws {
        try await ChatHistoryTestStorage.run {
            // No `add` first — the agent has never existed.
            let bogus = UUID()

            let received = await self.awaitAgentIdNotification(
                .agentRemoved,
                triggeredBy: {
                    _ = await AgentManager.shared.delete(id: bogus)
                },
                timeoutMs: 200
            )

            #expect(
                received == nil,
                "delete() against an unknown id must short-circuit before posting"
            )
        }
    }

    // MARK: - Keychain sweep on delete

    @Test
    func deleteSweepsPerAgentKeychainSecrets() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = self.makeCustomAgent(name: "SecretSweep")
            AgentManager.shared.add(agent)

            let pluginA = "com.test.sweep.\(UUID().uuidString)"
            let pluginB = "com.test.sweep.\(UUID().uuidString)"

            // Two secrets under the doomed agent + one under a
            // bystander agent. The bystander entry must survive.
            let bystander = UUID()
            ToolSecretsKeychain.saveSecret("tokenA", id: "k1", for: pluginA, agentId: agent.id)
            ToolSecretsKeychain.saveSecret("tokenB", id: "k2", for: pluginB, agentId: agent.id)
            ToolSecretsKeychain.saveSecret("survive", id: "k1", for: pluginA, agentId: bystander)

            defer {
                ToolSecretsKeychain.deleteAllSecrets(forAgent: bystander)
            }

            _ = await AgentManager.shared.delete(id: agent.id)

            #expect(ToolSecretsKeychain.getSecret(id: "k1", for: pluginA, agentId: agent.id) == nil)
            #expect(ToolSecretsKeychain.getSecret(id: "k2", for: pluginB, agentId: agent.id) == nil)
            #expect(
                ToolSecretsKeychain.getSecret(id: "k1", for: pluginA, agentId: bystander) == "survive",
                "bystander agent's secrets must NOT be swept"
            )
        }
    }

    // MARK: - Built-in agent guard

    @Test
    func deletingBuiltInDefaultAgentReturnsFalseAndDoesNotPost() async throws {
        try await ChatHistoryTestStorage.run {
            // The default agent is treated as built-in. AgentStore.delete
            // refuses to remove it, which makes delete() bail out early
            // before posting `.agentRemoved`.
            let received = await self.awaitAgentIdNotification(
                .agentRemoved,
                triggeredBy: {
                    let result = await AgentManager.shared.delete(id: Agent.defaultId)
                    #expect(result.deleted == false)
                },
                timeoutMs: 200
            )

            #expect(
                received == nil,
                "deleting the built-in default agent must not post .agentRemoved"
            )
        }
    }
}
