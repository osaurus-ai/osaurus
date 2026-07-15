//
//  HTTPIdempotencyKeyTests.swift
//  osaurusTests
//
//  Pins the Router billing idempotency-key resolution for HTTP-origin
//  requests: a client-supplied `Idempotency-Key` header is honored (so
//  CLI/script retries dedupe billing on a re-POST), everything else gets a
//  synthesized per-request key so the provider service's connect-phase
//  retries still dedupe.
//

import Foundation
import NIOHTTP1
import Testing

@testable import OsaurusCore

struct HTTPIdempotencyKeyTests {

    private func head(headers: [(String, String)] = []) -> HTTPRequestHead {
        var httpHeaders = HTTPHeaders()
        for (name, value) in headers {
            httpHeaders.add(name: name, value: value)
        }
        return HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/v1/chat/completions",
            headers: httpHeaders
        )
    }

    @Test func honorsClientSuppliedHeader() {
        let key = HTTPHandler.httpIdempotencyKey(
            head: head(headers: [("Idempotency-Key", "retry-abc-123")])
        )
        #expect(key == "retry-abc-123")
    }

    @Test func trimsSurroundingWhitespace() {
        let key = HTTPHandler.httpIdempotencyKey(
            head: head(headers: [("Idempotency-Key", "  spaced-key \t")])
        )
        #expect(key == "spaced-key")
    }

    @Test func synthesizesWhenHeaderAbsent() {
        let key = HTTPHandler.httpIdempotencyKey(head: head())
        #expect(key.hasPrefix("http-"))
        #expect(key.count > "http-".count)
    }

    @Test func synthesizedKeysAreUniquePerRequest() {
        let first = HTTPHandler.httpIdempotencyKey(head: head())
        let second = HTTPHandler.httpIdempotencyKey(head: head())
        #expect(first != second)
    }

    @Test func rejectsOversizedHeaderBySynthesizing() {
        let oversized = String(repeating: "k", count: 200)
        let key = HTTPHandler.httpIdempotencyKey(
            head: head(headers: [("Idempotency-Key", oversized)])
        )
        #expect(key.hasPrefix("http-"))
        #expect(key != oversized)
    }

    @Test func rejectsEmptyHeaderBySynthesizing() {
        let key = HTTPHandler.httpIdempotencyKey(
            head: head(headers: [("Idempotency-Key", "   ")])
        )
        #expect(key.hasPrefix("http-"))
    }
}
