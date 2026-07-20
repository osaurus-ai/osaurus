// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("TTS configuration decoding")
struct TTSConfigurationDecodingTests {
    // Config files written before the provider field existed must keep
    // working and land on the on-device engine with remote defaults filled in.
    @Test("legacy config file decodes with pocketTTS provider and remote defaults")
    func legacyConfigDecodes() throws {
        let legacy = #"{"enabled": false, "voice": "vera", "temperature": 0.9}"#
        let config = try JSONDecoder().decode(TTSConfiguration.self, from: Data(legacy.utf8))
        #expect(config.enabled == false)
        #expect(config.voice == "vera")
        #expect(config.temperature == 0.9)
        #expect(config.provider == .pocketTTS)
        #expect(config.remoteEndpoint == TTSConfiguration.defaultRemoteEndpoint)
        #expect(config.remoteModel == TTSConfiguration.defaultRemoteModel)
        #expect(config.remoteVoice == TTSConfiguration.defaultRemoteVoice)
        #expect(config.remoteSpeed == 1.0)
    }

    @Test("empty JSON decodes to defaults")
    func emptyConfigDecodes() throws {
        let config = try JSONDecoder().decode(TTSConfiguration.self, from: Data("{}".utf8))
        #expect(config == TTSConfiguration.default)
    }

    @Test("round-trip preserves remote fields")
    func roundTrip() throws {
        let original = TTSConfiguration(
            enabled: true,
            provider: .openAICompatible,
            voice: "jane",
            temperature: 0.5,
            remoteEndpoint: "http://tts.local:8880",
            remoteModel: "kokoro",
            remoteVoice: "af_sky",
            remoteSpeed: 1.5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TTSConfiguration.self, from: data)
        #expect(decoded == original)
    }

    // A config written by a future version with an engine this build doesn't
    // know would fail the enum decode; the store then falls back to defaults,
    // which is the safe behavior — but make sure a known raw value decodes.
    @Test("provider decodes from raw string")
    func providerRawValue() throws {
        let json = #"{"provider": "openAICompatible"}"#
        let config = try JSONDecoder().decode(TTSConfiguration.self, from: Data(json.utf8))
        #expect(config.provider == .openAICompatible)
    }
}

@Suite("OpenAI-compatible TTS client")
struct OpenAICompatibleTTSClientTests {
    private func client(
        endpoint: String = "http://localhost:5050",
        apiKey: String? = nil
    ) -> OpenAICompatibleTTSClient {
        OpenAICompatibleTTSClient(
            endpoint: endpoint, model: "tts-1", voice: "alloy", speed: 1.0, apiKey: apiKey)
    }

    private func requestURL(for endpoint: String) throws -> String {
        try #require(client(endpoint: endpoint).makeRequest(text: "hi").url?.absoluteString)
    }

    // MARK: - Request building

    @Test("bare host, trailing slash, and full path all normalize to the same URL")
    func endpointNormalization() throws {
        let expected = "http://localhost:5050/v1/audio/speech"
        #expect(try requestURL(for: "http://localhost:5050") == expected)
        #expect(try requestURL(for: "http://localhost:5050/") == expected)
        #expect(try requestURL(for: "http://localhost:5050/v1/audio/speech") == expected)
        #expect(try requestURL(for: "  http://localhost:5050  ") == expected)
    }

