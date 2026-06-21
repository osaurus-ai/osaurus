//
//  InsightsImageRedactionTests.swift
//  OsaurusCoreTests — Chat
//
//  Audit-remediation coverage (P2): inline base64 image payloads (e.g.
//  Computer Use screenshots, scrubbed or not) must not be retained verbatim in
//  the Chat-UI Insights request-body buffer. `ChatEngine.redactInlineImagePayloads`
//  replaces the payload with a short marker while leaving the request shape —
//  and ordinary text content — intact for debugging.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class InsightsImageRedactionTests: XCTestCase {
    func testRedactsInlineBase64ImagePayload() {
        let payload = String(repeating: "A", count: 200)
        let json = "{\"image_url\":{\"url\":\"data:image/png;base64,\(payload)\"}}"
        let out = ChatEngine.redactInlineImagePayloads(in: json)

        XCTAssertFalse(out.contains(payload), "the raw base64 payload must not survive")
        XCTAssertTrue(out.contains(";base64,"), "the request shape (the data-URL prefix) is kept")
        XCTAssertTrue(out.contains("[redacted 200-char image]"))
    }

    func testLeavesOrdinaryTextContentIntact() {
        // No data-URL payload → returned unchanged (the panel still inspects text).
        let json = "{\"content\":\"Reach me about base64 encoding at jane@example.com\"}"
        XCTAssertEqual(ChatEngine.redactInlineImagePayloads(in: json), json)
    }

    func testIgnoresShortBase64LikeStrings() {
        // Below the 64-char threshold there's no image to redact.
        let json = "{\"url\":\"data:image/png;base64,AAAABBBBCCCC\"}"
        XCTAssertEqual(ChatEngine.redactInlineImagePayloads(in: json), json)
    }

    func testRedactsEveryImageInTheRequest() {
        let p1 = String(repeating: "B", count: 80)
        let p2 = String(repeating: "C", count: 120)
        let json =
            "[\"data:image/jpeg;base64,\(p1)\",\"data:image/png;base64,\(p2)\"]"
        let out = ChatEngine.redactInlineImagePayloads(in: json)

        XCTAssertFalse(out.contains(p1))
        XCTAssertFalse(out.contains(p2))
        XCTAssertTrue(out.contains("[redacted 80-char image]"))
        XCTAssertTrue(out.contains("[redacted 120-char image]"))
    }
}
