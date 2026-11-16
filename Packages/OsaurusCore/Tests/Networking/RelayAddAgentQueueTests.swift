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

// The queue is a value type and #expect/#require capture their argument
// immutably, so every mutating call runs on its own line before the check.
struct RelayAddAgentQueueTests {

    private let address = "0xABCD000000000000000000000000000000000601"

    @Test func addsRunOneAtATimeInOrder() throws {
        var queue = RelayAddAgentQueue()
        let first = UUID()
        let second = UUID()
        queue.enqueue(first)
        queue.enqueue(second)

        let started = queue.start()
        let attempt = try #require(started)
        #expect(attempt.agentId == first)
        // The second waits until the relay has answered the first.
        let blocked = queue.start()
        #expect(blocked == nil)
        let sent = queue.markSent(attempt.token, address: address)
        #expect(sent)
        let confirmed = queue.confirm(address: address.lowercased())
        #expect(confirmed == first)
        let next = queue.start()
        #expect(next?.agentId == second)
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
        let started = queue.start()
        let stale = try #require(started)

        queue.enqueue(rotated)  // address rotated mid-add
        #expect(!queue.isCurrent(stale.token))
        let sent = queue.markSent(stale.token, address: address)
        #expect(!sent)

        // All of its attempts are still left.
        for _ in 1...RelayAddAgentQueue.maxAttempts {
            let retry = queue.start()
            #expect(retry?.agentId == rotated)
            _ = queue.fail()
        }
        let after = queue.start()
        #expect(after == nil)
    }

    @Test func removedAgentsHandlerCanNoLongerSend() throws {
        var queue = RelayAddAgentQueue()
        let off = UUID()
        let next = UUID()
        queue.enqueue(off)
        queue.enqueue(next)
        let started = queue.start()
        let attempt = try #require(started)

        let removed = queue.remove(off)
        #expect(removed)
        let sent = queue.markSent(attempt.token, address: address)
        #expect(!sent)
        let following = queue.start()
        #expect(following?.agentId == next)
        let removedUnknown = queue.remove(UUID())
        #expect(!removedUnknown)
    }

    @Test func refusedAddRetriesFirstThenGivesUp() {
        var queue = RelayAddAgentQueue()
        let refused = UUID()
        let next = UUID()
        queue.enqueue(refused)
        queue.enqueue(next)

        for attempt in 1...RelayAddAgentQueue.maxAttempts {
            let started = queue.start()
            #expect(started?.agentId == refused)
            let failure = queue.fail()
            #expect(failure?.id == refused)
            #expect(failure?.willRetry == (attempt < RelayAddAgentQueue.maxAttempts))
        }
        // Given up on: the queue moves on rather than stalling.
        let following = queue.start()
        #expect(following?.agentId == next)
    }

    @Test func aRetryGetsAFreshToken() throws {
        var queue = RelayAddAgentQueue()
        queue.enqueue(UUID())
        let firstStarted = queue.start()
        let first = try #require(firstStarted)
        _ = queue.fail()
        let retryStarted = queue.start()
        let retry = try #require(retryStarted)
        #expect(retry.token != first.token)
        #expect(!queue.isCurrent(first.token))
    }

    @Test func onlyAnAddThatWentOutAwaitsTheRelay() throws {
        var queue = RelayAddAgentQueue()
        queue.enqueue(UUID())
        let started = queue.start()
        let attempt = try #require(started)
        // An error frame now would be about something else.
        #expect(!queue.isAwaitingRelay)
        let sent = queue.markSent(attempt.token, address: address)
        #expect(sent)
        #expect(queue.isAwaitingRelay)
    }

    @Test func confirmIgnoresAddressesNoCurrentAddSent() throws {
        var queue = RelayAddAgentQueue()
        let id = UUID()
        queue.enqueue(id)
        let started = queue.start()
        let attempt = try #require(started)
        let early = queue.confirm(address: address)
        #expect(early == nil)  // not sent yet
        let sent = queue.markSent(attempt.token, address: address)
        #expect(sent)
        let other = queue.confirm(address: "0xother")
        #expect(other == nil)
        let confirmed = queue.confirm(address: address.uppercased())
        #expect(confirmed == id)
        #expect(queue.inFlight == nil)
    }

    @Test func failWithNothingInFlightIsIgnored() {
        var queue = RelayAddAgentQueue()
        let failure = queue.fail()
        #expect(failure == nil)
    }

    @Test func resetDropsEverything() throws {
        var queue = RelayAddAgentQueue()
        queue.enqueue(UUID())
        queue.enqueue(UUID())
        let started = queue.start()
        let attempt = try #require(started)
        queue.reset()
        #expect(!queue.isCurrent(attempt.token))
        #expect(queue.waiting.isEmpty)
        let after = queue.start()
        #expect(after == nil)
    }
}
