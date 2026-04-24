//
//  RequestValidator.swift
//  OsaurusCore
//
//  Pure helper for accepting/rejecting sampler params before they reach
//  the chat engine. Lives in OsaurusCore at module level (not on
//  HTTPHandler) so external packages — notably OsaurusEvalsKit — can
//  exercise it as a regression suite without taking a dependency on
//  the NIO ChannelHandler. The HTTP layer wraps this helper to keep the
//  reject-with-400 logic in one place.
//

import Foundation

public enum RequestValidator {

    /// Reasons we reject a `ChatCompletionRequest` (or its primitive
    /// equivalents) outright with HTTP 400. We only flag the cases our
    /// docs declare unsupported (`n>1`, `response_format=json_schema`,
    /// etc.) — any field we silently ignored historically continues to
    /// be ignored here so we don't regress on existing clients.
    ///
    /// Returns `nil` when the request is acceptable; otherwise a
    /// human-readable explanation suitable for the 400 body.
    public static func unsupportedSamplerReason(
        n: Int?,
        responseFormatType: String?
    ) -> String? {
        if let n, n > 1 {
            return "Parameter 'n' > 1 is not supported. Submit one request per completion."
        }
        if let type = responseFormatType {
            switch type {
            case "json_object", "text":
                break  // supported / no-op
            default:
                return
                    "response_format type '\(type)' is not supported. Use 'json_object' for JSON mode."
            }
        }
        return nil
    }
}
