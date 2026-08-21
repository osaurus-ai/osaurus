//
//  VoiceChatDuplexService.swift
//  OsaurusCore
//
//  Hosts NemotronLabs VoiceChat 11B — a FULL-DUPLEX speech-to-speech model —
//  inside the app.
//
//  This is not the ASR → text → TTS pipeline the rest of `Services/Voice`
//  implements. VoiceChat listens, answers, speaks, and emits tool calls on ONE
//  12.5 fps frame clock: every 0.08 s frame the backbone consumes the user's
//  audio together with its own previous text and function tokens, and the
//  speech decoder advances on the same clock. There is no intermediate
//  transcript to route, which is what makes barge-in and turn-taking possible
//  at all — and why it gets its own host rather than a mode flag on the
//  transcription path.
//
//  Audio in is 16 kHz mono; audio out is 22.05 kHz mono.
//

import AVFoundation
import Foundation
import MLX
import MLXVLM
import SwiftUI

/// One completed duplex turn, with the measurements that distinguish real
/// speech from a buffer that merely exists.
public struct VoiceChatTurnReport: Sendable, Equatable {
    public let bundleName: String
    public let inputSeconds: Double
    public let frames: Int
    public let sampleCount: Int
    public let sampleRate: Int
    public let loadSeconds: Double
    public let turnSeconds: Double
    public let rms: Float
    public let peak: Float
    public let zeroCrossingRate: Float
    public let transcriptTokenCount: Int
    public let functionTokenCount: Int

    public var durationSeconds: Double {
        sampleRate > 0 ? Double(sampleCount) / Double(sampleRate) : 0
    }

    /// Human-readable one-liner for the UI.
    public var summary: String {
        String(
            format: "%.2fs out · %d frames · rms %.4f · peak %.3f · zcr %.3f · %d asr · %d fn",
            durationSeconds, frames, rms, peak, zeroCrossingRate, transcriptTokenCount,
            functionTokenCount)
    }
}

/// Carries the loaded model across the actor hop to the compute task.
///
/// `@unchecked Sendable` because MLX modules are reference types with no
/// concurrency annotations. The invariant here is ownership, not locking:
/// `VoiceChatDuplexService` is the single owner, every entry point is
/// main-actor, and `isBusy` rejects a second turn while one is running — so
/// exactly one task ever touches the model at a time.
private struct VoiceChatModelBox: @unchecked Sendable {
    let model: NemotronVoiceChatModel
    let config: NemotronVoiceChatConfiguration
}

/// Result of one compute task, likewise carried back across the hop.
private struct VoiceChatComputeResult: @unchecked Sendable {
    let audio: [Float]
    let frames: Int
    let sampleRate: Int
    let transcriptTokenCount: Int
    let functionTokenCount: Int
}

public enum VoiceChatDuplexState: Equatable, Sendable {
    case idle
    case loading(String)
    case running(String)
    case finished(VoiceChatTurnReport)
    case failed(String)
}

/// Loads a VoiceChat bundle, runs duplex turns from an audio source, and plays
/// the generated speech.
@MainActor
public final class VoiceChatDuplexService: ObservableObject {
    public static let shared = VoiceChatDuplexService()

    @Published public private(set) var state: VoiceChatDuplexState = .idle
    @Published public private(set) var lastReport: VoiceChatTurnReport?
    /// Every turn this session, newest last — the variating-run record.
    @Published public private(set) var history: [VoiceChatTurnReport] = []

    private var model: NemotronVoiceChatModel?
    private var config: NemotronVoiceChatConfiguration?
    private var loadedDirectory: URL?
    private var player: AVAudioPlayer?

    private init() {}

    public var isBusy: Bool {
        switch state {
        case .loading, .running: return true
        default: return false
        }
    }

    public var loadedBundleName: String? { loadedDirectory?.lastPathComponent }