    @Test("endpoint without a scheme is rejected")
    func schemelessEndpointThrows() {
        #expect(throws: OpenAICompatibleTTSError.self) {
            _ = try client(endpoint: "localhost:5050").makeRequest(text: "hi")
        }
        #expect(throws: OpenAICompatibleTTSError.self) {
            _ = try client(endpoint: "").makeRequest(text: "hi")
        }
    }

    @Test("payload carries model, input, voice, pcm format, and speed")
    func payloadFields() throws {
        let request = try client().makeRequest(text: "hello world")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "tts-1")
        #expect(json["input"] as? String == "hello world")
        #expect(json["voice"] as? String == "alloy")
        #expect(json["response_format"] as? String == "pcm")
        #expect(json["speed"] as? Double == 1.0)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("authorization header only present when a key is set")
    func authorizationHeader() throws {
        let without = try client().makeRequest(text: "hi")
        #expect(without.value(forHTTPHeaderField: "Authorization") == nil)

        let with = try client(apiKey: "sk-test").makeRequest(text: "hi")
        #expect(with.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

        let empty = try client(apiKey: "").makeRequest(text: "hi")
        #expect(empty.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - PCM decoding

    private func pcmData(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let bits = UInt16(bitPattern: s)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        return data
    }

    @Test("decodes little-endian int16 to normalized floats")
    func pcmDecoding() {
        var remainder = Data()
        let floats = OpenAICompatibleTTSClient.samples(
            from: pcmData([0, 16384, -16384, 32767, -32768]),
            keepingRemainderIn: &remainder
        )
        #expect(remainder.isEmpty)
        #expect(floats.count == 5)
        #expect(floats[0] == 0)
        #expect(floats[1] == 0.5)
        #expect(floats[2] == -0.5)
        #expect(abs(floats[3] - 32767.0 / 32768.0) < 1e-6)
        #expect(floats[4] == -1.0)
    }

    @Test("trailing odd byte is kept as remainder, not decoded")
    func oddByteRemainder() {
        var data = pcmData([1000, -1000])
        data.append(0xAB)
        var remainder = Data()
        let floats = OpenAICompatibleTTSClient.samples(from: data, keepingRemainderIn: &remainder)
        #expect(floats.count == 2)
        #expect(remainder == Data([0xAB]))
    }

    @Test("empty data yields no samples and no remainder")
    func emptyData() {
        var remainder = Data(repeating: 1, count: 3)
        let floats = OpenAICompatibleTTSClient.samples(from: Data(), keepingRemainderIn: &remainder)
        #expect(floats.isEmpty)
        #expect(remainder.isEmpty)
    }

    @Test("consumeFrames drains whole frames and leaves the sub-frame tail")
    func consumeFramesLeavesTail() {
        let frame = 1920  // samples per 80 ms frame at 24 kHz
        var pending = pcmData([Int16](repeating: 100, count: frame * 2 + 7))
        let floats = OpenAICompatibleTTSClient.consumeFrames(&pending)
        #expect(floats.count == frame * 2)
        #expect(pending.count == 7 * 2)
        #expect(floats.allSatisfy { $0 == 100.0 / 32768.0 })
    }

    @Test("consumeFrames on less than one frame consumes nothing")
    func consumeFramesUnderOneFrame() {
        var pending = pcmData([Int16](repeating: 1, count: 100))
        let floats = OpenAICompatibleTTSClient.consumeFrames(&pending)
        #expect(floats.isEmpty)
        #expect(pending.count == 200)
    }

    // Split a known stream at an odd byte offset and check chunked decoding
    // reproduces the same samples a single-shot decode would — the exact
    // situation arbitrary HTTP chunk boundaries create.
    @Test("chunked decode across a mid-sample split matches single-shot decode")
    func midSampleSplit() {
        let source: [Int16] = [12345, -12345, 555, -1, 0, 32000, -32000]
        let data = pcmData(source)
        var scratch = Data()
        let whole = OpenAICompatibleTTSClient.samples(from: data, keepingRemainderIn: &scratch)

        var pending = Data()
        var chunked: [Float] = []
        for byte in data {
            pending.append(byte)
            var remainder = Data()
            let decoded = OpenAICompatibleTTSClient.samples(
                from: pending, keepingRemainderIn: &remainder)
            if !decoded.isEmpty {
                chunked.append(contentsOf: decoded)
                pending = Data(remainder)
            }
        }
        #expect(chunked == whole)
    }

    // MARK: - Server error bodies

    @Test("extracts OpenAI-shaped error message")
    func openAIErrorShape() {
        let body = #"{"error": {"message": "Invalid voice: xyz", "type": "invalid_request_error"}}"#
        #expect(OpenAICompatibleTTSClient.extractServerMessage(body) == "Invalid voice: xyz")
    }

    @Test("extracts string-valued error message (openai-edge-tts shape)")
    func stringErrorShape() {
        let body = #"{"error": "Invalid API key"}"#
        #expect(OpenAICompatibleTTSClient.extractServerMessage(body) == "Invalid API key")
    }

    @Test("extracts FastAPI-shaped detail message")
    func fastAPIErrorShape() {
        let body = #"{"detail": "Not authenticated"}"#
        #expect(OpenAICompatibleTTSClient.extractServerMessage(body) == "Not authenticated")
    }

    @Test("falls back to trimmed plain text for non-JSON bodies")
    func plainTextErrorBody() {
        #expect(OpenAICompatibleTTSClient.extractServerMessage("  Bad Gateway \n") == "Bad Gateway")
        #expect(OpenAICompatibleTTSClient.extractServerMessage("") == "")
    }

    @Test("server error descriptions include status and message")
    func errorDescriptions() {
        let with = OpenAICompatibleTTSError.serverError(status: 401, message: "Not authenticated")
        #expect(with.errorDescription == "TTS server returned HTTP 401: Not authenticated")
        let without = OpenAICompatibleTTSError.serverError(status: 502, message: "")
        #expect(without.errorDescription == "TTS server returned HTTP 502")
    }
}
