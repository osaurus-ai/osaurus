import Foundation
import Testing

@testable import OsaurusCore

/// Two silent max-context defects found by the 2026-08-26 sustain trace.
@Suite("Context cap persistence + JANG-tag size parsing")
struct ContextCapPersistenceAndJangTagTests {

    /// `encode(to:)` is synthesized and writes `contextLengthCap`, but the
    /// hand-written `init(from:)` had no decode line — the user's cap was
    /// silently reset to nil on every app relaunch.
    @Test("contextLengthCap survives an encode/decode round trip")
    func capRoundTrip() throws {
        var config = ChatConfiguration.default
        config.contextLengthCap = 24_576
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.contextLengthCap == 24_576)
    }

    @Test("absent cap decodes as nil, older configs unaffected")
    func capAbsentDecodesNil() throws {
        let config = ChatConfiguration.default
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.contextLengthCap == nil)
    }

    /// `JANG_6M` is a quant/build profile, not a parameter count. Parsed as
    /// one, Ling-3.0-tiny-JANG_6M became a "6-million-parameter" model and
    /// got the compact prompt + small SOUL cap meant for tiny models.
    @Test("JANG profile tags are not parameter counts")
    func jangTagsAreNotParameterCounts() {
        #expect(
            ModelMetadataParser.parameterCountBillions(
                from: "JANGQ-AI/Ling-3.0-tiny-JANG_6M") == nil)
        #expect(
            ModelMetadataParser.parameterCountBillions(
                from: "JANGQ-AI/Qwen3.8-27B-JANG_4D") == 27)
        #expect(
            ModelMetadataParser.parameterCountBillions(
                from: "Ling-2.6-flash-JANGTQ2-CRACK") == nil)
    }

    @Test("real M-suffix parameter counts still parse")
    func realMillionCountsStillParse() {
        #expect(
            ModelMetadataParser.parameterCountBillions(from: "google/gemma-3-270m")
                == 0.27)
    }
}
