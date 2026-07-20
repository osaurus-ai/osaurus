//
//  OpenAICompatibleTTSClient.swift
//  osaurus
//
//  Streams speech from any server implementing the OpenAI `/v1/audio/speech`
//  API (openai-edge-tts, Kokoro-FastAPI, LocalAI, OpenAI itself). Requests
//  WAV, sniffs what the server actually sent (WAV, raw PCM, or compressed),
//  and converts it to the Float32 frames `TTSAudioPipeline` plays.
//

import AVFoundation
import Foundation
import OSLog

public enum OpenAICompatibleTTSError: LocalizedError {
    case invalidEndpoint(String)
    case serverError(status: Int, message: String)
    case noAudio
    case unexpectedFormat(String)
    case unsupportedWav(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let raw):
            return "Invalid TTS endpoint URL: \(raw)"
        case .serverError(let status, let message):
            return message.isEmpty
                ? "TTS server returned HTTP \(status)"
                : "TTS server returned HTTP \(status): \(message)"
        case .noAudio:
            return "Server responded but returned no audio"
        case .unexpectedFormat(let format):
            return "Server sent \(format) audio that could not be decoded."
        case .unsupportedWav(let details):
            return "Server sent WAV audio in an unsupported format (\(details)); "
                + "expected 16-bit mono at 24000 Hz."
        }
    }
}

/// Stateless HTTP client for OpenAI-compatible speech synthesis.
///
/// `response_format: "pcm"` yields headerless 24 kHz mono 16-bit little-endian
/// samples — the OpenAI-documented PCM contract, which the compatible servers
/// follow — matching the 24 kHz mono format the audio pipeline is built on, so
/// no resampling is needed.
struct OpenAICompatibleTTSClient: Sendable {
    let endpoint: String
    let model: String
    let voice: String
    let speed: Double
    let apiKey: String?

    /// Samples per emitted frame. 80 ms at 24 kHz, mirroring PocketTTS frames
    /// so playback starts as soon as the first chunk arrives instead of after
    /// the whole utterance downloads.
    private static let frameSampleCount = 1920

    /// Give up on finding the `data` chunk in a WAV body past this point;
    /// real headers (ffmpeg's canonical or LIST-prefixed) fit in well under 1 KB.
    private static let maxWavHeaderBytes = 8192

    /// Ceiling for buffering a compressed (MP3/FLAC) body before decoding.
    /// 32 MB of MP3 is over an hour of speech; anything bigger is not TTS.
    private static let maxCompressedBytes = 32 * 1024 * 1024

    /// What the response body's magic bytes say the audio actually is.
    enum SniffedFormat: Equatable {
        case pcm
        case wav
        case compressed(String)
    }

