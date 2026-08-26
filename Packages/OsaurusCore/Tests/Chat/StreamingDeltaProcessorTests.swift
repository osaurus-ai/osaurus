//
//  StreamingDeltaProcessorTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Streaming delta processor")
@MainActor
struct StreamingDeltaProcessorTests {
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
