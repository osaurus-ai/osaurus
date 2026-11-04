//
//  RelayAddAgentQueueTests.swift
//  OsaurusCoreTests
//
//  Re-pairing the phone turns several agents' relay back on over a live
//  tunnel. The relay holds one challenge per tunnel, so those adds must go
//  one at a time; sent together, all but the last came back invalid_nonce
//  and stayed off the relay (the phone then got agent_offline on cellular).
//  Each attempt's token keeps a dropped attempt from signing a stale add.
//

import Foundation
import Testing

@testable import OsaurusCore

struct RelayAddAgentQueueTests {

    private let address = "0xABCD000000000000000000000000000000000601"

    @Test func addsRunOneAtATimeInOrder() throws {
        var queue = RelayAddAgentQueue()
        let first = UUID()
        let second = UUID()
        queue.enqueue(first)
        queue.enqueue(second)

        let attempt = try #require(queue.start())
        #expect(attempt.agentId == first)
        // The second waits until the relay has answered the first.
        #expect(queue.start() == nil)
        #expect(queue.markSent(attempt.token, address: address))
        #expect(queue.confirm(address: address.lowercased()) == first)
        #expect(queue.start()?.agentId == second)
    }

    @Test func enqueueIgnoresAgentsAlreadyWaiting() {
        var queue = RelayAddAgentQueue()
        let id = UUID()
        queue.enqueue(id)
        queue.enqueue(id)
        #expect(queue.waiting == [id])
    }

    @Test func requeuingTheInFlightAgentRestartsItWithoutCostingAnAttempt() throws {
        var queue = RelayAddAgentQueue()
        let rotated = UUID()
        queue.enqueue(rotated)
        let stale = try #require(queue.start())

        queue.enqueue(rotated)  // address rotated mid-add
        #expect(!queue.isCurrent(stale.token))
        #expect(!queue.markSent(stale.token, address: address))

        // All of its attempts are still left.
        for _ in 1...RelayAddAgentQueue.maxAttempts {
            #expect(queue.start()?.agentId == rotated)
            _ = queue.fail()
        }
        #expect(queue.start() == nil)
    }

    @Test func removedAgentsHandlerCanNoLongerSend() throws {
        var queue = RelayAddAgentQueue()
        let off = UUID()
        let next = UUID()
        queue.enqueue(off)
        queue.enqueue(next)
        let attempt = try #require(queue.start())

        #expect(queue.remove(off))
        #expect(!queue.markSent(attempt.token, address: address))
        #expect(queue.start()?.agentId == next)
        #expect(!queue.remove(UUID()))
    }

    @Test func refusedAddRetriesFirstThenGivesUp() {
        var queue = RelayAddAgentQueue()
        let refused = UUID()
        let next = UUID()
        queue.enqueue(refused)
        queue.enqueue(next)

        for attempt in 1...RelayAddAgentQueue.maxAttempts {
            #expect(queue.start()?.agentId == refused)
            let failure = queue.fail()
            #expect(failure?.id == refused)
            #expect(failure?.willRetry == (attempt < RelayAddAgentQueue.maxAttempts))
        }
        // Given up on: the queue moves on rather than stalling.
        #expect(queue.start()?.agentId == next)
    }

    @Test func aRetryGetsAFreshToken() throws {
        var queue = RelayAddAgentQueue()
        queue.enqueue(UUID())
        let first = try #require(queue.start())
        _ = queue.fail()
        let retry = try #require(queue.start())
        #expect(retry.token != first.token)
        #expect(!queue.isCurrent(first.token))
    }

    @Test func onlyAnAddThatWentOutAwaitsTheRelay() throws {
        var queue = RelayAddAgentQueue()
        queue.enqueue(UUID())
        let attempt = try #require(queue.start())
        // An error frame now would be about something else.
        #expect(!queue.isAwaitingRelay)
        #expect(queue.markSent(attempt.token, address: address))
        #expect(queue.isAwaitingRelay)
    }

    @Test func confirmIgnoresAddressesNoCurrentAddSent() throws {
        var queue = RelayAddAgentQueue()
        let id = UUID()
        queue.enqueue(id)
        let attempt = try #require(queue.start())
        #expect(queue.confirm(address: address) == nil)  // not sent yet
        #expect(queue.markSent(attempt.token, address: address))
        #expect(queue.confirm(address: "0xother") == nil)
        #expect(queue.confirm(address: address.uppercased()) == id)
        #expect(queue.inFlight == nil)
    }

    @Test func failWithNothingInFlightIsIgnored() {
        var queue = RelayAddAgentQueue()
        #expect(queue.fail() == nil)
    }

    @Test func resetDropsEverything() throws {
        var queue = RelayAddAgentQueue()
        queue.enqueue(UUID())
        queue.enqueue(UUID())
        let attempt = try #require(queue.start())
        queue.reset()
        #expect(!queue.isCurrent(attempt.token))
        #expect(queue.waiting.isEmpty)
        #expect(queue.start() == nil)
    }
}
