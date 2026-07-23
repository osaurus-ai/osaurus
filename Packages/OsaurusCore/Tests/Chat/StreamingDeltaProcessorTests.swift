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
}
