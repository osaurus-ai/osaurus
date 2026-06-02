//
//  HTTPRequestParse.swift
//  osaurus
//
//  Helpers for the request body decode pattern that every JSON HTTP route
//  in `HTTPHandler` repeats: pull the buffered bytes, copy into a `Data`,
//  keep a UTF-8 representation for request logging, then JSON-decode into
//  the route's typed body. Centralized here so the per-route handler can
//  read the body and the logged string in two lines instead of seven.
//

import Foundation
import NIOCore

extension HTTPHandler {

    /// The raw request body bytes plus their UTF-8 string form for logging.
    struct ParsedBody: Sendable {
        let data: Data
        /// Best-effort UTF-8 representation of `data` for the request log.
        /// `nil` when the request had no body buffered yet.
        let text: String?
    }

    /// Drain the buffered request body into a `Data` plus its UTF-8 string
    /// form for logging. Returns an empty `data` and `nil` `text` when the
    /// route was hit without a body (legitimate for some routes).
    ///
    /// Applies a structural JSON nesting-depth guard: a body within the size
    /// cap can still be a depth bomb (e.g. millions of nested `[`) that
    /// overflows the decoder's recursion. When the nesting budget is
    /// exceeded we drop the bytes (returning empty `data` but keeping the
    /// `text` for logging) so the route's JSON decode fails cleanly with a
    /// 400 instead of crashing the process. The budget is far beyond any
    /// real chat/tool payload, so legitimate requests are unaffected.
    func readRequestBody() -> ParsedBody {
        guard let body = stateRef.value.requestBodyBuffer else {
            return ParsedBody(data: Data(), text: nil)
        }
        var bodyCopy = body
        let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
        let data = Data(bytes)
        let text = String(decoding: data, as: UTF8.self)
        if Self.jsonNestingDepthExceedsBudget(data, max: Self.maxJSONNestingDepth) {
            return ParsedBody(data: Data(), text: text)
        }
        return ParsedBody(data: data, text: text)
    }

    /// Scan raw bytes for the maximum JSON structural nesting depth,
    /// returning `true` as soon as `max` is exceeded. Brackets inside JSON
    /// strings (respecting `\` escapes) don't count, so this won't false-trip
    /// on string payloads that merely contain `{`/`[` characters.
    static func jsonNestingDepthExceedsBudget(_ data: Data, max: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {  // backslash
                    escaped = true
                } else if byte == 0x22 {  // double quote
                    inString = false
                }
                continue
            }
            switch byte {
            case 0x22:  // double quote — enter string
                inString = true
            case 0x7B, 0x5B:  // '{' or '['
                depth += 1
                if depth > max { return true }
            case 0x7D, 0x5D:  // '}' or ']'
                if depth > 0 { depth -= 1 }
            default:
                break
            }
        }
        return false
    }
}