    /// Classify the first bytes of the body. Raw PCM has no magic number, so
    /// anything that isn't a recognized container is assumed to be PCM.
    static func sniffFormat(_ header: Data) -> SniffedFormat {
        let bytes = [UInt8](header.prefix(16))
        guard bytes.count >= 4 else { return .pcm }
        func matches(_ ascii: String) -> Bool { [UInt8](ascii.utf8) == Array(bytes.prefix(ascii.count)) }
        if matches("RIFF") { return .wav }
        if matches("ID3") || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) {
            return .compressed("MP3")
        }
        if matches("OggS") { return .compressed("Ogg") }
        if matches("fLaC") { return .compressed("FLAC") }
        return .pcm
    }

    struct WavInfo: Equatable {
        /// Offset of the first audio byte (start of the `data` chunk body).
        let dataOffset: Int
        let sampleRate: Int
        let channels: Int
        let bitsPerSample: Int
    }

    /// Parse a RIFF/WAVE header by walking chunks to `fmt ` and `data`.
    /// Returns nil if `header` doesn't yet contain both (caller should buffer
    /// more bytes and retry). Chunk-walking rather than assuming the canonical
    /// 44-byte layout, because ffmpeg emits a LIST chunk before `data`.
    static func parseWavHeader(_ header: Data) -> WavInfo? {
        let bytes = [UInt8](header)
        guard bytes.count >= 12 else { return nil }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int {
            u16(at) | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func tag(_ at: Int) -> String {
            String(bytes: bytes[at..<at + 4], encoding: .ascii) ?? ""
        }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }

        var offset = 12
        var sampleRate: Int?
        var channels: Int?
        var bits: Int?
        while offset + 8 <= bytes.count {
            let id = tag(offset)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                guard body + 16 <= bytes.count else { return nil }
                channels = u16(body + 2)
                sampleRate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == "data" {
                guard let sampleRate, let channels, let bits else { return nil }
                return WavInfo(
                    dataOffset: body, sampleRate: sampleRate, channels: channels,
                    bitsPerSample: bits)
            }
            // Chunks are word-aligned; odd sizes are padded with one byte.
            offset = body + size + (size % 2)
        }
        return nil
    }

    /// Decode a complete compressed body (MP3, FLAC, AAC — whatever CoreAudio
    /// reads) into 24 kHz mono Float32 samples. Fallback for servers that
    /// can't produce WAV/PCM, like the stock ffmpeg-less openai-edge-tts
    /// image: playback starts only after the whole body has downloaded, but
    /// it plays instead of failing. Throws `unexpectedFormat` when CoreAudio
    /// can't read the data either.
    /// Mutable state for the synchronous `AVAudioConverter` input block. The
    /// block is `@Sendable`, so the non-Sendable buffer and the end-of-file
    /// flag are boxed here; access is confined to one synchronous conversion.
    private final class DecodeState: @unchecked Sendable {
        let file: AVAudioFile
        let inBuffer: AVAudioPCMBuffer
        var reachedEnd = false
        init(file: AVAudioFile, inBuffer: AVAudioPCMBuffer) {
            self.file = file
            self.inBuffer = inBuffer
        }
    }

    static func decodeCompressedAudio(_ data: Data, formatHint: String) throws -> [Float] {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-tts-\(UUID().uuidString).\(formatHint.lowercased())")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: tempURL)
        } catch {
            throw OpenAICompatibleTTSError.unexpectedFormat(formatHint)
        }
        let inFormat = file.processingFormat
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 8192),
            let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192)
        else {
            throw OpenAICompatibleTTSError.unexpectedFormat(formatHint)
        }

        var samples: [Float] = []
        // `AVAudioConverterInputBlock` is `@Sendable`, so it cannot capture the
        // non-Sendable `inBuffer` or a mutable `var` directly. The conversion
        // below is fully synchronous on this thread, so boxing the buffer and
        // the end-of-file flag in a reference type is safe.
        let state = DecodeState(file: file, inBuffer: inBuffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if state.reachedEnd {
                outStatus.pointee = .endOfStream
                return nil
            }
            state.inBuffer.frameLength = 0
            do {
                try state.file.read(into: state.inBuffer)
            } catch {
                state.reachedEnd = true
                outStatus.pointee = .endOfStream
                return nil
            }
            if state.inBuffer.frameLength == 0 {
                state.reachedEnd = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return state.inBuffer
        }

        while true {
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
            if conversionError != nil {
                throw OpenAICompatibleTTSError.unexpectedFormat(formatHint)
            }
            if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || (status == .inputRanDry && state.reachedEnd) { break }
        }
        return samples
    }

    /// Synthesize `text`, yielding Float32 sample frames as bytes arrive.
    func synthesizeStreaming(text: String) throws -> AsyncThrowingStream<[Float], Error> {
        let request = try makeRequest(text: text)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 500 { break }
                        }
                        throw OpenAICompatibleTTSError.serverError(
                            status: http.statusCode, message: Self.extractServerMessage(body))
                    }

                    // Carries the trailing odd byte and sub-frame remainder
                    // between chunks; PCM samples are 2 bytes and frames are
                    // fixed-size, but HTTP chunk boundaries are arbitrary.
                    var pending = Data()
                    var sniffed: SniffedFormat?
                    var awaitingWavHeader = false
                    var compressedFormat: String?

                    func emit(_ frame: [Float]) {
                        guard !frame.isEmpty else { return }
                        continuation.yield(frame)
                    }

                    for try await byte in bytes {
                        pending.append(byte)
                        if sniffed == nil, pending.count >= 16 {
                            sniffed = Self.sniffFormat(pending)
                            switch sniffed! {
                            case .pcm:
                                break
                            case .wav:
                                awaitingWavHeader = true
                            case .compressed(let name):
                                TTSLogger.service.info(
                                    "remote TTS body is \(name, privacy: .public); buffering for CoreAudio decode")
                                compressedFormat = name
                            }
                        }
                        if compressedFormat != nil {
                            if pending.count > Self.maxCompressedBytes {
                                throw OpenAICompatibleTTSError.unexpectedFormat(
                                    "\(compressedFormat!) larger than 32 MB")
                            }
                            continue
                        }
                        if awaitingWavHeader {
                            if let info = Self.parseWavHeader(pending) {
                                awaitingWavHeader = false
                                guard
                                    info.sampleRate == 24_000, info.channels == 1,
                                    info.bitsPerSample == 16
                                else {
                                    throw OpenAICompatibleTTSError.unsupportedWav(
                                        "\(info.sampleRate) Hz, \(info.channels) ch, "
                                            + "\(info.bitsPerSample)-bit")
                                }
                                pending = Data(pending.dropFirst(info.dataOffset))
                            } else if pending.count > Self.maxWavHeaderBytes {
                                throw OpenAICompatibleTTSError.unexpectedFormat(
                                    "an unparseable WAV header")
                            } else {
                                continue
                            }
                        }
                        if sniffed != nil, pending.count >= Self.frameSampleCount * 2 {
                            emit(Self.consumeFrames(&pending))
                        }
                    }
                    if let compressedFormat {
                        let decoded = try Self.decodeCompressedAudio(
                            pending, formatHint: compressedFormat)
                        var offset = 0
                        while offset < decoded.count {
                            let end = min(offset + Self.frameSampleCount, decoded.count)
                            emit(Array(decoded[offset..<end]))
                            offset = end
                        }
                        pending = Data()
                    }
                    var remainder = Data()
                    emit(Self.samples(from: pending, keepingRemainderIn: &remainder))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Synthesize a one-word utterance and succeed on the first audio bytes.
    /// Exercises the same endpoint, credentials, model, and voice as playback,
    /// so a passing test means Preview will work too. The stream is torn down
    /// (cancelling the request) as soon as any samples arrive.
    func verifyConnection() async throws {
        let stream = try synthesizeStreaming(text: "Hi")
        for try await samples in stream where !samples.isEmpty {
            return
        }
        throw OpenAICompatibleTTSError.noAudio
    }

    func makeRequest(text: String) throws -> URLRequest {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        // Accept either a bare host or a URL that already includes the path.
        let full = base.hasSuffix("/v1/audio/speech") ? base : base + "/v1/audio/speech"
        // Newer Foundation URL parsing accepts "localhost:5050" with scheme
        // "localhost", so a nil-scheme check alone no longer catches
        // schemeless endpoints. Require an http(s) scheme and a host.
        guard let url = URL(string: full),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else {
            throw OpenAICompatibleTTSError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // "wav" rather than "pcm": both are 24 kHz mono s16le from compliant
        // servers, but openai-edge-tts's pcm conversion is broken (it feeds
        // AAC into a PCM muxer) while its wav path works. The WAV header is
        // parsed and stripped on receipt, so the difference costs ~44 bytes.
        let payload: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "wav",
            "speed": speed,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// Drain all complete frames from `pending`, leaving the remainder.
    ///
    /// Index safety: `Data.SubSequence == Data`, so slicing operations
    /// (`removeFirst`, `dropFirst`, subscripts) yield Data whose `startIndex`
    /// is NOT 0. Everything here therefore works with counts and rebuilds
    /// fresh `Data` for anything kept across calls — index-based access on a
    /// carried-over slice is how this crashed at end-of-stream in the field.
    static func consumeFrames(_ pending: inout Data) -> [Float] {
        let frameBytes = frameSampleCount * 2
        let usable = (pending.count / frameBytes) * frameBytes
        guard usable > 0 else { return [] }
        let chunk = Data(pending.prefix(usable))
        pending = Data(pending.dropFirst(usable))
        var scratch = Data()
        return samples(from: chunk, keepingRemainderIn: &scratch)
    }

    /// Decode 16-bit little-endian PCM into normalized floats. Any trailing
    /// odd byte is left in `remainder` for the next chunk.
    static func samples(from data: Data, keepingRemainderIn remainder: inout Data) -> [Float] {
        let usable = data.count - (data.count % 2)
        remainder = Data(data.suffix(data.count - usable))
        guard usable > 0 else { return [] }
        var out = [Float](repeating: 0, count: usable / 2)
        data.prefix(usable).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<(usable / 2) {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let sample = Int16(bitPattern: hi << 8 | lo)
                out[i] = Float(sample) / 32768.0
            }
        }
        return out
    }

    /// Servers return `{"error": {"message": ...}}` (OpenAI shape),
    /// `{"error": "..."}` (openai-edge-tts shape), `{"detail": ...}`
    /// (FastAPI shape), or plain text.
    static func extractServerMessage(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return body.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let error = json["error"] as? String { return error }
        if let detail = json["detail"] as? String { return detail }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
