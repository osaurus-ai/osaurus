//
//  LiveVoiceAudioInputRegistry.swift
//  osaurus
//

import Foundation

final class LiveVoiceAudioInputRegistry: @unchecked Sendable {
    static let shared = LiveVoiceAudioInputRegistry()

    private let lock = NSLock()
    private var samplesByAttachmentId: [UUID: LocalAudioSamples] = [:]
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
                sampleRate: sampleRate
            )

            while insertionOrder.count > maxEntries, let oldest = insertionOrder.first {
                insertionOrder.removeFirst()
                samplesByAttachmentId.removeValue(forKey: oldest)
            }
        }
    }

    func samples(for attachmentId: UUID) -> LocalAudioSamples? {
        lock.withLock { samplesByAttachmentId[attachmentId] }
    }

    func removeAll() {
        lock.withLock {
            samplesByAttachmentId.removeAll()
            insertionOrder.removeAll()
        }
    }
}
