import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct RemotePrefillProgressTests {
    private func chunk(progress: PrefillProgressState? = nil, delta: [String: Any]? = nil,
                       finish: String? = nil) throws -> Data {
        var object: [String: Any] = [
            "id": "progress-test", "object": "chat.completion.chunk", "created": 1,
            "model": "remote-model", "choices": [],
        ]
        if let progress {
            object["osaurus_prefill"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress))
        }
        if delta != nil || finish != nil {
            var choice: [String: Any] = ["index": 0, "delta": delta ?? [:]]
            if let finish { choice["finish_reason"] = finish }
            object["choices"] = [choice]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func parse(_ data: Data, provider: RemoteProviderType = .osaurus,
                       state: inout RemoteProviderService.StreamingState) -> [String] {
        var output: [String] = []
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: data, providerType: provider, state: &state, yield: { output.append($0) })
        return output
    }

    @Test func remoteOwnedProgressGetsFreshLocalStreamIdentity() throws {
        let store = RequestPrefillProgressStore()
        let foreign = store.begin(sessionID: "unrelated-chat", model: "foreign", totalUnits: 512)
        let original = store.snapshot(for: foreign)
        let receiver = PrefillProgressStreamReceiver(sessionID: "current-chat", store: store)
        defer { receiver.finish(); store.finish(foreign) }
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var progress = PrefillProgressState(stage: .prefill, completedUnitCount: 64,
                                            totalUnitCount: 512, detail: "processing")
        progress.requestOwner = foreign
        progress.requestSequence = 4
        let output = parse(try chunk(progress: progress), state: &state)
        #expect(output.count == 1)
        let normalized = try #require(output.first.flatMap(StreamingPrefillProgressHint.decode))
        #expect(normalized.requestOwner == nil)
        #expect(normalized.requestSequence == nil)
        #expect(receiver.receive(normalized))
        let local = try #require(store.visibleSnapshot(sessionID: "current-chat"))
        #expect(local.handle.requestID != foreign.requestID)
        #expect(local.progress.completedUnitCount == 64)
        #expect(store.snapshot(for: foreign) == original)
        receiver.finish()
        #expect(!receiver.receive(normalized))
        #expect(store.visibleSnapshot(sessionID: "current-chat") == nil)
        #expect(store.snapshot(for: foreign) == original)
    }

    @Test func duplicateStaleSwitchedAndMalformedRemoteOwnersAreRejected() throws {
        let store = RequestPrefillProgressStore()
        let a = store.begin(sessionID: "host", model: "same", totalUnits: 512)
        let b = store.begin(sessionID: "host", model: "same", totalUnits: 512)
        defer { store.finish(a); store.finish(b) }
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var progress = PrefillProgressState(stage: .prefill, completedUnitCount: 64, totalUnitCount: 512, detail: nil)
        progress.requestOwner = a
        progress.requestSequence = 3
        #expect(parse(try chunk(progress: progress), state: &state).count == 1)
        #expect(parse(try chunk(progress: progress), state: &state).isEmpty)
        progress.requestSequence = 2
        #expect(parse(try chunk(progress: progress), state: &state).isEmpty)
        progress.requestSequence = 4
        progress.requestOwner = b
        #expect(parse(try chunk(progress: progress), state: &state).isEmpty)
        progress.requestOwner = a
        progress.requestSequence = nil
        #expect(parse(try chunk(progress: progress), state: &state).isEmpty)
        progress.requestSequence = 4
        #expect(parse(try chunk(progress: progress), state: &state).count == 1)
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func actualOutputOrFinishPreventsLatePrefill(_ kind: Int) throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let progress = PrefillProgressState(stage: .prefill, completedUnitCount: 64, totalUnitCount: 512, detail: nil)
        #expect(parse(try chunk(progress: progress), state: &state).count == 1)
        let boundary: Data
        switch kind {
        case 0: boundary = try chunk(delta: ["content": "answer"])
        case 1: boundary = try chunk(delta: ["reasoning_content": "reason"])
        case 2: boundary = try chunk(delta: ["tool_calls": [["index": 0, "id": "call", "type": "function", "function": ["name": "lookup"]]]])
        case 3: boundary = try chunk(delta: ["tool_calls": [["index": 0, "function": ["arguments": "{}"]]]])
        default: boundary = try chunk(finish: "stop")
        }
        _ = parse(boundary, state: &state)
        #expect(parse(try chunk(progress: progress), state: &state).isEmpty)
    }

    @Test func invalidSuppressedAndCompletedFramesCannotStartOrResurrectProgress() throws {
        let store = RequestPrefillProgressStore()
        let suppressed = store.begin(sessionID: "host", model: "same", channel: .suppressed, totalUnits: 512)
        defer { store.finish(suppressed) }
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let invalid = PrefillProgressState(stage: .prefill, completedUnitCount: 513, totalUnitCount: 512, detail: nil)
        #expect(parse(try chunk(progress: invalid), state: &state).isEmpty)
        var hidden = PrefillProgressState(stage: .prefill, completedUnitCount: 64, totalUnitCount: 512, detail: nil)
        hidden.requestOwner = suppressed
        hidden.requestSequence = 1
        #expect(parse(try chunk(progress: hidden), state: &state).isEmpty)
        let valid = PrefillProgressState(stage: .cacheRestore, completedUnitCount: 128, totalUnitCount: 512, detail: "disk")
        #expect(parse(try chunk(progress: valid), state: &state).count == 1)
        let complete = PrefillProgressState(stage: .complete, completedUnitCount: 512, totalUnitCount: 512, detail: nil)
        #expect(parse(try chunk(progress: complete), state: &state).count == 1)
        #expect(parse(try chunk(progress: valid), state: &state).isEmpty)
    }

    @Test func ordinaryProvidersAndVisibleContentKeepExistingBehavior() throws {
        let progress = PrefillProgressState(stage: .prefill, completedUnitCount: 64, totalUnitCount: 512, detail: nil)
        for provider in [RemoteProviderType.openaiLegacy, .azureOpenAI, .osaurusRouter] {
            var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
            #expect(parse(try chunk(progress: progress), provider: provider, state: &state).isEmpty)
            #expect(parse(try chunk(delta: ["content": "answer"]), provider: provider, state: &state) == ["answer"])
        }
        var osaurus = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        #expect(parse(try chunk(delta: ["content": "answer"]), state: &osaurus) == ["answer"])
    }
}
