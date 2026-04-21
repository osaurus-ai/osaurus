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

extension HTTPHandler {

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
