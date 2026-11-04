//
//  RelayAddAgentQueueTests.swift
//  OsaurusCoreTests
//
//  Re-pairing the phone turns several agents' relay back on over a live
//  tunnel. The relay holds one challenge per tunnel, so those adds must go
//  one at a time; sent together, all but the last came back invalid_nonce
//  and stayed off the relay (the phone then got agent_offline on cellular).
//

import Foundation
import Testing

@testable import OsaurusCore

struct RelayAddAgentQueueTests {

    @Test func addsRunOneAtATimeInOrder() {
        var queue = RelayAddAgentQueue()
        let first = UUID()
        let second = UUID()
        queue.enqueue(first)
        queue.enqueue(second)

        #expect(queue.start() == first)
        // The second waits until the relay has answered the first.
        #expect(queue.start() == nil)
        queue.finish(first)
        #expect(queue.start() == second)
        queue.finish(second)
        #expect(queue.start() == nil)
        #expect(queue.inFlight == nil)
    }

    @Test func enqueueIgnoresDuplicates() {
        var queue = RelayAddAgentQueue()
        let id = UUID()
        queue.enqueue(id)
        queue.enqueue(id)
        #expect(queue.waiting == [id])
        _ = queue.start()
        queue.enqueue(id)
        #expect(queue.waiting.isEmpty)
    }

    @Test func refusedAddRetriesFirstThenGivesUp() {
        var queue = RelayAddAgentQueue()
        let refused = UUID()
        let next = UUID()
        queue.enqueue(refused)
        queue.enqueue(next)

        for attempt in 1...RelayAddAgentQueue.maxAttempts {
            #expect(queue.start() == refused)
            let failure = queue.fail()
            #expect(failure?.id == refused)
            #expect(failure?.willRetry == (attempt < RelayAddAgentQueue.maxAttempts))
        }
        // Given up on: the queue moves on rather than stalling.
        #expect(queue.start() == next)
    }

    @Test func failWithNothingInFlightIsIgnored() {
        var queue = RelayAddAgentQueue()
        #expect(queue.fail() == nil)
    }

    @Test func removingTheInFlightAgentFreesTheQueue() {
        var queue = RelayAddAgentQueue()
        let off = UUID()
        let next = UUID()
        queue.enqueue(off)
        queue.enqueue(next)
        _ = queue.start()

        #expect(queue.remove(off))
        #expect(queue.start() == next)
        #expect(!queue.remove(UUID()))
    }

    @Test func resetDropsEverything() {
        var queue = RelayAddAgentQueue()
        queue.enqueue(UUID())
        queue.enqueue(UUID())
        _ = queue.start()
        queue.reset()
        #expect(queue.inFlight == nil)
        #expect(queue.waiting.isEmpty)
        #expect(queue.start() == nil)
    }
}
