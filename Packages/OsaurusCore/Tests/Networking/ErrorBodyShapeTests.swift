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
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite
struct ErrorBodyShapeTests {
    @Test func nativeReasoningContractMappingDoesNotMatchErrorText() {
        let typed = K2HorizonTemplateContract.ContractError.unsupportedReasoningMode(expectedEffort: "high")
        let unrelated = NSError(
            domain: "UnrelatedRuntimeFailure", code: 1,
            userInfo: [NSLocalizedDescriptionKey: typed.localizedDescription])
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: typed).code == 400)
        #expect(HTTPHandler.openAIErrorType(for: typed) == "invalid_request_error")
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: unrelated).code == 500)
        #expect(HTTPHandler.openAIErrorType(for: unrelated) == "internal_error")
    }

    @Test func templatePreparationPreservesNativeReasoningRefusalAcrossProtocols() throws {
        let refusal = K2HorizonTemplateContract.ContractError.unsupportedReasoningMode(expectedEffort: "high")
        let error = MLXBatchAdapter.templatePreparationError(refusal)
        #expect(error is K2HorizonTemplateContract.ContractError)
        #expect(error.localizedDescription == refusal.localizedDescription)
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: error).code == 400)
        #expect(HTTPHandler.openAIErrorType(for: error) == "invalid_request_error")
        #expect(HTTPHandler.anthropicErrorType(for: error) == "invalid_request_error")
        #expect(HTTPHandler.openResponsesErrorCode(for: error) == "invalid_request_error")
        #expect(HTTPHandler.ollamaErrorType(for: error) == "invalid_request_error")
        // Both JSON and streaming routes consume this same classification.
        let body = HTTPHandler.errorBody(
            .openai(type: HTTPHandler.openAIErrorType(for: error)), message: error.localizedDescription)
        let object = try #require(decode(body))
        let payload = try #require(object["error"] as? [String: Any])
        #expect(payload["type"] as? String == "invalid_request_error")
        #expect(payload["message"] as? String == refusal.localizedDescription)
    }

    @Test func unrelatedTemplateFailureRetainsInternalErrorDespiteIdenticalMessage() {
        let refusal = K2HorizonTemplateContract.ContractError.unsupportedReasoningMode(expectedEffort: "high")
        let underlying = NSError(
            domain: "UnrelatedTemplateFailure", code: 17,
            userInfo: [NSLocalizedDescriptionKey: refusal.localizedDescription])
        let error = MLXBatchAdapter.templatePreparationError(underlying)
        #expect(!(error is K2HorizonTemplateContract.ContractError))
        #expect((error as NSError).domain == "MLXBatchAdapter")
        #expect((error as NSError).code == 1)
        #expect(error.localizedDescription.hasPrefix("Chat template error: "))
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: error).code == 500)
        #expect(HTTPHandler.openAIErrorType(for: error) == "internal_error")
        #expect(HTTPHandler.anthropicErrorType(for: error) == "api_error")
        #expect(HTTPHandler.openResponsesErrorCode(for: error) == "api_error")
        #expect(HTTPHandler.ollamaErrorType(for: error) == "internal_error")
    }

    @Test func invalidImageMapsToClientErrorAcrossProtocols() {
        let error = ModelRuntime.ImageInputError(imageIndex: 1, reason: "image data is corrupt.")
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: error).code == 400)
        #expect(HTTPHandler.openAIErrorType(for: error) == "invalid_request_error")
        #expect(HTTPHandler.openResponsesErrorCode(for: error) == "invalid_request_error")
        #expect(HTTPHandler.anthropicErrorType(for: error) == "invalid_request_error")
        #expect(HTTPHandler.ollamaErrorType(for: error) == "invalid_request_error")
        #expect(error.localizedDescription.contains("Image 2"))
    }

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

    @Test func loadRefusalMapsToResourceErrorNotInternalError() {
        let error = ModelRuntime.LoadRefusedError(
            modelName: "deepseek-v4-flash-jangtq2",
            message: "Not enough memory to load deepseek-v4-flash-jangtq2"
        )

        #expect(HTTPHandler.localRuntimeHTTPStatus(for: error).code == 503)
        #expect(HTTPHandler.openAIErrorType(for: error) == "insufficient_resources")
        #expect(HTTPHandler.openResponsesErrorCode(for: error) == "insufficient_resources")
        #expect(HTTPHandler.anthropicErrorType(for: error) == "overloaded_error")
        #expect(HTTPHandler.ollamaErrorType(for: error) == "insufficient_resources")
    }

    @Test func runtimePolicyStillMapsToBadRequest() {
        let error = MLXService.RuntimePolicyError(
            modelName: "gemma",
            issues: ["unsupported sampler"]
        )

        #expect(HTTPHandler.localRuntimeHTTPStatus(for: error).code == 400)
        #expect(HTTPHandler.openAIErrorType(for: error) == "invalid_request_error")
        #expect(HTTPHandler.openResponsesErrorCode(for: error) == "invalid_request_error")
        #expect(HTTPHandler.anthropicErrorType(for: error) == "invalid_request_error")
        #expect(HTTPHandler.ollamaErrorType(for: error) == "invalid_request_error")
    }

    @Test func cancellationDoesNotMapToInternalError() {
        let error = CancellationError()

        #expect(HTTPHandler.localRuntimeHTTPStatus(for: error).code == 499)
        #expect(HTTPHandler.openAIErrorType(for: error) == "request_cancelled")
        #expect(HTTPHandler.openResponsesErrorCode(for: error) == "request_cancelled")
        #expect(HTTPHandler.anthropicErrorType(for: error) == "request_cancelled")
        #expect(HTTPHandler.ollamaErrorType(for: error) == "request_cancelled")
    }

    @Test func nativeMTPRefusalMapsToInvalidRequestAcrossProtocols() {
        let error = NativeMTPAdmission.Refusal(reason: "Missing verified tuning")
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: error).code == 400)
        #expect(HTTPHandler.openAIErrorType(for: error) == "invalid_request_error")
        #expect(HTTPHandler.openResponsesErrorCode(for: error) == "invalid_request_error")
        #expect(HTTPHandler.anthropicErrorType(for: error) == "invalid_request_error")
        #expect(HTTPHandler.ollamaErrorType(for: error) == "invalid_request_error")
        #expect(error.localizedDescription.contains("Missing verified tuning"))
    }
}
