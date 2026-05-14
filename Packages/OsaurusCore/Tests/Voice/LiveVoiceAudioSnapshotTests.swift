//
//  LiveVoiceAudioSnapshotTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Live voice audio snapshot")
struct LiveVoiceAudioSnapshotTests {
    @Test("snapshot encodes mono Float PCM as 16-bit WAV")
    func snapshotEncodesWAV() throws {
        let snapshot = LiveVoiceAudioSnapshot(
            samples: [-1.0, 0.0, 1.0],
            sampleRate: 16_000
        )

        let wav = snapshot.wavData()

        #expect(String(data: wav[0 ..< 4], encoding: .ascii) == "RIFF")
        #expect(String(data: wav[8 ..< 12], encoding: .ascii) == "WAVE")
        #expect(String(data: wav[12 ..< 16], encoding: .ascii) == "fmt ")
        #expect(String(data: wav[36 ..< 40], encoding: .ascii) == "data")
        #expect(wav.count == 44 + 6)
    }
}
