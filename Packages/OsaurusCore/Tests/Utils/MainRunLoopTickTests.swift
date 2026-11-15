//
//  MainRunLoopTickTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct MainRunLoopTickTests {
    /// A waiting AppleScript fires main-run-loop timers on its worker thread;
    /// a tick delivered there must reach the main actor instead of trapping.
    @Test
    func offMainTickRunsOnTheMainActor() async {
        let ranOnMain: Bool = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                onMainRunLoopTick { continuation.resume(returning: Thread.isMainThread) }
            }
        }
        #expect(ranOnMain)
    }

    @Test @MainActor
    func mainThreadTickRunsInline() {
        var ran = false
        onMainRunLoopTick { ran = true }
        #expect(ran)
    }
}
