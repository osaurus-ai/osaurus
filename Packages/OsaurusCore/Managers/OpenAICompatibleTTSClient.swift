//
//  OpenAICompatibleTTSClient.swift
//  osaurus
//
//  Streams speech from any server implementing the OpenAI `/v1/audio/speech`
//  API (openai-edge-tts, Kokoro-FastAPI, LocalAI, OpenAI itself). Requests raw
//  PCM and converts it to the Float32 frames `TTSAudioPipeline` plays.
//

import Foundation

public enum OpenAICompatibleTTSError: LocalizedError {
    case invalidEndpoint(String)
    case serverError(status: Int, message: String)
    case noAudio

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
                    for try await byte in bytes {
                        pending.append(byte)
                        if pending.count >= Self.frameSampleCount * 2 {
                            continuation.yield(Self.consumeFrames(&pending))
                        }
                    }
                    let tail = Self.samples(from: pending, keepingRemainderIn: &pending)
                    if !tail.isEmpty { continuation.yield(tail) }
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
    static func consumeFrames(_ pending: inout Data) -> [Float] {
        let frameBytes = frameSampleCount * 2
        let usable = (pending.count / frameBytes) * frameBytes
        let chunk = pending.prefix(usable)
        pending.removeFirst(usable)
        var scratch = Data()
        return samples(from: Data(chunk), keepingRemainderIn: &scratch)
    }

    /// Decode 16-bit little-endian PCM into normalized floats. Any trailing
    /// odd byte is left in `remainder` for the next chunk.
    static func samples(from data: Data, keepingRemainderIn remainder: inout Data) -> [Float] {
        let usable = data.count - (data.count % 2)
        remainder = data.suffix(from: usable)
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

    /// Servers return either `{"error": {"message": ...}}` (OpenAI shape),
    /// `{"detail": ...}` (FastAPI shape), or plain text.
    static func extractServerMessage(_ body: String) -> String {
        guard let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return body.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let detail = json["detail"] as? String { return detail }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
