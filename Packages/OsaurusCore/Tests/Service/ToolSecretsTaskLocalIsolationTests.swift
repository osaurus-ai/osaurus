// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

private actor ToolSecretsTestBarrier {
    private let participants: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) {
        self.participants = participants
    }

    func wait() async {
        arrivals += 1
        guard arrivals < participants else {
            let waiting = waiters
            waiters.removeAll(keepingCapacity: true)
            for waiter in waiting {
                waiter.resume()
            }
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }
}

private actor ToolSecretsTestSignal {
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        signaled = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
        }
    }
}

@Suite("Tool secret task-local isolation")
struct ToolSecretsTaskLocalIsolationTests {

    @Test("parallel task-local stores cannot observe or delete each other's same account")
    func parallelStoresAreIsolated() async {
        let pluginId = "com.test.task-local.\(UUID().uuidString)"
        let agentId = UUID()
        let firstSaved = ToolSecretsTestBarrier(participants: 2)
        let firstRead = ToolSecretsTestBarrier(participants: 2)
        let firstDeleted = ToolSecretsTestSignal()
        let secondObserved = ToolSecretsTestSignal()
        let secondSaved = ToolSecretsTestBarrier(participants: 2)
        let secondDeleted = ToolSecretsTestSignal()

        async let first: (String?, String?) = ToolSecretsKeychain._withInMemoryStoreForTesting {
            ToolSecretsKeychain.saveSecret("first", id: "same", for: pluginId, agentId: agentId)
            await firstSaved.wait()

            let before = ToolSecretsKeychain.getSecret(id: "same", for: pluginId, agentId: agentId)
            await firstRead.wait()

            ToolSecretsKeychain.deleteSecret(id: "same", for: pluginId, agentId: agentId)
            await firstDeleted.signal()
            await secondObserved.wait()

            // Recreate the same account in this store before the other task
            // deletes its account. The final read proves that deletion in the
            // sibling task did not reach this task's store.
            ToolSecretsKeychain.saveSecret("first-again", id: "same", for: pluginId, agentId: agentId)
            await secondSaved.wait()
            await secondDeleted.wait()
            let afterSiblingDelete = ToolSecretsKeychain.getSecret(
                id: "same", for: pluginId, agentId: agentId)
            return (before, afterSiblingDelete)
        }

        async let second: (String?, String?) = ToolSecretsKeychain._withInMemoryStoreForTesting {
            ToolSecretsKeychain.saveSecret("second", id: "same", for: pluginId, agentId: agentId)
            await firstSaved.wait()

            let before = ToolSecretsKeychain.getSecret(id: "same", for: pluginId, agentId: agentId)
            await firstRead.wait()

            await firstDeleted.wait()
            let afterSiblingDelete = ToolSecretsKeychain.getSecret(
                id: "same", for: pluginId, agentId: agentId)
            await secondObserved.signal()

            ToolSecretsKeychain.saveSecret("second-again", id: "same", for: pluginId, agentId: agentId)
            await secondSaved.wait()
            ToolSecretsKeychain.deleteSecret(id: "same", for: pluginId, agentId: agentId)
            await secondDeleted.signal()
            return (before, afterSiblingDelete)
        }

        let (firstResult, secondResult) = await (first, second)
        #expect(firstResult.0 == "first")
        #expect(firstResult.1 == "first-again")
        #expect(secondResult.0 == "second")
        #expect(secondResult.1 == "second")
    }

    @Test("unbound test-host operations fail closed")
    func unboundOperationsDoNotPersist() {
        let pluginId = "com.test.unbound.\(UUID().uuidString)"
        let agentId = UUID()

        #expect(!ToolSecretsKeychain.saveSecret(
            "must-not-persist", id: "key", for: pluginId, agentId: agentId))
        #expect(ToolSecretsKeychain.getSecret(id: "key", for: pluginId, agentId: agentId) == nil)
        #expect(ToolSecretsKeychain.deleteSecret(id: "key", for: pluginId, agentId: agentId))
    }

    @Test("detached tasks require the exact captured store context")
    func detachedTasksRequireExplicitContextPropagation() async {
        let pluginId = "com.test.detached.\(UUID().uuidString)"
        let agentId = UUID()

        await ToolSecretsKeychain._withInMemoryStoreForTesting {
            #expect(
                ToolSecretsKeychain.saveSecret(
                    "scoped", id: "key", for: pluginId, agentId: agentId
                )
            )
            let context = ToolSecretsKeychain._captureInMemoryStoreContextForTesting()

            let values = await Task.detached { () -> (String?, String?) in
                let unbound = ToolSecretsKeychain.getSecret(
                    id: "key", for: pluginId, agentId: agentId
                )
                let rebound = ToolSecretsKeychain._withInMemoryStoreContextForTesting(context) {
                    ToolSecretsKeychain.getSecret(
                        id: "key", for: pluginId, agentId: agentId
                    )
                }
                return (unbound, rebound)
            }.value

            #expect(values.0 == nil)
            #expect(values.1 == "scoped")
        }
    }
}
