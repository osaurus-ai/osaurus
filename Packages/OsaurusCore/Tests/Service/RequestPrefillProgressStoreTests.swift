import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct RequestPrefillProgressStoreTests {
    private func event(_ handle: RequestPrefillProgressStore.Handle, _ sequence: UInt64,
                       _ completed: Int, _ total: Int, stage: PrefillProgressStage = .prefill)
        -> RequestPrefillProgressStore.Envelope
    {
        .init(handle: handle, sequence: sequence,
              progress: .init(stage: stage, completedUnitCount: completed,
                              totalUnitCount: total, detail: nil))
    }

    @Test(arguments: [false, true])
    func olderCompletionOrCancellationCannotEraseNewerRequest(runtimeComplete: Bool) {
        let store = RequestPrefillProgressStore()
        let a = store.begin(sessionID: "chat", model: "same-model", totalUnits: 4096)
        #expect(store.receive(event(a, 1, 512, 4096)))
        let b = store.begin(sessionID: "chat", model: "same-model", totalUnits: 8192)
        #expect(store.receive(event(b, 1, 1024, 8192)))
        let expected = store.visibleSnapshot(sessionID: "chat")
        #expect(expected?.handle == b)
        if runtimeComplete { #expect(store.receive(event(a, 2, 4096, 4096, stage: .complete))) }
        else { store.finish(a) }
        #expect(store.visibleSnapshot(sessionID: "chat") == expected)
        #expect(store.snapshot(for: a) == nil)
        #expect(!store.receive(event(a, 3, 2048, 4096)))
        store.finish(a)
        #expect(store.visibleSnapshot(sessionID: "chat") == expected)
    }

    @Test func lateOlderProgressCannotChangeNewerVisibleRequest() {
        let store = RequestPrefillProgressStore()
        let a = store.begin(sessionID: "chat", model: "same-model", totalUnits: 4096)
        let b = store.begin(sessionID: "chat", model: "same-model", totalUnits: 8192)
        #expect(store.receive(event(b, 1, 1024, 8192)))
        let expected = store.visibleSnapshot(sessionID: "chat")
        #expect(store.receive(event(a, 1, 2048, 4096)))
        #expect(store.visibleSnapshot(sessionID: "chat") == expected)
        #expect(store.snapshot(for: a)?.progress.completedUnitCount == 2048)
    }

    @Test func duplicateNativeEnvelopeAndFinishedHandleCannotResurrectProgress() throws {
        let store = RequestPrefillProgressStore()
        let handle = store.begin(sessionID: "chat", model: "model", totalUnits: 4096)
        let direct = event(handle, 1, 512, 4096)
        let encoded = try JSONEncoder().encode(direct)
        let nativeHint = try JSONDecoder().decode(RequestPrefillProgressStore.Envelope.self, from: encoded)
        #expect(store.receive(direct))
        #expect(!store.receive(nativeHint))
        #expect(store.receive(event(handle, 3, 1024, 4096)))
        #expect(!store.receive(event(handle, 2, 768, 4096)))
        #expect(!store.receive(event(handle, 2, 4096, 4096, stage: .complete)))
        #expect(store.snapshot(for: handle)?.progress.completedUnitCount == 1024)
        store.finish(handle)
        #expect(!store.receive(nativeHint))
        #expect(!store.receive(event(handle, UInt64.max, 2048, 4096)))
        #expect(store.entries.isEmpty)
        #expect(store.visibleSnapshot(sessionID: "chat") == nil)
    }

    @Test func totalDiscoveryPreservesSameRequestClockAndCannotRestartFinishedWork() {
        let store = RequestPrefillProgressStore()
        let started = Date(timeIntervalSince1970: 1234)
        let handle = store.begin(sessionID: "chat", model: "model", totalUnits: 0, at: started)
        #expect(store.updateQueuedTotal(4096, for: handle))
        #expect(store.snapshot(for: handle)?.startedAt == started)
        #expect(store.snapshot(for: handle)?.progress.totalUnitCount == 4096)
        #expect(store.receive(event(handle, 1, 512, 4096)))
        #expect(!store.updateQueuedTotal(9000, for: handle))
        store.finish(handle)
        #expect(!store.updateQueuedTotal(4096, for: handle))
        let next = store.begin(sessionID: "chat", model: "model", totalUnits: 4096)
        #expect(next.requestID != handle.requestID)
        #expect(!store.receive(event(handle, 2, 1024, 4096)))
        #expect(store.visibleSnapshot(sessionID: "chat")?.handle == next)
    }

    @Test func sessionSelectionIsReadOnlyAndNeverLeaksAnotherModelOrSuppressedWork() {
        let store = RequestPrefillProgressStore()
        let a = store.begin(sessionID: "A", model: "shared-model", totalUnits: 100)
        let b = store.begin(sessionID: "B", model: "shared-model", totalUnits: 200)
        let c = store.begin(sessionID: "A", model: "other-model", totalUnits: 300)
        let background = store.begin(sessionID: "A", model: "other-model", channel: .suppressed, totalUnits: 400)
        let unscoped = store.begin(sessionID: nil, model: "shared-model", totalUnits: 500)
        #expect(store.visibleSnapshot(sessionID: "A")?.handle == c)
        #expect(store.visibleSnapshot(sessionID: "B")?.handle == b)
        #expect(store.visibleSnapshot(sessionID: nil) == nil)
        #expect(store.visibleSnapshot(sessionID: "missing") == nil)
        #expect(store.entries.count == 5)
        store.finish(c)
        #expect(store.visibleSnapshot(sessionID: "A")?.handle == a)
        store.finish(background)
        store.finish(unscoped)
        #expect(store.visibleSnapshot(sessionID: "B")?.handle == b)
    }

    @Test func foreignStoreHandlesAndInvalidFramesCannotRegisterOrPoisonEntries() {
        let store = RequestPrefillProgressStore()
        let other = RequestPrefillProgressStore()
        let foreign = other.begin(sessionID: "chat", model: "model", totalUnits: 100)
        #expect(!store.receive(event(foreign, 1, 10, 100)))
        store.finish(foreign)
        #expect(store.entries.isEmpty)
        let own = store.begin(sessionID: "chat", model: "model", totalUnits: 100)
        #expect(!store.receive(event(own, 5, 101, 100)))
        #expect(!store.receive(event(own, 5, -1, 100)))
        #expect(!store.receive(event(own, 5, 0, -1)))
        #expect(store.receive(event(own, 1, 10, 100)))
        #expect(store.snapshot(for: own)?.lastSequence == 1)
    }
}
