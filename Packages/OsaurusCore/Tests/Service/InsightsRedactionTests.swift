//
//  InsightsRedactionTests.swift
//  OsaurusCoreTests
//
//  Verifies the defense-in-depth credential scrubber that runs before any
//  request body is written into the request log ring buffer. The scrubber
//  exists so a future caller that forgets to redact a `/pair` (or other
//  token-bearing) response still does not leak `osk-v1` keys to disk.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("InsightsService.redactCredentials")
struct InsightsRedactionTests {

    @Test
    func redactsApiKeyValueInJSON() {
        let body = #"{"agentAddress":"0xabc","apiKey":"osk-v1.payload.signature","isPermanent":true}"#
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("osk-v1.payload.signature"))
        #expect(scrubbed.contains("<redacted>"))
        // Surrounding structure is preserved.
        #expect(scrubbed.contains("\"agentAddress\":\"0xabc\""))
        #expect(scrubbed.contains("\"isPermanent\":true"))
    }

    @Test
    func redactsBearerHeaderValue() {
        let body = "Authorization: Bearer osk-v1.aaa.bbb"
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("osk-v1.aaa.bbb"))
        #expect(scrubbed.contains("Bearer <redacted>"))
    }

    @Test
    func redactsBearerInJSONStringifiedHeader() {
        let body = #"{"headers":{"Authorization":"Bearer osk-v1.qwe.rty"}}"#
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("osk-v1.qwe.rty"))
    }

    @Test
    func leavesOrdinaryStringsAlone() {
        let body = #"{"role":"user","content":"hello"}"#
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(scrubbed == body)
    }

    @Test
    func redactsMultipleOccurrences() {
        // Two JSON-style values in the same blob — both should be scrubbed.
        let body = #"["osk-v1.aaa.bbb","osk-v1.ccc.ddd"]"#
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(!scrubbed.contains("osk-v1.aaa.bbb"))
        #expect(!scrubbed.contains("osk-v1.ccc.ddd"))
    }

    @Test
    func bareTokenInProseIsLeftAlone() {
        // The redactor is intentionally narrow: it scrubs `Bearer <token>`
        // and JSON-string-quoted token values but does NOT touch tokens that
        // appear bare in arbitrary prose. Logging callers are expected to
        // structure secrets as one of the recognised shapes.
        let body = "diagnostic line mentioning osk-v1.foo.bar"
        let scrubbed = InsightsService.redactCredentials(body)
        #expect(scrubbed == body)
    }
}
