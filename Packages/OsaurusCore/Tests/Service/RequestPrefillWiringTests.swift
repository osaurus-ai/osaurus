import AppKit
import Combine
import XCTest
import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@MainActor
struct RequestPrefillWiringTests {
    @Test(arguments: [0, 1, 2, 3])
    func actualMapperFirstOutputFinishesOnlyItsOwnerAndNativeHintCannotResurrect(_ kind: Int) async throws {
        let store = RequestPrefillProgressStore()
        let legacy = InferenceProgressManager()
        let a = store.begin(sessionID: "chat", model: "same-model", totalUnits: 4096)
        let b = store.begin(sessionID: "chat", model: "same-model", totalUnits: 8192)
        let expectedB = store.snapshot(for: b)
        let receiver = PrefillProgressStreamReceiver(sessionID: "chat", store: store)
        let (source, upstream) = AsyncStream<Generation>.makeStream()
        defer { upstream.finish(); receiver.finish() }
        let mapped = GenerationEventMapper.map(
            events: source, progressManager: legacy, progressOwner: a, requestProgressStore: store)
        var iterator = mapped.makeAsyncIterator()
        upstream.yield(.prefillProgress(.init(stage: .prefill, completedUnitCount: 512, totalUnitCount: 4096)))
        guard case .prefillProgress(let state)? = try await iterator.next() else {
            Issue.record("Missing owned progress event"); return
        }
        #expect(state.requestOwner == a)
        #expect(state.requestSequence == 1)
        let hint = try #require(StreamingPrefillProgressHint.decode(StreamingPrefillProgressHint.encode(state)))
        #expect(!receiver.receive(hint), "Direct/native delivery must share the same sequence")
        #expect(store.snapshot(for: a)?.progress.completedUnitCount == 512)
        let output: Generation
        switch kind {
        case 0: output = .chunk("answer")
        case 1: output = .reasoning("reasoning")
        case 2: output = .toolCallProgress("<tool_call>")
        default: output = .toolCall(.init(function: .init(name: "read", arguments: [:])))
        }
        upstream.yield(output)
        _ = try await iterator.next()
        #expect(store.snapshot(for: a) == nil)
        #expect(store.snapshot(for: b) == expectedB)
        #expect(!receiver.receive(hint))
        #expect(store.visibleSnapshot(sessionID: "chat")?.handle == b)
        #expect(legacy.prefillProgress == nil)
        upstream.finish()
        while try await iterator.next() != nil {}
    }

    @Test func mapperConsumerCancellationFinishesOnlyItsOwner() async {
        let store = RequestPrefillProgressStore()
        let a = store.begin(sessionID: "A", model: "same-model", totalUnits: 4096)
        let b = store.begin(sessionID: "B", model: "same-model", totalUnits: 8192)
        let expectedB = store.snapshot(for: b)
        let ready = XCTestExpectation(description: "A progress consumed")
        let closed = XCTestExpectation(description: "A ownership closed on cancellation")
        closed.assertForOverFulfill = false
        let observer = store.$entries.dropFirst().sink { entries in
            if entries[a.requestID] == nil { closed.fulfill() }
        }
        defer { observer.cancel() }
        let (source, upstream) = AsyncStream<Generation>.makeStream()
        let mapped = GenerationEventMapper.map(
            events: source, progressManager: InferenceProgressManager(),
            progressOwner: a, requestProgressStore: store)
        let consumer = Task {
            do {
                for try await event in mapped {
                    if case .prefillProgress = event { ready.fulfill() }
                }
            } catch {}
        }
        defer { consumer.cancel(); upstream.finish() }
        upstream.yield(.prefillProgress(.init(stage: .prefill, completedUnitCount: 512, totalUnitCount: 4096)))
        #expect(await XCTWaiter.fulfillment(of: [ready], timeout: 1) == .completed)
        consumer.cancel()
        #expect(await XCTWaiter.fulfillment(of: [closed], timeout: 1) == .completed)
        await consumer.value
        #expect(store.snapshot(for: a) == nil)
        #expect(store.snapshot(for: b) == expectedB)
    }

    @Test func legacyRemoteProgressClosesAtFirstToolOutputAndRejectsLateFrames() {
        let store = RequestPrefillProgressStore()
        let receiver = PrefillProgressStreamReceiver(sessionID: "remote-chat", store: store)
        let state = PrefillProgressState(stage: .prefill, completedUnitCount: 64, totalUnitCount: 512, detail: nil)
        let invalid = PrefillProgressState(stage: .prefill, completedUnitCount: 513,
                                           totalUnitCount: 512, detail: nil)
        #expect(!receiver.receive(invalid))
        #expect(store.entries.isEmpty)
        #expect(receiver.receive(state))
        let owner = store.visibleSnapshot(sessionID: "remote-chat")?.handle
        #expect(owner != nil)
        // ChatView calls this on tool name/envelope/args, reasoning, text and every exit.
        receiver.finish()
        #expect(!receiver.receive(state))
        #expect(store.visibleSnapshot(sessionID: "remote-chat") == nil)
        let newer = store.begin(sessionID: "remote-chat", model: "remote", totalUnits: 1024)
        receiver.finish()
        #expect(store.visibleSnapshot(sessionID: "remote-chat")?.handle == newer)
    }

    @Test func nativeTypingViewSelectsExactSessionEvenOnSameThemeReconfigure() async {
        let store = RequestPrefillProgressStore()
        let a = store.begin(sessionID: "A", model: "same-model", totalUnits: 100)
        let b = store.begin(sessionID: "B", model: "same-model", totalUnits: 200)
        #expect(store.receive(.init(handle: a, sequence: 1,
                                   progress: .init(stage: .prefill, completedUnitCount: 25, totalUnitCount: 100, detail: nil))))
        #expect(store.receive(.init(handle: b, sequence: 1,
                                   progress: .init(stage: .prefill, completedUnitCount: 75, totalUnitCount: 200, detail: nil))))
        let warmup = WarmupProgressHub()
        let warmed = XCTestExpectation(description: "Unrelated suppressed warmup present")
        let observation = warmup.$phases.sink { phases in
            if phases["other-model"] != nil { warmed.fulfill() }
        }
        defer { observation.cancel() }
        warmup.prefillWillStart(model: "other-model", tokenCount: 9999)
        #expect(await XCTWaiter.fulfillment(of: [warmed], timeout: 1) == .completed)
        let view = NativeTypingIndicatorView(progressStore: store, warmupHub: warmup)
        let theme = LightTheme()
        view.configure(theme: theme, sessionID: "A")
        #expect(view.prefillDisplayText == "25/100")
        view.configure(theme: theme, sessionID: "B")
        #expect(view.prefillDisplayText == "75/200")
        view.configure(theme: theme, sessionID: "missing")
        #expect(view.prefillDisplayText == nil)
        view.configure(theme: theme, sessionID: "A")
        #expect(view.prefillDisplayText == "25/100")
        #expect(store.entries.count == 2, "View selection must not mutate request lifetimes")
    }
}
