//
//  LocalTTSEngine.swift
//  osaurus
//
//  The seam between `TTSService` (playback, published UI state) and an
//  on-device synthesis model. The service owns exactly one engine at a time,
//  chosen from `TTSConfiguration`; everything model-specific — download,
//  disk probe, voice catalog, synthesis — lives behind this protocol.
//

import Foundation

/// Download / compile progress while an engine loads. `nil` is indeterminate.
typealias LocalTTSLoadProgress = @Sendable (Double?) -> Void

/// An on-device text-to-speech model. Output is always 24 kHz mono Float32,
/// the format `TTSAudioPipeline` plays.
protocol LocalTTSEngine: Actor {
    /// Identifies the exact model this engine loads. Two configurations that
    /// resolve to the same id share an engine; a different id means the
    /// resident model must be unloaded and the new one loaded.
    nonisolated var modelId: String { get }

    /// Activity-log identity (`MediaActivityLogger.beginSpeech`).
    nonisolated var activityModel: String { get }
    nonisolated var activityProvider: String { get }

    /// Whether every file `load` needs is already on disk. Cheap file-system
    /// checks only; callable from any thread.
    nonisolated func filesOnDisk() -> Bool

    /// The voice to synthesize with: the per-agent override when this engine
    /// knows it, else the configured voice, else the model's default.
    nonisolated func resolveVoice(override: String?, config: TTSConfiguration) -> String

    /// Download anything missing and load the model.
    func load(progress: @escaping LocalTTSLoadProgress) async throws

    /// Free the loaded model. The next `load` brings it back.
    func unload() async

    /// Synthesize one utterance-sized chunk (see `TTSTextChunker`) as a stream
    /// of sample buffers. Cancelling the consuming task stops synthesis.
    func synthesize(
        chunk: String, voice: String, config: TTSConfiguration
    ) async throws -> AsyncThrowingStream<[Float], Error>
}

enum LocalTTSEngines {
    /// The engine for `config`, or nil when the configured provider is not on-device.
    static func make(for config: TTSConfiguration) -> (any LocalTTSEngine)? {
        switch config.provider {
        case .pocketTTS: return PocketTTSEngine()
        case .openAICompatible: return nil
        }
    }

    /// `modelId` of the engine `make(for:)` would build, without building it.
    static func modelId(for config: TTSConfiguration) -> String? {
        switch config.provider {
        case .pocketTTS: return PocketTTSEngine.id
        case .openAICompatible: return nil
        }
    }

    /// Whether `config`'s on-device model is on disk. False for remote engines.
    static func filesOnDisk(for config: TTSConfiguration) -> Bool {
        make(for: config)?.filesOnDisk() ?? false
    }

    /// Re-emit an upstream stream as plain sample buffers. Ending the consumer
    /// (cancellation, `break`) cancels the upstream iteration.
    static func samples<Element: Sendable>(
        from upstream: AsyncThrowingStream<Element, Error>,
        _ transform: @escaping @Sendable (Element) -> [Float]
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in upstream {
                        try Task.checkCancellation()
                        continuation.yield(transform(element))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
