import Combine
import Foundation
import MLXLMCommon
import XCTest

@testable import OsaurusCore

/// Real event mapper with isolated progress state; no shared HUD mutation.
final class GenerationEventMapperProgressSuppressionTests: XCTestCase {
    @MainActor
    private func exercise(suppressed: Bool) async throws {
        let manager = InferenceProgressManager()
        manager.prefillWillStart(tokenCount: 8192)
        let foreground = PrefillProgressState(stage: .prefill, completedUnitCount: 1024,
                                              totalUnitCount: 8192, detail: "foreground fixture")
        manager.prefillDidUpdate(foreground)
        let cleared = XCTestExpectation(description: "Foreground HUD received clear")
        cleared.isInverted = suppressed
        cleared.assertForOverFulfill = false // first output and stream drain can both clear
        // Ignore initial current value; observe actual publisher activity from
        // the real mapper's asynchronous manager callback.
        let observation = manager.$prefillProgress.dropFirst().sink { progress in
            if progress == nil { cleared.fulfill() }
        }
        defer { observation.cancel() }
        let (events, upstream) = AsyncStream<Generation>.makeStream()
        defer { upstream.finish() }
        upstream.yield(.toolCallProgress("<tool_call>"))
        let mapped = GenerationEventMapper.map(
            events: events, modelName: "prefill-suppression-fixture-" + UUID().uuidString,
            suppressProgressUI: suppressed, progressManager: manager)
        var iterator = mapped.makeAsyncIterator()
        if case .toolCallProgress(let text)? = try await iterator.next() {
            XCTAssertEqual(text, "<tool_call>")
        } else {
            XCTFail("Must exercise the real tool-call-progress branch")
        }
        // Keep upstream open: the positive control must clear at first output,
        // not accidentally pass because the stream-drain cleanup cleared later.
        // A negative async contract requires a bounded observation window. This
        // timer belongs only to the test waiter, never to production progress.
        let result = await XCTWaiter.fulfillment(of: [cleared], timeout: 1.0)
        XCTAssertEqual(result, .completed,
                       suppressed ? "Suppressed tool progress cleared foreground HUD" : "Foreground tool progress failed to clear its HUD")
        upstream.finish()
        while try await iterator.next() != nil {}
        if suppressed {
            XCTAssertEqual(manager.prefillProgress, foreground)
            XCTAssertEqual(manager.prefillTokenCount, 8192)
        } else {
            XCTAssertNil(manager.prefillProgress)
            XCTAssertNil(manager.prefillTokenCount)
        }
    }

    @MainActor
    func testSuppressedToolCallProgressPreservesForegroundHUD() async throws {
        try await exercise(suppressed: true)
    }

    @MainActor
    func testUnsuppressedToolCallProgressClearsForegroundHUD() async throws {
        try await exercise(suppressed: false)
    }
}
