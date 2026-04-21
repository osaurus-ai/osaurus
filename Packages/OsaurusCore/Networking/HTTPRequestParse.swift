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
    func readRequestBody() -> ParsedBody {
        guard let body = stateRef.value.requestBodyBuffer else {
            return ParsedBody(data: Data(), text: nil)
        }
        var bodyCopy = body
        let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
        let data = Data(bytes)
        return ParsedBody(data: data, text: String(decoding: data, as: UTF8.self))
    }
}