    /// Directories under the models root that hold a VoiceChat bundle.
    public static func availableBundles(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var found = [URL]()
        for org in orgs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: org.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }
            if VoiceChatLoader.looksLikeVoiceChatBundle(at: org) {
                found.append(org)
                continue
            }
            let children =
                (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
            for child in children where VoiceChatLoader.looksLikeVoiceChatBundle(at: child) {
                found.append(child)
            }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Unload the current model so another bundle (or another feature) can have
    /// the memory back.
    public func unload() {
        player?.stop()
        player = nil
        model = nil
        config = nil
        loadedDirectory = nil
        state = .idle
        MLX.GPU.clearCache()
    }

    /// Run one duplex turn: audio file in, generated speech out and played.
    ///
    /// The audio file may be any format Core Audio reads; its FIRST channel is
    /// taken as the user's voice (the NVIDIA fixtures are stereo with the user
    /// on the left) and resampled to the model's 16 kHz input rate.
    public func runTurn(
        bundle: URL,
        audioFile: URL,
        seconds: Double = 3.0,
        offsetSeconds: Double = 0,
        playResult: Bool = true
    ) async {
        guard !isBusy else { return }
        let bundleName = bundle.lastPathComponent

        var loadSeconds: Double = 0
        do {
            if loadedDirectory?.standardizedFileURL != bundle.standardizedFileURL {
                state = .loading(bundleName)
                let started = Date()
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let (model, config) = try VoiceChatLoader.load(from: bundle)
                    return VoiceChatModelBox(model: model, config: config)
                }.value
                loadSeconds = Date().timeIntervalSince(started)

                // The speech decoder conditions on CHARACTERS, so it needs the
                // tokenizer's vocabulary before it can generate anything.
                guard let vocabulary = Self.readVocabulary(bundle: bundle) else {
                    throw VoiceChatDuplexError.missingVocabulary(bundleName)
                }
                try loaded.model.setVocabulary(vocabulary)

                model = loaded.model
                config = loaded.config
                loadedDirectory = bundle
            }

            guard let model, let config else {
                throw VoiceChatDuplexError.notLoaded
            }

            state = .running(bundleName)
            let samples = try Self.readMonoSamples(
                from: audioFile, targetRate: config.inputSampleRate,
                seconds: seconds, offsetSeconds: offsetSeconds)
            guard samples.count > 400 else {
                throw VoiceChatDuplexError.emptyInput(audioFile.lastPathComponent)
            }

            let box = VoiceChatModelBox(model: model, config: config)
            let turnStarted = Date()
            let report = try await Task.detached(priority: .userInitiated) {
                let mel = voiceChatLogMelSpectrogram(
                    samples, config: box.config.audioConfig.preprocessor)
                let (projected, encoded) = box.model.sttModel.perception(mel)
                let result = box.model.generateTurn(audioEmbeds: projected, asrEmbeds: encoded)
                return VoiceChatComputeResult(
                    audio: result.audio.asType(.float32).asArray(Float.self),
                    frames: result.audioFrames,
                    sampleRate: result.sampleRate,
                    transcriptTokenCount: box.model.transcribeUser(result).count,
                    functionTokenCount: result.functionTokens.filter {
                        $0 != box.config.padTokenId
                    }.count)
            }.value
            let turnSeconds = Date().timeIntervalSince(turnStarted)

            let stats = Self.measure(report.audio)
            let turnReport = VoiceChatTurnReport(
                bundleName: bundleName,
                inputSeconds: Double(samples.count) / Double(config.inputSampleRate),
                frames: report.frames,
                sampleCount: report.audio.count,
                sampleRate: report.sampleRate,
                loadSeconds: loadSeconds,
                turnSeconds: turnSeconds,
                rms: stats.rms,
                peak: stats.peak,
                zeroCrossingRate: stats.zeroCrossingRate,
                transcriptTokenCount: report.transcriptTokenCount,
                functionTokenCount: report.functionTokenCount)

            if playResult {
                try play(report.audio, sampleRate: report.sampleRate)
            }

            lastReport = turnReport
            history.append(turnReport)
            state = .finished(turnReport)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Audio helpers

    /// Read the first channel of `url`, resampled to `targetRate`.
    static func readMonoSamples(
        from url: URL, targetRate: Int, seconds: Double, offsetSeconds: Double
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw VoiceChatDuplexError.unreadableAudio(url.lastPathComponent) }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw VoiceChatDuplexError.unreadableAudio(url.lastPathComponent)
        }

        let source = Array(
            UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        let sourceRate = format.sampleRate
        let wanted = Int(seconds * Double(targetRate))
        let start = offsetSeconds * sourceRate
        var out = [Float]()
        out.reserveCapacity(wanted)
        for i in 0 ..< wanted {
            let position = start + Double(i) * sourceRate / Double(targetRate)
            let index = Int(position)
            guard index + 1 < source.count else { break }
            let fraction = Float(position - Double(index))
            out.append(source[index] * (1 - fraction) + source[index + 1] * fraction)
        }
        return out
    }

    struct AudioStats {
        let rms: Float
        let peak: Float
        let zeroCrossingRate: Float
    }

    /// "A buffer exists" is not evidence that speech was produced — silence and
    /// noise both produce buffers. These are the numbers that separate them.
    static func measure(_ samples: [Float]) -> AudioStats {
        var sumSquares: Float = 0
        var peak: Float = 0
        var crossings = 0
        for (index, value) in samples.enumerated() {
            sumSquares += value * value
            peak = max(peak, abs(value))
            if index > 0, (samples[index - 1] < 0) != (value < 0) { crossings += 1 }
        }
        let count = Float(max(samples.count, 1))
        return AudioStats(
            rms: (sumSquares / count).squareRoot(),
            peak: peak,
            zeroCrossingRate: Float(crossings) / count)
    }

    private func play(_ samples: [Float], sampleRate: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voicechat-turn.wav")
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                channels: 1, interleaved: false)
        else { throw VoiceChatDuplexError.playbackFailed }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw VoiceChatDuplexError.playbackFailed }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, value) in samples.enumerated() {
            buffer.floatChannelData![0][index] = value
        }
        try file.write(from: buffer)

        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        player.play()
        self.player = player
    }

    /// The tokenizer vocabulary the character-aware speech conditioning needs.
    static func readVocabulary(bundle: URL) -> [String: Int]? {
        let url = bundle.appendingPathComponent("tokenizer.json")
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let modelBlock = json["model"] as? [String: Any],
            let vocabulary = modelBlock["vocab"] as? [String: Int]
        else { return nil }
        return vocabulary
    }
}

public enum VoiceChatDuplexError: LocalizedError {
    case notLoaded
    case missingVocabulary(String)
    case unreadableAudio(String)
    case emptyInput(String)
    case playbackFailed

    public var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "VoiceChat model is not loaded"
        case .missingVocabulary(let name):
            return "\(name) has no readable tokenizer vocabulary for speech conditioning"
        case .unreadableAudio(let name):
            return "Could not read audio from \(name)"
        case .emptyInput(let name):
            return "\(name) produced too few input samples"
        case .playbackFailed:
            return "Could not play the generated speech"
        }
    }
}
