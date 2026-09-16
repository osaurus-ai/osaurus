//
//  StreamingDeltaProcessorTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Streaming delta processor", .serialized)
@MainActor
struct StreamingDeltaProcessorTests {
    @Test("concurrent completion paths both finish after the same paced tail")
    func concurrentFinalizersDoNotLoseAWaiter() async {
        let key = "chatSmoothStreamingEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let text = String(repeating: "The photo shows a city. ", count: 20)
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = StreamingDeltaProcessor(turn: turn)
        processor.receiveDelta(text)
        var started = 0
        var completed = 0
        let first = Task { @MainActor in
            started += 1
            await processor.finalize()
            completed += 1
        }
        let second = Task { @MainActor in
            started += 1
            await processor.finalize()
            completed += 1
        }
        // Tasks enter finalize on the main actor and suspend on its tail.
        // Fire the actual production timer so this also works in a test
        // runner whose main run loop does not pump scheduled timers.
        let deadline = Date().addingTimeInterval(3)
        while started < 2, Date() < deadline { await Task.yield() }
        #expect(started == 2)
        while completed < 2, Date() < deadline {
            processor.pacingTimer?.fire()
            await Task.yield()
        }
        #expect(completed == 2, "relay and consumer must both resume")
        #expect(turn.content == text)
        #expect(processor.pacingTimer == nil)
        first.cancel()
        second.cancel()
    }

    @Test("reset releases a finalizer waiting on the previous turn")
    func resetReleasesPreviousTurnFinalizer() async {
        let key = "chatSmoothStreamingEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let oldTurn = ChatTurn(role: .assistant, content: "")
        let processor = StreamingDeltaProcessor(turn: oldTurn)
        processor.receiveDelta(String(repeating: "tail ", count: 200))
        var started = false
        var completed = false
        let finalizer = Task { @MainActor in
            started = true
            await processor.finalize()
            completed = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !started, Date() < deadline { await Task.yield() }
        #expect(started)
        let nextTurn = ChatTurn(role: .assistant, content: "")
        processor.reset(turn: nextTurn)
        while !completed, Date() < deadline { await Task.yield() }
        #expect(completed)
        #expect(nextTurn.contentIsEmpty)
        #expect(processor.pacingTimer == nil)
        finalizer.cancel()
    }

    @Test("smooth finalize drains a small final tail without waiting for another timer tick")
    func smoothFinalizeDrainsSmallTail() async {
        let key = "chatSmoothStreamingEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let turn = ChatTurn(role: .assistant, content: "")
        var syncCount = 0
        let processor = StreamingDeltaProcessor(turn: turn) {
            syncCount += 1
        }

        processor.receiveDelta("Finished.")
        await processor.finalize()

        #expect(turn.content == "Finished.")
        #expect(syncCount >= 1)
    }

    @Test("deallocating mid-stream invalidates the live pacing timer")
    func deallocMidStreamInvalidatesPacingTimer() async {
        let key = "chatSmoothStreamingEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let turn = ChatTurn(role: .assistant, content: "")
        var processor: StreamingDeltaProcessor? = StreamingDeltaProcessor(turn: turn)
        weak var weakProcessor = processor

        // A pending buffer starts the 16ms repeating pacing timer.
        processor?.receiveDelta(String(repeating: "x", count: 500))
        let timer = processor?.pacingTimer
        #expect(timer?.isValid == true)

        // Simulate the chat window/session going away mid-stream: the
        // processor deallocates while the pacing timer is still scheduled
        // and its buffer is non-empty. The run loop keeps the Timer object
        // alive, so without a deinit invalidation it would tick forever,
        // spawning a no-op task every 16ms for the rest of the process.
        processor = nil
        await Task.yield()

        #expect(weakProcessor == nil)
        #expect(timer?.isValid == false)
    }
}
