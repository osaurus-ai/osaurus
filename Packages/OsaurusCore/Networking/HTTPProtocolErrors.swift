//
//  HTTPProtocolErrors.swift
//  osaurus
//
//  Per-protocol JSON error envelopes. Today's `HTTPHandler` builds these
//  inline at every route's catch block — there are at least three distinct
//  shapes (OpenAI, Anthropic, OpenResponses) plus a plain-text fallback.
//  This helper makes "fail this request with a protocol-correct error"
//  one call instead of 6-12 lines of literal JSON construction.
//

import Foundation
import NIOHTTP1

extension HTTPHandler {

    static let emptyToolTaskCompletionMessage = AgentToolLoop.emptyToolTaskFallback

    private static let emptyToolTaskCompletionDomain = "OsaurusEmptyToolTaskCompletion"

    /// Wire flavor for the JSON error body. Each flavor uses the envelope
    /// shape its protocol's clients expect.
    enum HTTPErrorFlavor {
        /// `{"error":{"message":"...","type":"<type>"}}` — used by
        /// `/chat/completions` and `/embeddings`.
        case openai(type: String)
        /// `{"type":"error","error":{"type":"<errorType>","message":"..."}}` —
        /// the Anthropic Messages API shape.
        case anthropic(errorType: String)
        /// `{"error":{"type":"error","code":"<code>","message":"..."}}` —
        /// the OpenAI Responses API shape.
        case openResponses(code: String)
    }

    /// Build the JSON body string for `flavor`. Pure: returns the body
    /// only — caller still needs to write it to the wire (typically via
    /// `sendResponse` or `writeJSONResponse`).
    static func errorBody(_ flavor: HTTPErrorFlavor, message: String) -> String {
        let escaped = escapeJSONString(message)
        switch flavor {
        case .openai(let type):
            return #"{"error":{"message":"\#(escaped)","type":"\#(type)"}}"#
        case .anthropic(let errorType):
            return
                #"{"type":"error","error":{"type":"\#(errorType)","message":"\#(escaped)"}}"#
        case .openResponses(let code):
            return
                #"{"error":{"type":"error","code":"\#(code)","message":"\#(escaped)"}}"#
        }
    }

    static func localRuntimeHTTPStatus(for error: Error) -> HTTPResponseStatus {
        if error is CancellationError {
            return HTTPResponseStatus(statusCode: 499, reasonPhrase: "Client Closed Request")
        }
        if (error as NSError).domain == emptyToolTaskCompletionDomain {
            return .serviceUnavailable
        }
        if error is ModelRuntime.LoadRefusedError {
            return .serviceUnavailable
        }
        if error is MLXService.RuntimePolicyError {
            return .badRequest
        }
        if (error as NSError).domain == "OsaurusToolChoice" {
            return .badRequest
        }
        return .internalServerError
    }

    static func openAIErrorType(for error: Error) -> String {
        if error is CancellationError {
            return "request_cancelled"
        }
        if (error as NSError).domain == emptyToolTaskCompletionDomain {
            return "server_error"
        }
        if error is ModelRuntime.LoadRefusedError {
            return "insufficient_resources"
        }
        if error is MLXService.RuntimePolicyError {
            return "invalid_request_error"
        }
        if (error as NSError).domain == "OsaurusToolChoice" {
            return "invalid_request_error"
        }
        return "internal_error"
    }

    static func emptyToolTaskCompletionError(
        requestMessages: [ChatMessage],
        responseMessage: ChatMessage?
    ) -> Error? {
        guard requestContainsToolTaskHistory(requestMessages),
            assistantResponseIsEmptyNoTool(responseMessage)
        else { return nil }
        return NSError(
            domain: emptyToolTaskCompletionDomain,
            code: 503,
            userInfo: [NSLocalizedDescriptionKey: emptyToolTaskCompletionMessage]
        )
    }

    private static func requestContainsToolTaskHistory(_ messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            message.role == "tool" || !(message.tool_calls?.isEmpty ?? true)
        }
    }

    private static func assistantResponseIsEmptyNoTool(_ message: ChatMessage?) -> Bool {
        guard let message, message.role == "assistant" else { return false }
        let contentEmpty = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let reasoningEmpty =
            (message.reasoning_content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let toolCallsEmpty = message.tool_calls?.isEmpty ?? true
        return contentEmpty && reasoningEmpty && toolCallsEmpty
    }

    static func anthropicErrorType(for error: Error) -> String {
        if error is CancellationError {
            return "request_cancelled"
        }
        if error is ModelRuntime.LoadRefusedError {
            return "overloaded_error"
        }
        if error is MLXService.RuntimePolicyError {
            return "invalid_request_error"
        }
        if (error as NSError).domain == "OsaurusToolChoice" {
            return "invalid_request_error"
        }
        return "api_error"
    }

    static func openResponsesErrorCode(for error: Error) -> String {
        if error is CancellationError {
            return "request_cancelled"
        }
        if error is ModelRuntime.LoadRefusedError {
            return "insufficient_resources"
        }
        if error is MLXService.RuntimePolicyError {
            return "invalid_request_error"
        }
        if (error as NSError).domain == "OsaurusToolChoice" {
            return "invalid_request_error"
        }
        return "api_error"
    }

    static func ollamaErrorType(for error: Error) -> String {
        if error is CancellationError {
            return "request_cancelled"
        }
        if error is ModelRuntime.LoadRefusedError {
            return "insufficient_resources"
        }
        if error is MLXService.RuntimePolicyError {
            return "invalid_request_error"
        }
        if (error as NSError).domain == "OsaurusToolChoice" {
            return "invalid_request_error"
        }
        return "internal_error"
    }

    /// Minimal JSON string escape. We deliberately do NOT pull in
    /// `JSONEncoder` here because the call site is usually inside a catch
    /// block where another encoder failure is the last thing we want.
    private static func escapeJSONString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}
