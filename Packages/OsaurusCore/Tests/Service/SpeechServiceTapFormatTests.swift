//
//  SpeechServiceTapFormatTests.swift
//  OsaurusCoreTests
//
//  Regression coverage for APPLE-MACOS-3H4: multi-channel microphone/interface
//  input buffers must downmix cleanly to mono Float32 without requiring a
//  hardcoded 1-channel tap format on AVAudioInputNode.
//

import AVFoundation
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SpeechServiceTapFormatTests {

    @Test("mono Float32 buffer extracts samples unchanged")
    func monoFloat32PassesThrough() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let ch0 = try #require(buffer.floatChannelData?[0])
        ch0[0] = 0.25
        ch0[1] = -0.5
        ch0[2] = 0.75
        ch0[3] = 0.0

        let samples = SpeechService.extractMonoFloatSamples(from: buffer)
        #expect(samples == [0.25, -0.5, 0.75, 0.0])
    }

    @Test("stereo Float32 buffer downmixes both channels to mono")
    func stereoFloat32DownmixesToMono() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let ch0 = try #require(buffer.floatChannelData?[0])
        let ch1 = try #require(buffer.floatChannelData?[1])
        ch0[0] = 0.6; ch1[0] = 0.2
        ch0[1] = -0.4; ch1[1] = 0.4
        ch0[2] = 0.0; ch1[2] = 0.8

        let samples = SpeechService.extractMonoFloatSamples(from: buffer)
        #expect(samples.count == 3)
        #expect(abs(samples[0] - 0.4) < 1e-5)
        #expect(abs(samples[1] - 0.0) < 1e-5)
        #expect(abs(samples[2] - 0.4) < 1e-5)
    }

    @Test("4-channel Float32 interface buffer downmixes cleanly without failing")
    func fourChannelFloat32DownmixesToMono() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let channels = try #require(buffer.floatChannelData)
        channels[0][0] = 0.8; channels[1][0] = 0.0; channels[2][0] = 0.0; channels[3][0] = 0.0
        channels[0][1] = 0.4; channels[1][1] = 0.4; channels[2][1] = 0.4; channels[3][1] = 0.4

        let samples = SpeechService.extractMonoFloatSamples(from: buffer)
        #expect(samples.count == 2)
        #expect(abs(samples[0] - 0.2) < 1e-5)
        #expect(abs(samples[1] - 0.4) < 1e-5)
    }

    @Test("interleaved Int16 buffer converts cleanly to mono Float32")
    func interleavedInt16ConvertsToMonoFloat32() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2, interleaved: true)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let raw = try #require(buffer.int16ChannelData?[0])
        for i in 0 ..< 8 {
            raw[i] = 16_384
        }

        let samples = SpeechService.extractMonoFloatSamples(from: buffer)
        #expect(samples.count == 4)
        for sample in samples {
            #expect(sample.isFinite)
            #expect(abs(sample - 0.5) < 0.05)
        }
    }
}
