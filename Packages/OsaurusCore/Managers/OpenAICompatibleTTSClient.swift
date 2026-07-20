//
//  OpenAICompatibleTTSClient.swift
//  osaurus
//
//  Streams speech from any server implementing the OpenAI `/v1/audio/speech`
//  API (openai-edge-tts, Kokoro-FastAPI, LocalAI, OpenAI itself). Requests raw
//  PCM and converts it to the Float32 frames `TTSAudioPipeline` plays.
//

import Foundation

/// Append-only diagnostic log for remote TTS at `~/.osaurus/tmp/tts.log`.
/// Exists because "static noise" and "silence" bugs are invisible in the UI:
/// the request, the server's declared content type, and the first bytes of
/// the body are what identify a format mismatch, and users can attach the
/// file to a report. Truncated when it grows past 1 MB so it never balloons.
enum TTSDebugLog {
    private static let queue = DispatchQueue(label: "ai.osaurus.tts.debuglog", qos: .utility)
    private static let maxBytes = 1_048_576
    private static var fileURL: URL {
        OsaurusPaths.root()
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("tts.log")
    }

    /// Append a timestamped line. Fire-and-forget off the caller's thread;
    /// logging must never slow down or break audio delivery.
    static func log(_ message: String) {
        let url = fileURL
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            let fm = FileManager.default
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
                size > maxBytes
            {
                try? fm.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Hex dump of the first `count` bytes, for eyeballing magic numbers.
    static func hexPreview(_ data: Data, count: Int = 16) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

public enum OpenAICompatibleTTSError: LocalizedError {
    case invalidEndpoint(String)
    case serverError(status: Int, message: String)
    case noAudio
    case unexpectedFormat(String)

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
            return "Server sent \(format) audio instead of raw PCM. "
                + "It may not support response_format \"pcm\"."
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

    /// What the response body's magic bytes say the audio actually is.
    enum SniffedFormat: Equatable {
        case pcm
        /// WAV container; `headerBytes` to skip before the PCM data starts.
        case wav(headerBytes: Int)
        case compressed(String)
    }

    /// Classify the first bytes of the body. Raw PCM has no magic number, so
    /// anything that isn't a recognized container is assumed to be PCM.
    static func sniffFormat(_ header: Data) -> SniffedFormat {
        let bytes = [UInt8](header.prefix(16))
        guard bytes.count >= 4 else { return .pcm }
        func matches(_ ascii: String) -> Bool { [UInt8](ascii.utf8) == Array(bytes.prefix(ascii.count)) }
        if matches("RIFF") {
            // Canonical 44-byte header; servers that add chunks are rare and
            // will still mostly work (a click, then speech).
            return .wav(headerBytes: 44)
        }
        if matches("ID3") || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) {
            return .compressed("MP3")
        }
        if matches("OggS") { return .compressed("Ogg") }
        if matches("fLaC") { return .compressed("FLAC") }
        return .pcm
    }

    /// Synthesize `text`, yielding Float32 sample frames as bytes arrive.
    func synthesizeStreaming(text: String) throws -> AsyncThrowingStream<[Float], Error> {
        let request = try makeRequest(text: text)
        TTSDebugLog.log(
            "request POST \(request.url?.absoluteString ?? "?") model=\(model) voice=\(voice) "
                + "speed=\(speed) auth=\(apiKey?.isEmpty == false)")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "?"
                    TTSDebugLog.log(
                        "response status=\(http?.statusCode ?? -1) contentType=\(contentType)")
                    if let http, !(200...299).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 500 { break }
                        }
                        TTSDebugLog.log("error body: \(body.prefix(500))")
                        throw OpenAICompatibleTTSError.serverError(
                            status: http.statusCode, message: Self.extractServerMessage(body))
                    }

                    // Carries the trailing odd byte and sub-frame remainder
                    // between chunks; PCM samples are 2 bytes and frames are
                    // fixed-size, but HTTP chunk boundaries are arbitrary.
                    var pending = Data()
                    var totalBytes = 0
                    var totalSamples = 0
                    var peak: Float = 0
                    var headerChecked = false
                    var skipBytes = 0

                    func emit(_ frame: [Float]) {
                        guard !frame.isEmpty else { return }
                        totalSamples += frame.count
                        for s in frame { peak = max(peak, abs(s)) }
                        continuation.yield(frame)
                    }

                    for try await byte in bytes {
                        totalBytes += 1
                        if skipBytes > 0 {
                            skipBytes -= 1
                            continue
                        }
                        pending.append(byte)
                        if !headerChecked, pending.count >= 16 {
                            headerChecked = true
                            switch Self.sniffFormat(pending) {
                            case .pcm:
                                TTSDebugLog.log(
                                    "body sniffed as raw PCM, first bytes: "
                                        + TTSDebugLog.hexPreview(pending))
                            case .wav(let headerBytes):
                                TTSDebugLog.log(
                                    "body is a WAV container, skipping \(headerBytes)-byte header")
                                skipBytes = headerBytes - pending.count
                                pending = Data()
                            case .compressed(let name):
                                TTSDebugLog.log(
                                    "body is \(name), first bytes: "
                                        + TTSDebugLog.hexPreview(pending))
                                throw OpenAICompatibleTTSError.unexpectedFormat(name)
                            }
                        }
                        if headerChecked, pending.count >= Self.frameSampleCount * 2 {
                            emit(Self.consumeFrames(&pending))
                        }
                    }
                    var remainder = Data()
                    emit(Self.samples(from: pending, keepingRemainderIn: &remainder))
                    TTSDebugLog.log(
                        "stream finished: \(totalBytes) bytes, \(totalSamples) samples "
                            + String(
                                format: "(%.2fs at 24kHz), peak amplitude %.3f",
                                Double(totalSamples) / 24_000.0, peak))
                    continuation.finish()
                } catch {
                    TTSDebugLog.log("stream failed: \(error.localizedDescription)")
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
        guard let url = URL(string: full), url.scheme != nil else {
            throw OpenAICompatibleTTSError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "pcm",
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
