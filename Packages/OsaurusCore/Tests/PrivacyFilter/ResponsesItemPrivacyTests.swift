import Foundation
import Testing

@testable import OsaurusCore

@Suite("Responses Item privacy continuity")
struct ResponsesItemPrivacyTests {
    private func detection() async -> DetectedEntity {
        let original = "alice@example.com"
        let map = RedactionMap(conversationID: UUID())
        let placeholder = await map.intern(original, as: .email)
        return DetectedEntity(category: .email, original: original,
            range: original.startIndex..<original.endIndex, placeholder: placeholder, approved: true)
    }

    @Test func scansAndScrubsRawOnlyPayloadWithoutDroppingIdentityOrFutureFields() async throws {
        let item: JSONValue = .object([
            "type": .string("future_output"), "id": .string("future_identity"),
            "status": .string("completed"), "phase": .string("commentary"),
            "future": .object(["contact": .string("alice@example.com"), "count": .number(3), "enabled": .bool(true)]),
        ])
        let before = [ChatMessage(role: "assistant", content: nil, tool_calls: nil, tool_call_id: nil,
            responses_output_items: [item])]
        #expect(before.scrubbableTexts() == ["alice@example.com"])
        let after = before.applyingScrub(approved: [await detection()])
        let raw = try #require(after.first?.responses_output_items?.first)
        guard case .object(let fields) = raw, case .object(let payload) = fields["future"] else {
            Issue.record("Raw provider structure disappeared"); return
        }
        #expect(fields["id"] == .string("future_identity"))
        #expect(fields["phase"] == .string("commentary"))
        #expect(payload["contact"] == .string("[EMAIL_1]"))
        #expect(payload["count"] == .number(3) && payload["enabled"] == .bool(true))
        #expect(!after.scrubbableConcat().contains("alice@example.com"))
        let diff = PrivacyFilterPipeline.diffMessages(before: before, after: after)
        #expect(diff.changedCount == 1 && diff.dirtyIndices == [0])
    }

    @Test func escapedArgumentsAndReasoningAreScannedInTheSameViewAsSubstitution() async throws {
        let items: [JSONValue] = [
            .object(["type": .string("reasoning"), "id": .string("rs_original"),
                "encrypted_content": .string("opaque-ciphertext"),
                "summary": .array([.object(["type": .string("summary_text"), "text": .string("contact alice@example.com")])])]),
            .object(["type": .string("function_call"), "id": .string("fc_original"),
                "call_id": .string("call_original"), "name": .string("fixture"),
                "arguments": .string(#"{"recipient":"alice\u0040example.com","count":3,"ok":true}"#)]),
        ]
        let before = [ChatMessage(role: "assistant", content: nil, tool_calls: nil, tool_call_id: nil,
            reasoning_item_id: "rs_original", reasoning_encrypted: "opaque-ciphertext", responses_output_items: items)]
        #expect(before.scrubbableTexts().contains("alice@example.com"))
        #expect(!before.scrubbableTexts().contains("opaque-ciphertext"))
        let after = before.applyingScrub(approved: [await detection()])
        #expect(after.first?.reasoning_item_id == "rs_original")
        #expect(after.first?.reasoning_encrypted == "opaque-ciphertext")
        let raw = try #require(after.first?.responses_output_items)
        guard case .object(let call) = raw[1], case .string(let arguments) = call["arguments"] else {
            Issue.record("Function call disappeared"); return
        }
        let args = try #require(try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
        #expect(args["recipient"] as? String == "[EMAIL_1]")
        #expect(args["count"] as? Int == 3 && args["ok"] as? Bool == true)
        #expect(call["call_id"] == .string("call_original") && call["id"] == .string("fc_original"))
    }

    @Test func scrubbingPreservesRealMediaPartsAndLocalAudioOwnership() async throws {
        let samples = LocalAudioSamples(samples: [0.1, 0.2, -0.3], sampleRate: 16000)
        var before = ChatMessage(
            role: "user", text: "contact alice@example.com", imageData: [Data([1, 2, 3])],
            audios: [(Data([4, 5]), "wav")], localAudioSamples: [samples],
            videos: [(Data([6, 7]), "mp4")]
        )
        let media: JSONValue = .object([
            "type": .string("message"), "role": .string("user"), "id": .string("input_original"),
            "content": .array([
                .object(["type": .string("input_text"), "text": .string("contact alice@example.com")]),
                .object(["type": .string("input_image"), "image_url": .string("data:image/png;base64,AQID")]),
            ]),
        ])
        before.responses_output_items = [media]
        let after = try #require([before].applyingScrub(approved: [await detection()]).first)
        #expect(after.content == "contact [EMAIL_1]")
        #expect(after.imageUrls == before.imageUrls)
        #expect(after.audioInputsWithLocalSamples.count == 1)
        #expect(after.localAudioSamples == before.localAudioSamples)
        #expect(after.videoUrls == before.videoUrls)
        #expect(after.responses_output_items?.count == 1)
        #expect(![after].scrubbableConcat().contains("alice@example.com"))
        #expect(![after].scrubbableConcat().contains("data:image/png;base64,AQID"))
    }

    @Test func inboundCompleteEventsRestorePayloadWithoutRewritingOpaqueIdentity() async throws {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("alice@example.com", as: .email)
        let event: JSONValue = .object([
            "type": .string("response.output_item.done"), "output_index": .number(1),
            "item": .object([
                "type": .string("reasoning"), "id": .string("rs_original"),
                "encrypted_content": .string("opaque-[EMAIL_1]"),
                "summary": .array([.object(["type": .string("summary_text"), "text": .string("Contact [EMAIL_1]")])]),
            ]),
        ])
        let restored = await PrivacyFilterPipeline.unscrubInboundJSON(event, map: map)
        guard case .object(let fields) = restored, case .object(let item) = fields["item"] else {
            Issue.record("Native lifecycle identity disappeared"); return
        }
        #expect(fields["type"] == .string("response.output_item.done"))
        #expect(item["id"] == .string("rs_original"))
        #expect(item["encrypted_content"] == .string("opaque-[EMAIL_1]"))
        #expect(ResponsesItemPayload.scrubbableTexts([restored]).contains("Contact alice@example.com"))
        #expect(await PrivacyFilterPipeline.unscrubInboundJSON(event, map: nil) == event)
    }

}
