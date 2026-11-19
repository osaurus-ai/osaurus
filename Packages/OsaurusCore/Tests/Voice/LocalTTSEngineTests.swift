// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("On-device TTS engines")
struct LocalTTSEngineTests {
    @Test("each provider maps to its engine id; the remote provider has none")
    func engineIdsPerProvider() {
        #expect(LocalTTSEngines.modelId(for: TTSConfiguration(provider: .pocketTTS)) == PocketTTSEngine.id)
        #expect(LocalTTSEngines.modelId(for: TTSConfiguration(provider: .openAICompatible)) == nil)
        #expect(LocalTTSEngines.make(for: TTSConfiguration(provider: .openAICompatible)) == nil)
        #expect(LocalTTSEngines.make(for: TTSConfiguration(provider: .pocketTTS))?.modelId == PocketTTSEngine.id)
    }

    @Test("PocketTTS prefers a known agent override, then the configured voice, then the default")
    func pocketVoiceResolution() {
        let engine = PocketTTSEngine()
        let config = TTSConfiguration(voice: "vera")
        #expect(engine.resolveVoice(override: "  jane ", config: config) == "jane")
        #expect(engine.resolveVoice(override: nil, config: config) == "vera")
        #expect(engine.resolveVoice(override: "", config: config) == "vera")
        #expect(engine.resolveVoice(override: "af_heart", config: config) == TTSConfiguration.defaultVoice)
        #expect(
            engine.resolveVoice(override: nil, config: TTSConfiguration(voice: "renamed"))
                == TTSConfiguration.defaultVoice)
    }

    @Test("the voice catalog default is in the catalog")
    func defaultVoiceIsKnown() {
        #expect(PocketTTSVoiceCatalog.availableVoices.contains(TTSConfiguration.defaultVoice))
        #expect((0.1 ... 1.2).contains(PocketTTSVoiceCatalog.defaultTemperature))
    }

    @Test("sample re-streaming preserves order and propagates errors")
    func sampleStreamMapsAndFails() async throws {
        struct Boom: Error {}
        let upstream = AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.finish(throwing: Boom())
        }
        var received: [[Float]] = []
        await #expect(throws: Boom.self) {
            let mapped = LocalTTSEngines.samples(from: upstream) { value in
                Array(repeating: Float(value), count: value)
            }
            for try await samples in mapped {
                received.append(samples)
            }
        }
        #expect(received == [[1], [2, 2]])
    }

    @Test("ending the consumer cancels the upstream iteration")
    func consumerEndCancelsUpstream() async throws {
        let (upstream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        let terminated = AsyncStream<Void>.makeStream()
        continuation.onTermination = { _ in terminated.continuation.yield() }
        continuation.yield(1)

        for try await _ in LocalTTSEngines.samples(from: upstream, { _ in [0] }) { break }

        var iterator = terminated.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}
