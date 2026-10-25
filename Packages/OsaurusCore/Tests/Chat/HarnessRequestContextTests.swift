import Foundation
import Testing

@testable import OsaurusCore

struct HarnessRequestContextTests {
    @Test(arguments: [false, true])
    func requestCopyPreservesCallerAdmissionBudget(replaceModel: Bool) {
        var original = request()
        original.admissionPositionLimit = 4096
        original.admissionOutputTokensAreImplicit = true

        let copied = copy(original, replaceModel: replaceModel)
        #expect(copied.admissionPositionLimit == 4096)
        #expect(copied.admissionOutputTokensAreImplicit)
        #expect(original.admissionPositionLimit == 4096)
    }

    @Test(arguments: [false, true])
    func requestCopyDoesNotInventAdmissionBudget(replaceModel: Bool) {
        let copied = copy(request(), replaceModel: replaceModel)
        #expect(copied.admissionPositionLimit == nil)
        #expect(!copied.admissionOutputTokensAreImplicit)
    }

    @Test
    func publicWireCannotSetOrReceiveHostAdmissionControls() throws {
        let input = Data(#"{"model":"model","messages":[],"admissionPositionLimit":4096,"admissionOutputTokensAreImplicit":true}"#.utf8)
        var decoded = try JSONDecoder().decode(ChatCompletionRequest.self, from: input)
        #expect(decoded.admissionPositionLimit == nil)
        #expect(!decoded.admissionOutputTokensAreImplicit)
        decoded.admissionPositionLimit = 4096
        decoded.admissionOutputTokensAreImplicit = true
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(wire["admissionPositionLimit"] == nil)
        #expect(wire["admissionOutputTokensAreImplicit"] == nil)
    }

    private func request() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "model",
            messages: [ChatMessage(role: "user", content: "request")],
            temperature: nil,
            max_tokens: nil,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil
        )
    }

    private func copy(_ original: ChatCompletionRequest, replaceModel: Bool) -> ChatCompletionRequest {
        if replaceModel {
            return original.withModel("replacement")
        }
        return original.withContext(
            messages: [ChatMessage(role: "user", content: "replacement")],
            tools: nil,
            toolChoice: nil
        )
    }
}
