//
//  ErrorBodyShapeTests.swift
//  osaurusTests
//
//  Coverage for `HTTPHandler.errorBody(_:message:)` — the helper that
//  unifies error JSON shapes across the three supported wire flavors
//  (OpenAI, Anthropic, OpenResponses). After §1.5 of the audit every
//  4xx/5xx body returned to clients goes through this helper instead
//  of inline string concatenation, so a regression here would propagate
//  to every endpoint at once.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ErrorBodyShapeTests {

    private func decode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test func openaiFlavorMatchesOpenAIErrorEnvelope() throws {
        let body = HTTPHandler.errorBody(
            .openai(type: "invalid_request_error"),
            message: "Bad arguments"
        )
        let dict = try #require(decode(body))
        let error = try #require(dict["error"] as? [String: Any])
        #expect(error["type"] as? String == "invalid_request_error")
        #expect(error["message"] as? String == "Bad arguments")
    }

    @Test func anthropicFlavorMatchesMessagesAPIShape() throws {
        let body = HTTPHandler.errorBody(
            .anthropic(errorType: "invalid_request_error"),
            message: "Bad input"
        )
        let dict = try #require(decode(body))
        #expect(dict["type"] as? String == "error")
        let error = try #require(dict["error"] as? [String: Any])
        #expect(error["type"] as? String == "invalid_request_error")
        #expect(error["message"] as? String == "Bad input")
    }

    @Test func openResponsesFlavorCarriesCode() throws {
        let body = HTTPHandler.errorBody(
            .openResponses(code: "model_not_found"),
            message: "Unknown model"
        )
        let dict = try #require(decode(body))
        let error = try #require(dict["error"] as? [String: Any])
        #expect(error["type"] as? String == "error")
        #expect(error["code"] as? String == "model_not_found")
        #expect(error["message"] as? String == "Unknown model")
    }

    @Test func messagesContainingQuotesAndNewlinesAreEscaped() throws {
        let raw = "User said \"hi\"\nand pressed enter"
        let body = HTTPHandler.errorBody(.openai(type: "internal_error"), message: raw)
        let dict = try #require(decode(body))
        let error = try #require(dict["error"] as? [String: Any])
        // After JSON decode the escaped sequences must round-trip back
        // to the original raw string.
        #expect(error["message"] as? String == raw)
    }
}
