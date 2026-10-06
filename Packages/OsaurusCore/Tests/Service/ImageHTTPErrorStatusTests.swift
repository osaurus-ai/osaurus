import Testing
@testable import OsaurusCore

@Suite
struct ImageHTTPErrorStatusTests {
    @Test func actualQwenEditStrengthPolicyErrorIsBadRequest() throws {
        let message: String
        do {
            try ImageModelRequestPolicy(canonical: "qwen-image-2.1").validate(
                width: nil, height: nil, isEdit: true, guidance: 1,
                negativePrompt: nil, strength: 0.75, sourceCount: 1)
            Issue.record("Unsupported explicit edit strength must throw before mapping")
            return
        } catch let error as ImageGenerationError {
            // Actual bridge description, including the nested capability wording.
            message = error.description
        }
        #expect(message.hasPrefix("invalid request:"))
        #expect(message.contains("not implemented"))
        #expect(HTTPHandler.imageErrorStatus(message: message, hfAuth: false).code == 400)
    }

    @Test(arguments: ["not implemented", "not found", "incomplete"])
    func explicitRequestClassificationWinsOverDetail(_ detail: String) {
        let message = ImageGenerationError.invalidRequest(detail).description
        #expect(HTTPHandler.imageErrorStatus(message: message, hfAuth: false).code == 400)
    }

    @Test func independentStatusesAndAuthPrecedenceRemainUnchanged() {
        #expect(HTTPHandler.imageErrorStatus(message: "operation not implemented", hfAuth: false).code == 501)
        #expect(HTTPHandler.imageErrorStatus(message: ImageGenerationError.modelNotFound("missing").description,
            hfAuth: false).code == 404)
        #expect(HTTPHandler.imageErrorStatus(message: ImageGenerationError.modelIncomplete(
            model: "partial", reasons: ["weights"]).description, hfAuth: false).code == 409)
        #expect(HTTPHandler.imageErrorStatus(message: ImageGenerationError.wrongModelKind(
            expected: "imageEdit", actual: "imageGen").description, hfAuth: false).code == 400)
        #expect(HTTPHandler.imageErrorStatus(message: "unknown engine error", hfAuth: false).code == 500)
        #expect(HTTPHandler.imageErrorStatus(message: ImageGenerationError.invalidRequest(
            "not implemented").description, hfAuth: true).code == 402)
    }
}
