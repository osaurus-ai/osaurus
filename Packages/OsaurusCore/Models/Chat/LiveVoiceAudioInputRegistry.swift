//
//  LiveVoiceAudioInputRegistry.swift
//  osaurus
//

import Foundation
import MLX
import MLXLMCommon

final class LiveVoiceAudioInputRegistry: @unchecked Sendable {
    static let shared = LiveVoiceAudioInputRegistry()

    struct PreencodedAudioMetadata: Sendable, Equatable {
        let sourceSampleCount: Int
        let sampleRate: Int
        let encodeMs: Int
        let encodedAt: Date
    }

    private final class PreencodedAudioEntry: @unchecked Sendable {
        let audio: MLXLMCommon.UserInput.Audio
        let metadata: PreencodedAudioMetadata

        init(audio: MLXLMCommon.UserInput.Audio, metadata: PreencodedAudioMetadata) {
            self.audio = audio
            self.metadata = metadata
        }
    }

    private let lock = NSLock()
    private var samplesByAttachmentId: [UUID: LocalAudioSamples] = [:]
    private var preencodedByAttachmentId: [UUID: PreencodedAudioEntry] = [:]
    private var insertionOrder: [UUID] = []
    private let maxEntries = 16

    private init() {}

    func store(snapshot: LiveVoiceAudioSnapshot, for attachmentId: UUID) {
        store(samples: snapshot.samples, sampleRate: snapshot.sampleRate, for: attachmentId)
    }

    func store(samples: [Float], sampleRate: Int, for attachmentId: UUID) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        lock.withLock {
            if samplesByAttachmentId[attachmentId] == nil {
                insertionOrder.append(attachmentId)
            }
            samplesByAttachmentId[attachmentId] = LocalAudioSamples(
                samples: samples,
                sampleRate: sampleRate,
                preencodedAttachmentId: attachmentId
            )

            while insertionOrder.count > maxEntries, let oldest = insertionOrder.first {
                insertionOrder.removeFirst()
                samplesByAttachmentId.removeValue(forKey: oldest)
                preencodedByAttachmentId.removeValue(forKey: oldest)
            }
        }
    }

    func storePreencoded(
        samples: [Float],
        sampleRate: Int,
        sourceSampleCount: Int? = nil,
        sourceSampleRate: Int? = nil,
        embedding: MLXArray,
        encodeMs: Int,
        for attachmentId: UUID
    ) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        let metadata = PreencodedAudioMetadata(
            sourceSampleCount: sourceSampleCount ?? samples.count,
            sampleRate: sourceSampleRate ?? sampleRate,
            encodeMs: encodeMs,
            encodedAt: Date()
        )
        let entry = PreencodedAudioEntry(
            audio: .preEncoded(samples: samples, sampleRate: sampleRate, embedding: embedding),
            metadata: metadata
        )
        lock.withLock {
            if samplesByAttachmentId[attachmentId] == nil {
                samplesByAttachmentId[attachmentId] = LocalAudioSamples(
                    samples: samples,
                    sampleRate: sampleRate,
                    preencodedAttachmentId: attachmentId
                )
            }
            if !insertionOrder.contains(attachmentId) {
                insertionOrder.append(attachmentId)
            }
            preencodedByAttachmentId[attachmentId] = entry
            while insertionOrder.count > maxEntries, let oldest = insertionOrder.first {
                insertionOrder.removeFirst()
                samplesByAttachmentId.removeValue(forKey: oldest)
                preencodedByAttachmentId.removeValue(forKey: oldest)
            }
        }
    }

    func freshPreencodedAudio(
        for attachmentId: UUID,
        sourceSampleCount: Int,
        sampleRate: Int
    ) -> MLXLMCommon.UserInput.Audio? {
        lock.withLock {
            guard let entry = preencodedByAttachmentId[attachmentId],
                entry.metadata.sourceSampleCount == sourceSampleCount,
                entry.metadata.sampleRate == sampleRate
            else {
                return nil
            }
            return entry.audio
        }
    }

    func preencodedMetadata(for attachmentId: UUID) -> PreencodedAudioMetadata? {
        lock.withLock { preencodedByAttachmentId[attachmentId]?.metadata }
    }

    func remove(for attachmentId: UUID) {
        lock.withLock {
            samplesByAttachmentId.removeValue(forKey: attachmentId)
            preencodedByAttachmentId.removeValue(forKey: attachmentId)
            insertionOrder.removeAll { $0 == attachmentId }
        }
    }

    func samples(for attachmentId: UUID) -> LocalAudioSamples? {
        lock.withLock { samplesByAttachmentId[attachmentId] }
    }

    func removeAll() {
        lock.withLock {
            samplesByAttachmentId.removeAll()
            preencodedByAttachmentId.removeAll()
            insertionOrder.removeAll()
        }
    }
}
