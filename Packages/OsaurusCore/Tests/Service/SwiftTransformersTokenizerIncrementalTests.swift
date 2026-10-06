import Foundation
import XCTest
import VMLXHub
import VMLXTokenizers
import MLXLMCommon
@testable import OsaurusCore

final class SwiftTransformersTokenizerIncrementalTests: XCTestCase {

    private func fixture(cleanup: Bool? = false, decoder: String = "ByteLevel") throws -> PreTrainedTokenizer {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte)
            scalars.append(256 + extra)
            extra += 1
        }
        var vocab: [String: Int] = [:]
        for (byte, scalar) in zip(bytes, scalars) { vocab[String(Unicode.Scalar(scalar)!)] = byte }
        var config: [NSString: Any] = ["tokenizer_class": "GPT2Tokenizer"]
        if let cleanup { config["clean_up_tokenization_spaces"] = cleanup }
        let decoderConfig: [String: Any] = decoder == "Sequence"
            ? ["type": "Sequence", "decoders": [["type": "ByteLevel"]]]
            : ["type": decoder]
        let data: [NSString: Any] = [
            "model": ["type": "BPE", "vocab": vocab, "merges": []] as [String: Any],
            "decoder": decoderConfig,
            "added_tokens": [
                ["id": 256, "content": "<ifm|think>", "special": true] as [String: Any],
                ["id": 257, "content": "<literal-added>", "special": false] as [String: Any],
            ],
        ]
        return try PreTrainedTokenizer(tokenizerConfig: Config(config), tokenizerData: Config(data))
    }


    private func stream(_ ids: [Int], _ tokenizer: any MLXLMCommon.Tokenizer) -> String {
        var d = NaiveStreamingDetokenizer(tokenizer: tokenizer)
        var result = ""
        for id in ids { d.append(token: id); if let part = d.next() { result += part } }
        if let part = d.flush() { result += part }
        XCTAssertTrue((d.flush() ?? "").isEmpty)
        return result
    }

    private func diskFixture(cleanup: Bool? = false, decoder: String = "ByteLevel") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config: [String: Any] = ["tokenizer_class": "GPT2Tokenizer"]
        if let cleanup { config["clean_up_tokenization_spaces"] = cleanup }
        let tok = try fixture(cleanup: cleanup, decoder: decoder)
        var vocab: [String: Int] = [:]
        for id in 0..<256 { vocab[tok.convertIdToToken(id)!] = id }
        let dc: [String: Any] = decoder == "Sequence"
            ? ["type": "Sequence", "decoders": [["type": "ByteLevel"]]] : ["type": decoder]
        let data: [String: Any] = ["model": ["type": "BPE", "vocab": vocab, "merges": []],
             "decoder": dc, "added_tokens": [
                ["id":256,"content":"<ifm|think>","special":true],
                ["id":257,"content":"<literal-added>","special":false]]]
        for (name, object) in [("tokenizer_config.json", config), ("tokenizer.json", data)] {
            try JSONSerialization.data(withJSONObject: object).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    func testPublicLoaderForwardsByteLevelCapabilityAndPreservesExactStream() async throws {
        let dir = try diskFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: dir)
        let upstream = try await AutoTokenizer.from(modelFolder: dir)
        XCTAssertNotNil(upstream.incrementalByteLevelDecoder)
        XCTAssertNotNil(tokenizer.incrementalByteLevelDecoder)
        let ids = Array(String(repeating: "ASCII 🇺🇸 👩🏽‍💻 e\u{301} newline\n", count: 5).utf8).map(Int.init)
            + [256, 0xE2, 0x82, 257, 0xAC, Int.max] + Array(" tool: {\"account\":\"00123\"} end".utf8).map(Int.init)
        let expected = upstream.decode(tokens: ids, skipSpecialTokens: false)
        XCTAssertEqual(stream(ids, tokenizer), expected)
    }

    func testPublicLoaderPreservesStrictDecoderFallback() async throws {
        for (cleanup, decoder) in [(true as Bool?, "ByteLevel"), (nil, "ByteLevel"), (false, "Sequence"), (false, "Fuse")] {
            let dir = try diskFixture(cleanup: cleanup, decoder: decoder)
            defer { try? FileManager.default.removeItem(at: dir) }
            let tokenizer = try await SwiftTransformersTokenizerLoader().load(from: dir)
            XCTAssertNil(tokenizer.incrementalByteLevelDecoder)
            let ids = Array("A stable ASCII fixture with punctuation !".utf8).map(Int.init)
            let upstream = try await AutoTokenizer.from(modelFolder: dir)
            XCTAssertNil(upstream.incrementalByteLevelDecoder)
            XCTAssertEqual(stream(ids, tokenizer), upstream.decode(tokens: ids, skipSpecialTokens: false))
        }
    }

}
