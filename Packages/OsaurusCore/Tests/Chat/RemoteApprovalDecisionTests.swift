//
//  RemoteApprovalDecisionTests.swift
//  OsaurusCoreTests
//
//  The decision vocabulary a paired phone answers approval cards with
//  (docs/MOBILE_PROTOCOL.md §16.2).
//

import Foundation
import Testing

@testable import OsaurusCore

struct RemoteApprovalDecisionTests {
    @Test func mapsEveryAnswerTheCardOffers() {
        #expect(HTTPHandler.promptResolution(for: "deny") == .denied)
        #expect(HTTPHandler.promptResolution(for: "allow_once") == .allowOnce)
        #expect(HTTPHandler.promptResolution(for: "allow_for_run") == .allowForRun)
        #expect(HTTPHandler.promptResolution(for: "always_allow") == .alwaysAllow)
    }

    @Test func refusesAnythingElse() {
        // A typo must not silently become an allow.
        #expect(HTTPHandler.promptResolution(for: "allow") == nil)
        #expect(HTTPHandler.promptResolution(for: "Deny") == nil)
        #expect(HTTPHandler.promptResolution(for: "") == nil)
        #expect(HTTPHandler.promptResolution(for: "allow-once") == nil)
    }
}
