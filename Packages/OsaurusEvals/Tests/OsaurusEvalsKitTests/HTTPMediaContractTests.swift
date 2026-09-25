import Foundation
import Testing
@testable import OsaurusEvalsKit

@Suite("Strict real-media qualification")
struct HTTPMediaContractTests {
    @Test(arguments: ["red and blue", "not red", "a red square on blue", "infrared", ""])
    func colorMentionsCannotMasqueradeAsPixelProof(_ answer: String) {
        #expect(!HTTPMediaContract.exactColor(answer, expected: "red"))
    }

    @Test(arguments: ["red", "Red.", " **RED**\n"])
    func exactColorAllowsOnlyPresentationPunctuation(_ answer: String) {
        #expect(HTTPMediaContract.exactColor(answer, expected: "red"))
    }

    @Test func onlyKnownUnsupportedLocalMediaMaySkip() {
        for status in [400, 401, 404, 429, 500, 503] {
            #expect(!HTTPMediaContract.maySkipUnsupported(status: status,
                errorType: "invalid_request_error", installedSupportsMedia: true, required: false))
            #expect(!HTTPMediaContract.maySkipUnsupported(status: status,
                errorType: "invalid_request_error", installedSupportsMedia: false, required: true))
        }
        #expect(!HTTPMediaContract.maySkipUnsupported(status: 500,
            errorType: "invalid_request_error", installedSupportsMedia: false, required: false))
        #expect(!HTTPMediaContract.maySkipUnsupported(status: 400,
            errorType: "invalid_request_error", installedSupportsMedia: nil, required: false))
        #expect(HTTPMediaContract.maySkipUnsupported(status: 400,
            errorType: "invalid_request_error", installedSupportsMedia: false, required: false))
    }

    @Test func requiresVisibleTerminalAnswerAndMeasuredThroughput() {
        let valid: [String: Any] = ["choices": [["finish_reason": "stop",
            "message": ["content": "red"]]], "usage": ["tokens_per_second": 25.0]]
        #expect(HTTPMediaContract.terminalProblems(valid).isEmpty)
        for (content, finish) in [("red", "length"), ("", "stop"), ("<think>red</think>", "stop")] {
            var bad = valid
            bad["choices"] = [["finish_reason": finish, "message": ["content": content]]]
            #expect(!HTTPMediaContract.terminalProblems(bad).isEmpty)
        }
        var missingRate = valid
        missingRate["usage"] = ["completion_tokens": 1]
        #expect(!HTTPMediaContract.terminalProblems(missingRate).isEmpty)
    }

    @Test func explicitVisionQualificationCannotDecodeAsOptionalSupport() throws {
        let expectation = try JSONDecoder().decode(EvalCase.HTTPAPIExpectations.self,
            from: Data(#"{"scenario":"multimodal_image","requireMediaSupport":true}"#.utf8))
        #expect(expectation.requireMediaSupport == true)
    }
}
